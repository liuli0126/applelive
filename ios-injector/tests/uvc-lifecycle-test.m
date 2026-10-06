#import "ALExternalCamera.h"
#import <libuvc/libuvc.h>
#import <libusb.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_int scenario, opens, closes, exits, starts, stops, deliveries;
static atomic_bool running;
static pthread_t worker;
static uvc_frame_callback_t *callback;
static void *callbackContext;
static libusb_log_cb usbLogger;
static atomic_int usbLists,usbListFrees,configReads,configFrees;
static uvc_device_t *deviceList[] = {(uvc_device_t *)2,NULL};
static uint32_t intervals[] = {333667,666666,0};
static uvc_frame_desc_t frameDescriptor = {.wWidth=640,.wHeight=480,.bFrameIntervalType=2,.intervals=intervals};
static uvc_format_desc_t formatDescriptor = {.bDescriptorSubtype=UVC_VS_FORMAT_UNCOMPRESSED,
    .fourccFormat={'Y','U','Y','2'},.frame_descs=&frameDescriptor};

static void check(BOOL ok,const char *message) { if (!ok) { fprintf(stderr,"FAIL %s\n",message); exit(1); } }
static BOOL awaitState(ALExternalCamera *camera,NSString *state,double seconds) {
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent()+seconds;
    while (CFAbsoluteTimeGetCurrent()<deadline) {
        if ([camera.status[@"state"] isEqualToString:state]) return YES;
        usleep(10000);
    }
    fprintf(stderr,"Unexpected state: %s\n",camera.status.description.UTF8String); return NO;
}
uvc_error_t uvc_init(uvc_context_t **ctx,struct libusb_context *usb) {
    *ctx=(uvc_context_t *)1;
    if (usbLogger) usbLogger(NULL,LIBUSB_LOG_LEVEL_WARNING,"mock driver: descriptor access check\n");
    return UVC_SUCCESS;
}
libusb_context *applelive_uvc_usb_context(uvc_context_t *ctx) { return ctx?(libusb_context *)17:NULL; }
void LIBUSB_CALL libusb_set_log_cb(libusb_context *ctx,libusb_log_cb cb,int mode) { usbLogger=cb; }
int LIBUSB_CALL libusb_set_option(libusb_context *ctx,enum libusb_option option,...) { return 0; }
ssize_t LIBUSB_CALL libusb_get_device_list(libusb_context *ctx,libusb_device ***devices) {
    check(ctx==(libusb_context *)17,"diagnostics use the actual UVC context");
    static libusb_device *one[]={(libusb_device *)10,NULL},*empty[]={NULL};
    int current=atomic_load(&scenario);
    if (current==7) { *devices=NULL;return LIBUSB_ERROR_ACCESS; }
    atomic_fetch_add(&usbLists,1);
    *devices=current==1?empty:one;return current==1?0:1;
}
void LIBUSB_CALL libusb_free_device_list(libusb_device **devices,int unref) { atomic_fetch_add(&usbListFrees,1); }
int LIBUSB_CALL libusb_get_device_descriptor(libusb_device *device,struct libusb_device_descriptor *desc) {
    *desc=(struct libusb_device_descriptor){.idVendor=0x046d,.idProduct=0x082d,.bNumConfigurations=1};return 0;
}
int LIBUSB_CALL libusb_get_config_descriptor(libusb_device *device,uint8_t index,struct libusb_config_descriptor **config) {
    if (atomic_load(&scenario)==5) { *config=NULL;return LIBUSB_ERROR_ACCESS; }
    static struct libusb_interface_descriptor alt={.bInterfaceNumber=1,.bInterfaceClass=14,.bInterfaceSubClass=2};
    static struct libusb_interface interface={.altsetting=&alt,.num_altsetting=1};
    static struct libusb_config_descriptor value={.bNumInterfaces=1,.interface=&interface};
    alt.bInterfaceClass=atomic_load(&scenario)==8?1:14;
    alt.bInterfaceSubClass=atomic_load(&scenario)==8?1:2;
    *config=&value;atomic_fetch_add(&configReads,1);return 0;
}
void LIBUSB_CALL libusb_free_config_descriptor(struct libusb_config_descriptor *config) { atomic_fetch_add(&configFrees,1); }
const char *LIBUSB_CALL libusb_error_name(int code) { return code==LIBUSB_ERROR_ACCESS?"LIBUSB_ERROR_ACCESS":"LIBUSB_SUCCESS"; }
void uvc_exit(uvc_context_t *ctx) { atomic_fetch_add(&exits,1); }
uvc_error_t uvc_get_device_list(uvc_context_t *ctx,uvc_device_t ***list) {
    static uvc_device_t *empty[]={NULL}; int current=atomic_load(&scenario);
    *list=(current==1 || current>=5)?empty:deviceList; return UVC_SUCCESS;
}
void uvc_free_device_list(uvc_device_t **list,uint8_t unref) {}
uvc_error_t uvc_get_device_descriptor(uvc_device_t *dev,uvc_device_descriptor_t **desc) {
    static uvc_device_descriptor_t descriptor={.idVendor=0x1234,.idProduct=0xabcd,.product="Test UVC"};
    *desc=&descriptor;return UVC_SUCCESS;
}
void uvc_free_device_descriptor(uvc_device_descriptor_t *desc) {}
uvc_error_t uvc_open(uvc_device_t *dev,uvc_device_handle_t **handle) {
    if (atomic_load(&scenario)==2) return UVC_ERROR_ACCESS;
    if (atomic_load(&scenario)==3) usleep(150000);
    *handle=(uvc_device_handle_t *)3;atomic_fetch_add(&opens,1);return UVC_SUCCESS;
}
void uvc_close(uvc_device_handle_t *handle) { atomic_fetch_add(&closes,1); }
const char *uvc_strerror(uvc_error_t error) { return error == UVC_ERROR_ACCESS?"Access denied":"mock"; }
const uvc_format_desc_t *uvc_get_format_descs(uvc_device_handle_t *h) { return &formatDescriptor; }
uvc_error_t uvc_get_stream_ctrl_format_size(uvc_device_handle_t *h,uvc_stream_ctrl_t *control,
    enum uvc_frame_format format,int width,int height,int fps) { return fps==15?UVC_SUCCESS:UVC_ERROR_NOT_SUPPORTED; }
