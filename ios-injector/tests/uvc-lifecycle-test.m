#import "ALExternalCamera.h"
#import <libuvc/libuvc.h>
#include <pthread.h>
#include <stdatomic.h>
#include <unistd.h>

static atomic_int scenario, opens, closes, exits, starts, stops, deliveries;
static atomic_bool running;
static pthread_t worker;
static uvc_frame_callback_t *callback;
static void *callbackContext;
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
uvc_error_t uvc_init(uvc_context_t **ctx,struct libusb_context *usb) { *ctx=(uvc_context_t *)1; return UVC_SUCCESS; }
void uvc_exit(uvc_context_t *ctx) { atomic_fetch_add(&exits,1); }
uvc_error_t uvc_get_device_list(uvc_context_t *ctx,uvc_device_t ***list) {
    static uvc_device_t *empty[]={NULL}; *list=atomic_load(&scenario)==1?empty:deviceList; return UVC_SUCCESS;
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
        puts("PASS simulated UVC discovery, denied access, mode fallback, cancellation, reconnect and no-frame teardown");
    }
    return 0;
}
