#include <ApplicationServices/ApplicationServices.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>

// macOS 27 routes Dock gestures through an attached live IOHIDEvent.
// Signatures follow Apple's HIDEvent.m; resolve optional APIs at runtime.
typedef struct {
    CFTypeRef (*create)(CFAllocatorRef,uint32_t,uint64_t,uint32_t);
    void (*integer)(CFTypeRef,uint32_t,CFIndex);
    void (*number)(CFTypeRef,uint32_t,double);
    void (*flags)(CFTypeRef,uint32_t);
    void (*append)(CFTypeRef,CFTypeRef,uint32_t);
    void (*attach)(CGEventRef,CFTypeRef);
} DockAPI;
static DockAPI api;
static pthread_once_t apiOnce=PTHREAD_ONCE_INIT;
static void loadDockAPI(void) {
    void *io=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
    void *sl=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",RTLD_LAZY);
    if(!io||!sl)return;
    api.create=dlsym(io,"IOHIDEventCreate");
    api.integer=dlsym(io,"IOHIDEventSetIntegerValue");
    api.number=dlsym(io,"IOHIDEventSetDoubleValue");
    api.flags=dlsym(io,"IOHIDEventSetEventFlags");
    api.append=dlsym(io,"IOHIDEventAppendEvent");
    api.attach=dlsym(sl,"SLEventSetIOHIDEvent");
}
static bool usesLivePayload(void) { if(__builtin_available(macOS 27.0,*))return true;return false; }
static CGEventRef createDockMotionEvent(double progress,double delta,double velocity,int axis,int phase) {
    if(!isfinite(delta)||fabs(delta)>4)return NULL;
    if(!isfinite(progress)||!isfinite(velocity)||fabs(progress)>2||fabs(velocity)>10||(axis!=1&&axis!=2&&axis!=3)||(phase!=1&&phase!=2&&phase!=4&&phase!=8))return NULL;
    if(phase==4 && progress*velocity < -0.001)phase=8;
    bool live=usesLivePayload();
    // iPhone horizontal progress uses the legacy Dock direction convention.
    // The macOS 27 HID path consumes the opposite horizontal sign.
    if(live && axis==1){progress=-progress;velocity=-velocity;}
    double legacyProgress=live ? -progress:progress;
    CGEventRef e=CGEventCreate(NULL);if(!e)return NULL;
    CGEventSetType(e,30);
    CGEventSetIntegerValueField(e,110,23);
    CGEventSetIntegerValueField(e,41,33231);
    CGEventSetIntegerValueField(e,132,phase);
    CGEventSetIntegerValueField(e,134,phase);
    CGEventSetIntegerValueField(e,123,axis);
    CGEventSetIntegerValueField(e,165,axis);
    CGEventSetDoubleValueField(e,124,legacyProgress);
    if(axis==2){CGEventSetDoubleValueField(e,125,0);CGEventSetDoubleValueField(e,126,delta);}
    float amount=(float)legacyProgress;uint32_t bits;memcpy(&bits,&amount,4);
    CGEventSetIntegerValueField(e,135,bits);
    uint32_t a=(uint32_t)axis;float hint;memcpy(&hint,&a,4);
    CGEventSetDoubleValueField(e,119,hint);
    CGEventSetDoubleValueField(e,139,hint);
    CGEventSetIntegerValueField(e,136,axis==1 ? 0:1);
    CGEventSetIntegerValueField(e,138,3);
    CGEventSetIntegerValueField(e,58,CGEventGetTimestamp(e));CGEventSetIntegerValueField(e,169,mach_absolute_time());
    if(phase==4||phase==8) {
        double wrapperVelocity=live ? -velocity:velocity;
        CGEventSetDoubleValueField(e,129,wrapperVelocity);
        CGEventSetDoubleValueField(e,130,wrapperVelocity);
    }
    if(live) {
        pthread_once(&apiOnce,loadDockAPI);
        if(!api.create||!api.integer||!api.number||!api.flags||!api.append||!api.attach){CFRelease(e);return NULL;}
        CFTypeRef hid=api.create(kCFAllocatorDefault,23,mach_absolute_time(),0);
        if(!hid){CFRelease(e);return NULL;}
        api.flags(hid,(uint32_t)phase<<24);
        api.integer(hid,(23<<16)+1,axis);
        api.integer(hid,(23<<16)+5,3);
        api.number(hid,(23<<16)+2,progress);
        if(axis==2){api.number(hid,(23<<16)+3,0);api.number(hid,(23<<16)+4,delta);}
        if(phase==4||phase==8) {
            CFTypeRef child=api.create(kCFAllocatorDefault,9,mach_absolute_time(),0);
            if(!child){CFRelease(hid);CFRelease(e);return NULL;}
            // Physical Dock gestures carry the scalar velocity in both components.
            api.number(child,(9<<16),velocity);
            api.number(child,(9<<16)+1,velocity);
            api.append(hid,child,0);CFRelease(child);
        }
        api.attach(e,hid);CFRelease(hid);
        // Rebuild the CG wrapper from its serialized representation so cached
        // source/subtype metadata agrees with the attached HID event.
        CFDataRef data=CGEventCreateData(NULL,e);
        CGEventRef normalized=data ? CGEventCreateFromData(NULL,data):NULL;
        if(data)CFRelease(data);CFRelease(e);return normalized;
    }
    return e;
}
CGEventRef PocketCreateDockEvent(double progress,double velocity,int axis,int phase){return createDockMotionEvent(progress,0,velocity,axis,phase);}
CGEventRef PocketCreateDockMotionEvent(double progress,double delta,double velocity,int axis,int phase){return createDockMotionEvent(progress,delta,velocity,axis,phase);}
bool PocketPostDock(double progress,double velocity,int axis,int phase);
bool PocketPostDockMotion(double progress,double delta,double velocity,int axis,int phase){
    if(!usesLivePayload())return PocketPostDock(progress,velocity,axis,phase);
    CGEventRef event=createDockMotionEvent(progress,delta,velocity,axis,phase);if(!event)return false;
    CGEventPost(kCGSessionEventTap,event);CFRelease(event);return true;
}
bool PocketPostDock(double progress,double velocity,int axis,int phase) {
    CGEventRef event=PocketCreateDockEvent(progress,velocity,axis,phase);if(!event)return false;
    CGEventPost(kCGSessionEventTap,event);CFRelease(event);
    if(!usesLivePayload()) {
        CGEventRef marker=CGEventCreate(NULL);
        if(marker){CGEventSetType(marker,29);CGEventSetIntegerValueField(marker,41,33231);CGEventPost(kCGSessionEventTap,marker);CFRelease(marker);}
    }
    return true;
}

