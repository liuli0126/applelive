#import "ALExternalCamera.h"
#import "ALUVCFrame.h"
#import "ALUVCWire.h"
#import <libuvc/libuvc.h>
#import <libusb.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <math.h>
#import <IOKit/IOKitLib.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>

// Read-only access to libuvc's existing context; libuvc still owns event handling.
extern struct libusb_context *applelive_uvc_usb_context(uvc_context_t *context);
static __weak ALExternalCamera *usbLogOwner;

@interface ALUVCSession : NSObject
@property(nonatomic, weak) ALExternalCamera *owner;
@end
@implementation ALUVCSession
@end

@interface ALExternalCamera () {
    dispatch_queue_t _queue;
    dispatch_source_t _watchdog;
    uvc_context_t *_context;
    uvc_device_handle_t *_device;
    BOOL _streaming;
    atomic_uint_fast64_t _generation;
    uint64_t _activeGeneration;
    CFAbsoluteTime _lastFrame;
    NSUInteger _frameCount;
    NSUInteger _badFrames;
    NSMutableArray<NSString *> *_diagnostics;
    NSMutableArray<NSString *> *_usbMessages;
    NSString *_deviceName;
    ALUVCSession *_callbackSession;
    int _lastOpenError;
    NSInteger _visibleUSBDevices;
    NSUInteger _descriptorFailures;
    NSUInteger _USBVideoInterfaces;
    int _descriptorError;
    int _enumerationError;
}
@property(atomic, copy, readwrite) NSDictionary *status;
- (void)receiveFrame:(uvc_frame_t *)frame;
- (void)recordUSBMessage:(NSString *)message;
@end

static void LIBUSB_CALL ALUSBLog(libusb_context *context, enum libusb_log_level level, const char *message) {
    (void)context;(void)level;
    @autoreleasepool {
        ALExternalCamera *owner;
        @synchronized (ALExternalCamera.class) { owner=usbLogOwner; }
        if (owner && message) {
            // Limit input before constructing an NSString. No device payloads are logged.
            NSString *text=[[NSString alloc] initWithBytes:message length:strnlen(message,384) encoding:NSUTF8StringEncoding];
            if (text) [owner recordUSBMessage:text];
        }
    }
}

static void ALUVCReceive(uvc_frame_t *frame, void *context) {
    @autoreleasepool {
        ALExternalCamera *owner = ((__bridge ALUVCSession *)context).owner;
        [owner receiveFrame:frame];
    }
}

