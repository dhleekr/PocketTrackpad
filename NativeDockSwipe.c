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
CGEventRef PocketCreateDockEvent(double progress,double velocity,int axis,int phase) {
    if(!isfinite(progress)||!isfinite(velocity)||fabs(progress)>2||fabs(velocity)>10||(axis!=1&&axis!=2)||(phase!=1&&phase!=2&&phase!=4&&phase!=8))return NULL;
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
    float amount=(float)legacyProgress;uint32_t bits;memcpy(&bits,&amount,4);
    CGEventSetIntegerValueField(e,135,bits);
    uint32_t a=(uint32_t)axis;float hint;memcpy(&hint,&a,4);
    CGEventSetDoubleValueField(e,119,hint);
    CGEventSetDoubleValueField(e,139,hint);
    CGEventSetIntegerValueField(e,136,0);
    if(phase==4||phase==8) {
        CGEventSetDoubleValueField(e,129,axis==1?velocity:0);
        CGEventSetDoubleValueField(e,130,axis==2?velocity:0);
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
        if(phase==4||phase==8) {
            CFTypeRef child=api.create(kCFAllocatorDefault,9,mach_absolute_time(),0);
            if(!child){CFRelease(hid);CFRelease(e);return NULL;}
            api.number(child,(9<<16),axis==1?velocity:0);
            api.number(child,(9<<16)+1,axis==2?velocity:0);
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
bool PocketPostDock(double progress,double velocity,int axis,int phase) {
    CGEventRef event=PocketCreateDockEvent(progress,velocity,axis,phase);if(!event)return false;
    CGEventPost(kCGSessionEventTap,event);CFRelease(event);
    if(!usesLivePayload()) {
        CGEventRef marker=CGEventCreate(NULL);
        if(marker){CGEventSetType(marker,29);CGEventSetIntegerValueField(marker,41,33231);CGEventPost(kCGSessionEventTap,marker);CFRelease(marker);}
    }
    return true;
}