// macOS Notification Center uses FluidTouchGesture (27), not a Dock swipe.
// Fields match a physical right-edge two-finger gesture captured on macOS 27.
CGEventRef PocketCreateNotificationEvent(double progress,double delta,double velocity,int phase) {
    if(!isfinite(progress)||!isfinite(delta)||!isfinite(velocity)||fabs(progress)>2||fabs(delta)>2||fabs(velocity)>30||(phase!=1&&phase!=2&&phase!=4&&phase!=8))return NULL;
    bool closing=progress<0;uint32_t motion=closing ? 1:9;
    if(closing){progress=-progress;velocity=-velocity;}
    pthread_once(&apiOnce,loadDockAPI);
    if(!api.create||!api.integer||!api.number||!api.flags||!api.append||!api.attach)return NULL;
    CGEventRef event=CGEventCreate(NULL);if(!event)return NULL;
    CGEventSetType(event,31);CGEventSetIntegerValueField(event,110,27);
    CGEventSetIntegerValueField(event,41,33231);
    CGEventSetIntegerValueField(event,123,motion);CGEventSetIntegerValueField(event,165,motion);
    CGEventSetIntegerValueField(event,132,phase);CGEventSetIntegerValueField(event,134,phase);
    CGEventSetDoubleValueField(event,124,progress);
    CGEventSetDoubleValueField(event,125,-delta);CGEventSetDoubleValueField(event,126,0);
    CGEventSetIntegerValueField(event,138,1);
    CGEventSetIntegerValueField(event,58,CGEventGetTimestamp(event));CGEventSetIntegerValueField(event,169,mach_absolute_time());
    float amount=(float)progress;uint32_t bits;memcpy(&bits,&amount,4);CGEventSetIntegerValueField(event,135,bits);
    float hint;memcpy(&hint,&motion,4);CGEventSetDoubleValueField(event,119,hint);CGEventSetDoubleValueField(event,139,hint);
    CFTypeRef hid=api.create(kCFAllocatorDefault,27,mach_absolute_time(),0);
    if(!hid){CFRelease(event);return NULL;}
    api.flags(hid,(uint32_t)phase<<24);api.integer(hid,(27<<16)+1,motion);api.integer(hid,(27<<16)+5,1);
    api.number(hid,(27<<16)+2,progress);api.number(hid,(27<<16)+3,-delta);api.number(hid,(27<<16)+4,0);
    if(phase==4||phase==8){
        CGEventSetDoubleValueField(event,129,velocity);CGEventSetDoubleValueField(event,130,velocity);
        CFTypeRef child=api.create(kCFAllocatorDefault,9,mach_absolute_time(),0);
        if(!child){CFRelease(hid);CFRelease(event);return NULL;}
        api.number(child,9<<16,velocity);api.number(child,(9<<16)+1,velocity);api.append(hid,child,0);CFRelease(child);
    }
    api.attach(event,hid);CFRelease(hid);
    CFDataRef data=CGEventCreateData(NULL,event);CGEventRef normalized=data?CGEventCreateFromData(NULL,data):NULL;
    if(data)CFRelease(data);CFRelease(event);return normalized;
}
bool PocketPostNotification(double progress,double delta,double velocity,int phase){
    CGEventRef event=PocketCreateNotificationEvent(progress,delta,velocity,phase);if(!event)return false;
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);return true;
}