@implementation ALExternalCamera
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.applelive.external-camera", DISPATCH_QUEUE_SERIAL);
        atomic_init(&_generation, 0);
        _diagnostics = [NSMutableArray new];
        _usbMessages = [NSMutableArray new];
        self.status = @{@"state": @"stopped", @"message": @"外接相机未连接"};
    }
    return self;
}
- (void)log:(NSString *)text {
    @synchronized (self) {
        NSString *bounded=text ?: @"";
        [_diagnostics addObject:[bounded substringToIndex:MIN(bounded.length,400)]];
        if (_diagnostics.count > 60) [_diagnostics removeObjectAtIndex:0];
    }
}
- (void)setState:(NSString *)state message:(NSString *)message code:(int)code {
    self.status = @{@"state": state, @"message": message ?: @"", @"error": message ?: @"",
                   @"device": _deviceName ?: @"UVC 外接相机", @"code": @(code)};
    [self log:[NSString stringWithFormat:@"%@ (%d): %@", state, code, message]];
}
- (NSString *)diagnosticReport {
    @synchronized (self) {
        NSString *base=[_diagnostics componentsJoinedByString:@"\n"];
        NSString *driver=[_usbMessages componentsJoinedByString:@"\n"];
        // Stay below both the service's UTF-8 wire limit and the client's text limit.
        return [NSString stringWithFormat:@"%@\n--- libusb 驱动记录 ---\n%@",
            [base substringToIndex:MIN(base.length,5500)], [driver substringToIndex:MIN(driver.length,4000)]];
    }
}
- (void)recordUSBMessage:(NSString *)message {
    @synchronized (self) {
        NSString *text=[message stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [_usbMessages addObject:text];
        if (_usbMessages.count>16) [_usbMessages removeObjectAtIndex:0];
    }
}
- (void)recordAccessContext {
    [self log:[NSString stringWithFormat:@"AppleLive USB 探测 0.1.1 · %@ · %@ · uid=%u/euid=%u",
        NSBundle.mainBundle.bundleIdentifier ?: NSProcessInfo.processInfo.processName,
        NSProcessInfo.processInfo.operatingSystemVersionString,(unsigned)getuid(),(unsigned)geteuid()]];
    // Entitlements belong to the executable, not to an injected dylib. Reading
    // them is diagnostic only; the actual uvc_open result decides access.
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
    CreateTask create = (CreateTask)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CopyEntitlement copy = (CopyEntitlement)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    if (!create || !copy) { [self log:@"进程权限查询不可用；将以实际打开结果为准"]; return; }
    CFTypeRef task = create(NULL);
    if (!task) return;
    for (NSString *key in @[@"com.apple.private.security.no-sandbox",@"platform-application",
                             @"com.apple.security.exception.iokit-user-client-class",
                             @"com.apple.system.diagnostics.iokit-properties"]) {
        CFTypeRef value = copy(task, (__bridge CFStringRef)key, NULL);
        [self log:[NSString stringWithFormat:@"%@ = %@", key, value ? (__bridge id)value : @"未声明"]];
        if (value) CFRelease(value);
    }
    CFRelease(task);
}
- (void)recordUSBInventory {
    io_registry_entry_t root=IORegistryGetRootEntry(0);
    [self log:[NSString stringWithFormat:@"IORegistry 根节点可访问: %@（仅诊断，不代表 USB 已授权）",root?@"是":@"否"]];
    if (root) IOObjectRelease(root);
    for (NSString *deviceClass in @[@"IOUSBDevice",@"IOUSBHostDevice",@"IOUSBInterface",@"IOUSBHostInterface",@"IOUSBHostController"]) {
    io_iterator_t iterator = 0;
    kern_return_t result = IOServiceGetMatchingServices(0, IOServiceMatching(deviceClass.UTF8String), &iterator);
    if (result != KERN_SUCCESS) {
        [self log:[NSString stringWithFormat:@"IOKit %@: 0x%08x",deviceClass,result]];
        if (iterator) IOObjectRelease(iterator);
        continue;
    }
    NSUInteger count = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        NSMutableArray *values = [NSMutableArray new];
        io_name_t name={0};
        IOObjectGetClass(service,name);
        [values addObject:[NSString stringWithFormat:@"class=%s",name]];
        for (NSString *key in @[@"idVendor", @"idProduct", @"USB Product Name", @"bInterfaceClass", @"bInterfaceSubClass"]) {
            CFTypeRef value = IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, NULL, 0);
            if (value) {
                if (CFGetTypeID(value) == CFStringGetTypeID() || CFGetTypeID(value) == CFNumberGetTypeID())
                    [values addObject:[NSString stringWithFormat:@"%@=%@", key, (__bridge id)value]];
                CFRelease(value);
            }
        }
        IOObjectRelease(service);
        if (count<4) [self log:[values componentsJoinedByString:@" "]];
        if (++count >= 128) break;
    }
    IOObjectRelease(iterator);
    [self log:[NSString stringWithFormat:@"IOKit %@: 返回 0x%08x，可见 %lu%@",deviceClass,result,(unsigned long)count,count>=128?@"+":@""]];
    }
}
- (void)recordRawUSBInventory {
    libusb_device **devices=NULL;
    libusb_context *usb=applelive_uvc_usb_context(_context);
    _visibleUSBDevices=-1;_descriptorFailures=0;_USBVideoInterfaces=0;_descriptorError=0;_enumerationError=0;
    if (!usb) { [self log:@"底层 USB 上下文不可用"];return; }
    ssize_t count=libusb_get_device_list(usb,&devices);
    _visibleUSBDevices=count;
    if (count<0) _enumerationError=(int)count;
    [self log:[NSString stringWithFormat:@"libusb 原始设备数: %ld%@",(long)count,
        count<0?[NSString stringWithFormat:@" (%s)",libusb_error_name((int)count)]:@""]];
    for (ssize_t i=0;devices && i<count && i<8;i++) {
        struct libusb_device_descriptor descriptor={0};
        int result=libusb_get_device_descriptor(devices[i],&descriptor);
        if (result<0) {
            _descriptorFailures++;
            _descriptorError=result;
            [self log:[NSString stringWithFormat:@"USB[%ld] 设备描述符失败: %d (%s)",(long)i,result,libusb_error_name(result)]];
            continue;
        }
        [self log:[NSString stringWithFormat:@"USB[%ld] %04X:%04X%@ class=%02X configs=%u",(long)i,
            descriptor.idVendor,descriptor.idProduct,descriptor.idVendor==0x046d?@" 罗技/Logitech":@"",
            descriptor.bDeviceClass,descriptor.bNumConfigurations]];
        struct libusb_config_descriptor *config=NULL;
        result=libusb_get_config_descriptor(devices[i],0,&config);
        if (result<0 || !config) {
            _descriptorFailures++;
            _descriptorError=result<0?result:LIBUSB_ERROR_OTHER;
            [self log:[NSString stringWithFormat:@"USB[%ld] 配置0读取失败: %d (%s)",(long)i,result,libusb_error_name(result)]];
            continue;
        }
        NSMutableArray *interfaces=[NSMutableArray new];
        for (NSUInteger j=0;j<config->bNumInterfaces && j<32;j++) {
            const struct libusb_interface *entry=&config->interface[j];
            if (!entry->altsetting || entry->num_altsetting<1) continue;
            const struct libusb_interface_descriptor *alt=&entry->altsetting[0];
            if (alt->bInterfaceClass==14 && alt->bInterfaceSubClass==2) _USBVideoInterfaces++;
            [interfaces addObject:[NSString stringWithFormat:@"%u:%02X/%02X",alt->bInterfaceNumber,alt->bInterfaceClass,alt->bInterfaceSubClass]];
        }
        [self log:[NSString stringWithFormat:@"USB[%ld] 接口号:类/子类 %@ (0E/02=UVC视频，01=音频)",(long)i,[interfaces componentsJoinedByString:@", "]]];
        libusb_free_config_descriptor(config);
    }
    if (devices) libusb_free_device_list(devices,1);
}
- (void)closeDevice {
    if (_watchdog) { dispatch_source_cancel(_watchdog); _watchdog = nil; }
    if (_device) {
        if (_streaming) uvc_stop_streaming(_device); // joins the frame callback
        _streaming = NO;
        uvc_close(_device); _device = NULL;
    }
    _callbackSession = nil;
    if (_context) { uvc_exit(_context); _context = NULL; }
    @synchronized (ALExternalCamera.class) {
        if (usbLogOwner==self) {
            libusb_set_log_cb(NULL,NULL,LIBUSB_LOG_CB_GLOBAL);
            usbLogOwner=nil;
        }
    }
}
- (void)dealloc {
    atomic_fetch_add(&_generation, 1);
    [self closeDevice];
}
- (void)stop {
    atomic_fetch_add(&_generation, 1);
    dispatch_async(_queue, ^{ [self closeDevice]; });
}
- (void)stopAndWait { [self stop]; dispatch_sync(_queue, ^{}); }
- (void)start {
    uint64_t generation = atomic_fetch_add(&_generation, 1) + 1;
    self.status = @{@"state": @"opening", @"message": @"正在识别外接相机…"};
    dispatch_async(_queue, ^{
        [self closeDevice];
        if (atomic_load(&self->_generation) != generation) return;
        self->_activeGeneration = generation;
        self->_deviceName = nil;
        @synchronized (self) { [self->_diagnostics removeAllObjects];[self->_usbMessages removeAllObjects]; }
        [self recordAccessContext];
        [self recordUSBInventory];
        @synchronized (ALExternalCamera.class) { usbLogOwner=self; }
        libusb_set_log_cb(NULL,ALUSBLog,LIBUSB_LOG_CB_GLOBAL);
        libusb_set_option(NULL,LIBUSB_OPTION_LOG_LEVEL,LIBUSB_LOG_LEVEL_DEBUG);
        int result = uvc_init(&self->_context, NULL);
        if (result != UVC_SUCCESS) {
            [self setState:@"error" message:@"USB Host 初始化失败，点“连接诊断”查看原因" code:result];
            [self closeDevice]; return;
        }
        [self recordRawUSBInventory];
        uvc_device_t **devices = NULL;
        result = uvc_get_device_list(self->_context, &devices);
        // Debug enumeration only; per-transfer logging would burden live capture.
        libusb_set_option(applelive_uvc_usb_context(self->_context),LIBUSB_OPTION_LOG_LEVEL,LIBUSB_LOG_LEVEL_WARNING);
        [self log:[NSString stringWithFormat:@"UVC 枚举返回: %d (%s)",result,uvc_strerror(result)]];
        if (result != UVC_SUCCESS || !devices || !devices[0]) {
            if (devices) uvc_free_device_list(devices, 1);
            NSString *message=self->_enumerationError<0?@"底层 USB 枚举失败，请复制连接诊断":
                self->_visibleUSBDevices==0?@"采集服务未枚举到 USB 设备，请复制连接诊断":
                self->_descriptorFailures?@"USB 设备已枚举，但读取描述符失败，请复制连接诊断":
                self->_USBVideoInterfaces?@"已发现 UVC 视频接口，但采集库未返回相机，请复制连接诊断":
                @"已检查 USB 设备，未识别到 UVC 视频接口，请复制连接诊断";
            [self setState:@"error" message:message
                code:self->_enumerationError<0?self->_enumerationError:self->_descriptorError<0?self->_descriptorError:
                    result == UVC_SUCCESS ? UVC_ERROR_NO_DEVICE : result];
            [self closeDevice]; return;
        }
        BOOL opened = NO;
        for (NSUInteger i = 0; devices[i] && i < 32; i++) {
            if (atomic_load(&self->_generation) != generation) break;
            uvc_device_descriptor_t *descriptor = NULL;
            NSString *name = @"UVC 采集卡";
            if (uvc_get_device_descriptor(devices[i], &descriptor) == UVC_SUCCESS && descriptor) {
                NSString *product = descriptor->product ? [NSString stringWithUTF8String:descriptor->product] : nil;
                name = [NSString stringWithFormat:@"%@ [%04X:%04X]", product ?: @"UVC 采集卡",
                        descriptor->idVendor, descriptor->idProduct];
                uvc_free_device_descriptor(descriptor);
            }
            [self log:[@"发现 " stringByAppendingString:name]];
            result = uvc_open(devices[i], &self->_device);
            if (result == UVC_SUCCESS) {
                self->_deviceName = name;
                opened = [self beginStream:generation];
                if (opened) break;
                result = self->_lastOpenError;
                uvc_close(self->_device); self->_device = NULL;
            }
            [self log:[NSString stringWithFormat:@"打开/协商失败: %d (%s)", result, uvc_strerror(result)]];
        }
        uvc_free_device_list(devices, 1);
        if (atomic_load(&self->_generation) != generation) { [self closeDevice]; return; }
        if (!opened) {
            NSString *message = result == UVC_ERROR_ACCESS
                ? @"USB 访问被系统拒绝，请复制连接诊断以检查采集进程的实际权限"
                : @"无法打开或启动采集卡，点“连接诊断”查看格式与权限信息";
            [self setState:@"error" message:message code:result];
            [self closeDevice];
        }
    });
}
- (BOOL)beginStream:(uint64_t)generation {
    _lastOpenError = UVC_ERROR_NOT_SUPPORTED;
    NSMutableArray<NSDictionary *> *modes = [NSMutableArray new];
    NSUInteger count = 0;
    for (const uvc_format_desc_t *format = uvc_get_format_descs(_device); format && count++ < 128; format = format->next) {
        enum uvc_frame_format pixelFormat = UVC_FRAME_FORMAT_UNKNOWN;
        if (format->bDescriptorSubtype == UVC_VS_FORMAT_MJPEG) pixelFormat = UVC_FRAME_FORMAT_MJPEG;
        else if (format->bDescriptorSubtype == UVC_VS_FORMAT_UNCOMPRESSED) {
            if (memcmp(format->fourccFormat, "YUY2", 4) == 0) pixelFormat = UVC_FRAME_FORMAT_YUYV;
            if (memcmp(format->fourccFormat, "UYVY", 4) == 0) pixelFormat = UVC_FRAME_FORMAT_UYVY;
        }
        if (pixelFormat == UVC_FRAME_FORMAT_UNKNOWN) continue;
        NSUInteger frames = 0;
        for (const uvc_frame_desc_t *frame = format->frame_descs; frame && frames++ < 128; frame = frame->next) {
            NSUInteger w = frame->wWidth, h = frame->wHeight;
            if (w < 2 || h < 2 || w > 1920 || h > 1080 || w * h > 1920 * 1080) continue;
            NSMutableOrderedSet<NSNumber *> *rates = [NSMutableOrderedSet orderedSet];
            if (frame->bFrameIntervalType && frame->intervals) {
                for (NSUInteger i = 0; i < frame->bFrameIntervalType; i++) {
                    uint32_t interval = frame->intervals[i];
                    if (!interval) break;
                    // libuvc compares integer FPS using truncation; 29.97 is 29.
                    int fps = 10000000 / interval;
                    if (fps >= 5 && fps <= 30) [rates addObject:@(fps)];
                }
            } else [rates addObjectsFromArray:@[@30, @25, @20, @15, @10]];
            for (NSNumber *rate in rates) {
                int fps = rate.intValue;
                // Raw video over Lightning USB 2 needs bounded bandwidth.
                if (pixelFormat != UVC_FRAME_FORMAT_MJPEG && w * h * 2 * fps > 28 * 1024 * 1024) continue;
                NSInteger score = labs((long)(w*h) - 1280*720) / 1000 + (30-fps)*20;
                if (pixelFormat != UVC_FRAME_FORMAT_MJPEG) score += 2000;
                [modes addObject:@{@"w": @(w), @"h": @(h), @"fps": rate, @"format": @(pixelFormat), @"score": @(score)}];
            }
        }
    }
    [modes sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"score"] compare:b[@"score"]]; }];
    NSUInteger attempts = 0;
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + 12;
    for (NSDictionary *mode in modes) {
        if (atomic_load(&_generation) != generation || attempts++ >= 24) return NO;
        if (CFAbsoluteTimeGetCurrent() > deadline) { _lastOpenError = UVC_ERROR_TIMEOUT; return NO; }
        uvc_stream_ctrl_t control = {0};
        enum uvc_frame_format format = [mode[@"format"] intValue];
        int result = uvc_get_stream_ctrl_format_size(_device, &control, format,
                         [mode[@"w"] intValue], [mode[@"h"] intValue], [mode[@"fps"] intValue]);
        _lastOpenError = result;
        if (result != UVC_SUCCESS) continue;
        @synchronized (self) { _frameCount = _badFrames = 0; _lastFrame = CFAbsoluteTimeGetCurrent(); }
        [self setState:@"opening" message:@"采集卡已打开，等待 HDMI 画面…" code:0];
        _callbackSession = [ALUVCSession new]; _callbackSession.owner = self;
        result = uvc_start_streaming(_device, &control, ALUVCReceive, (__bridge void *)_callbackSession, 0);
        _lastOpenError = result;
        [self log:[NSString stringWithFormat:@"尝试 %@x%@ %@fps format=%d: %d", mode[@"w"], mode[@"h"], mode[@"fps"], format, result]];
        if (result != UVC_SUCCESS) continue;
        _streaming = YES;
        __weak typeof(self) weakSelf = self;
        _watchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_watchdog, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC/10);
        dispatch_source_set_event_handler(_watchdog, ^{
            ALExternalCamera *owner = weakSelf;
            if (!owner) return;
            CFAbsoluteTime last;
            NSUInteger bad;
            @synchronized (owner) { last = owner->_lastFrame; bad = owner->_badFrames; }
            if (atomic_load(&owner->_generation) != generation) { [owner closeDevice]; return; }
            if (CFAbsoluteTimeGetCurrent() - last > 5) {
                atomic_fetch_add(&owner->_generation, 1);
                [owner closeDevice];
                [owner setState:@"error" message:bad ? @"收到的视频帧无法解码；请复制连接诊断" : @"采集卡没有持续输出；检查 HDMI、OTG 和供电后点击重试" code:UVC_ERROR_TIMEOUT];
            }
        });
        dispatch_resume(_watchdog);
        return YES;
    }
    [self log:@"没有启动成功的 MJPEG/YUY2/UYVY 模式（带宽限制内最多尝试24项）"];
    return NO;
}
- (void)receiveFrame:(uvc_frame_t *)frame {
    if (!frame || atomic_load(&_generation) != _activeGeneration) return;
    BOOL jpeg = frame->frame_format == UVC_FRAME_FORMAT_MJPEG;
    if (!jpeg && frame->frame_format != UVC_FRAME_FORMAT_YUYV && frame->frame_format != UVC_FRAME_FORMAT_UYVY) return;
    void (^raw)(NSData *) = self.onRawFrame;
    if (raw) {
        if (frame->step > UINT32_MAX) return;
        NSData *packet = ALUVCPackFrame(frame->data,frame->data_bytes,frame->width,frame->height,(uint32_t)frame->step,
            jpeg ? ALUVCJPEG : frame->frame_format == UVC_FRAME_FORMAT_UYVY ? ALUVCUYVY : ALUVCYUY2);
        if (!packet) { @synchronized (self) { _badFrames++; } return; }
        if (atomic_load(&_generation) != _activeGeneration) return;
        BOOL first;
        @synchronized (self) { first = _frameCount++ == 0; _lastFrame = CFAbsoluteTimeGetCurrent(); }
        if (first) [self setState:@"playing" message:@"已收到采集卡视频数据" code:0];
        raw(packet); return;
    }
    CVPixelBufferRef pixel = ALCopyUVCFrame(frame->data, frame->data_bytes, frame->width, frame->height,
        frame->step, jpeg, frame->frame_format == UVC_FRAME_FORMAT_UYVY);
    if (!pixel) { @synchronized (self) { _badFrames++; } return; }
    if (atomic_load(&_generation) == _activeGeneration) {
        BOOL first;
        @synchronized (self) { first = _frameCount++ == 0; _lastFrame = CFAbsoluteTimeGetCurrent(); }
        if (first) [self setState:@"playing" message:@"外接相机画面已接入" code:0];
        void (^handler)(CVPixelBufferRef) = self.onFrame;
        if (handler) handler(pixel);
    }
    CVPixelBufferRelease(pixel);
}
@end