static void *produce(void *ignored) {
    uint8_t pixels[16]={16,128,235,128,16,128,235,128,16,128,235,128,16,128,235,128};
    uvc_frame_t frame={.data=pixels,.data_bytes=sizeof(pixels),.width=4,.height=2,.step=8,.frame_format=UVC_FRAME_FORMAT_YUYV};
    while (atomic_load(&running)) {
        if (atomic_load(&scenario)!=4) callback(&frame,callbackContext);
        usleep(10000);
    }
    return NULL;
}
uvc_error_t uvc_start_streaming(uvc_device_handle_t *h,uvc_stream_ctrl_t *control,uvc_frame_callback_t *cb,void *ctx,uint8_t flags) {
    callback=cb; callbackContext=ctx;atomic_store(&running,true);atomic_fetch_add(&starts,1);
    pthread_create(&worker,NULL,produce,NULL);return UVC_SUCCESS;
}
void uvc_stop_streaming(uvc_device_handle_t *h) {
    atomic_store(&running,false); pthread_join(worker,NULL);atomic_fetch_add(&stops,1);
}
static void awaitClosed(void) {
    for (int i=0;i<200 && atomic_load(&opens)!=atomic_load(&closes);i++) usleep(10000);
    check(atomic_load(&opens)==atomic_load(&closes),"every opened handle closed");
}
int main(void) {
    @autoreleasepool {
        ALExternalCamera *camera=[ALExternalCamera new];
        camera.onFrame=^(CVPixelBufferRef frame) { check(frame != NULL,"owned frame delivered"); atomic_fetch_add(&deliveries,1); };
        atomic_store(&scenario,1); [camera start];check(awaitState(camera,@"error",2),"missing device reported");
        check([camera.status[@"code"] intValue]==UVC_ERROR_NO_DEVICE,"missing device has real error code");
        check([camera.status[@"message"] containsString:@"未枚举到"],"empty raw USB distinguished");
        check([camera.diagnosticReport containsString:@"IOUSBDevice"] && [camera.diagnosticReport containsString:@"IOUSBHostDevice"],"both matching classes reported");
        atomic_store(&scenario,5); [camera start];check(awaitState(camera,@"error",2),"descriptor failure reported");
        check([camera.status[@"message"] containsString:@"描述符失败"],"descriptor failure not misreported as absent cable");
        check([camera.status[@"code"] intValue]==LIBUSB_ERROR_ACCESS,"descriptor access error not replaced by no-device");
        check([camera.diagnosticReport containsString:@"046D:082D"] && [camera.diagnosticReport containsString:@"LIBUSB_ERROR_ACCESS"],"Logitech identifier and original descriptor error retained");
        check([camera.diagnosticReport containsString:@"mock driver"],"underlying driver warning retained");
        atomic_store(&scenario,6); [camera start];check(awaitState(camera,@"error",2),"UVC filter miss reported");
        check([camera.diagnosticReport containsString:@"1:0E/02"],"actual video interface retained when UVC enumeration fails");
        check([camera.status[@"message"] containsString:@"UVC 视频接口"],"UVC miss distinguished from USB descriptor failure");
        atomic_store(&scenario,8); [camera start];check(awaitState(camera,@"error",2),"non-video USB reported");
        check([camera.status[@"message"] containsString:@"未识别到 UVC"],"audio-only interface distinguished from visible UVC");
        atomic_store(&scenario,7); [camera start];check(awaitState(camera,@"error",2),"raw USB access denied reported");
        check([camera.status[@"message"] containsString:@"底层 USB 枚举失败"],"negative raw count distinguished from empty list");
        check([camera.status[@"code"] intValue]==LIBUSB_ERROR_ACCESS,"original enumeration error retained");
        atomic_store(&scenario,2); [camera start];check(awaitState(camera,@"error",2),"permission denied reported");
        check([camera.status[@"code"] intValue]==UVC_ERROR_ACCESS,"preserve access error");
        atomic_store(&scenario,0);[camera start];check(awaitState(camera,@"playing",2),"negotiated fallback delivers video");
        [camera stop];awaitClosed();int count=atomic_load(&deliveries);usleep(50000);
        check(atomic_load(&deliveries)==count,"no frames after completed stop");
        atomic_store(&scenario,3);[camera start];usleep(30000);[camera stop];
        usleep(220000);awaitClosed();
        check(atomic_load(&deliveries)==count,"cancel while opening suppresses old callback");
        atomic_store(&scenario,0);[camera start];check(awaitState(camera,@"playing",2),"reconnect succeeds");
        [camera stop];awaitClosed();
        atomic_store(&scenario,4);[camera start];check(awaitState(camera,@"error",8),"no-frame watchdog stops device");awaitClosed();
        check(atomic_load(&starts)==atomic_load(&stops),"every stream stopped");
        check([camera.diagnosticReport containsString:@"1234:ABCD"],"diagnostic device identifier");
        [camera stopAndWait];
        check(!usbLogger,"driver log callback removed after teardown");
        check(atomic_load(&usbLists)==atomic_load(&usbListFrees),"every raw device list freed");
        check(atomic_load(&configReads)==atomic_load(&configFrees),"every configuration descriptor freed");
        check([camera.diagnosticReport dataUsingEncoding:NSUTF8StringEncoding].length<30000,"diagnostics fit service message limit");
        puts("PASS simulated UVC discovery, denied access, mode fallback, cancellation, reconnect and no-frame teardown");
    }
    return 0;
}
