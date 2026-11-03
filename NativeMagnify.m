#import <Cocoa/Cocoa.h>
#import "vendor/TouchSynthesis/TouchEvents.h"
// Keep undocumented serialization isolated to the directly distributed Mac host.
bool PocketPostMagnify(double delta, int phase) {
    if (!isfinite(delta) || fabs(delta)>1 || phase<1 || phase>4) return false;
    NSDictionary *info=@{(__bridge NSString*)kTLInfoKeyGestureSubtype:@8,
        (__bridge NSString*)kTLInfoKeyGesturePhase:@(phase),
        (__bridge NSString*)kTLInfoKeyMagnification:@(delta)};
    CGEventRef event=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)info,(__bridge CFArrayRef)@[]);
    if (!event) return false;
    // Fail closed if this OS no longer decodes the undocumented format correctly.
    NSEvent *decoded=[NSEvent eventWithCGEvent:event];
    bool valid=decoded && decoded.type==NSEventTypeMagnify && fabs(decoded.magnification-delta)<0.00001;
    if(valid) { CGEventSetLocation(event,CGEventGetLocation(event));CGEventPost(kCGHIDEventTap,event); }
    CFRelease(event);return valid;
}

// A pan companion needs a gesture payload, not just fields on a bare CGEvent.
// Use the same permissive TouchSynthesis adapter as the magnify path.
CGEventRef PocketCreatePanCompanion(double x,double y,int32_t phase) {
    if(!isfinite(x)||!isfinite(y)||fabs(x)>4000||fabs(y)>4000||
       (phase!=1&&phase!=2&&phase!=4&&phase!=8&&phase!=128))return NULL;
    NSDictionary *parameters=@{(__bridge NSString*)kTLInfoKeyGestureSubtype:@(kTLInfoSubtypeSub6),
        (__bridge NSString*)kTLInfoKeyGesturePhase:@(phase)};
    CGEventRef result=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)parameters,(__bridge CFArrayRef)@[]);
    if(!result)return NULL;
    CGEventSetDoubleValueField(result,116,x);
    CGEventSetDoubleValueField(result,119,y);
    return result;
}

CGEventRef PocketCreateRotate(double degrees,int phase) {
    if(!isfinite(degrees)||fabs(degrees)>180||phase<1||phase>4)return NULL;
    NSDictionary *info=@{(__bridge NSString*)kTLInfoKeyGestureSubtype:@(kTLInfoSubtypeRotate),
        (__bridge NSString*)kTLInfoKeyGesturePhase:@(phase),(__bridge NSString*)kTLInfoKeyRotation:@(degrees)};
    CGEventRef event=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)info,(__bridge CFArrayRef)@[]);
    NSEvent *decoded=event ? [NSEvent eventWithCGEvent:event]:nil;
    if(!decoded||decoded.type!=NSEventTypeRotate||fabs(decoded.rotation-degrees)>0.001){if(event)CFRelease(event);return NULL;}
    return event;
}
bool PocketPostRotate(double degrees,int phase){
    CGEventRef event=PocketCreateRotate(degrees,phase);if(!event)return false;
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);return true;
}
CGEventRef PocketCreateSmartZoom(void){
    NSDictionary *info=@{(__bridge NSString*)kTLInfoKeyGestureSubtype:@(kTLInfoSubtypeSmartMagnify)};
    CGEventRef event=tl_CGEventCreateFromGesture((__bridge CFDictionaryRef)info,(__bridge CFArrayRef)@[]);
    NSEvent *decoded=event ? [NSEvent eventWithCGEvent:event]:nil;
    if(!decoded||decoded.type!=NSEventTypeSmartMagnify){if(event)CFRelease(event);return NULL;}
    return event;
}
bool PocketPostSmartZoom(void){
    CGEventRef event=PocketCreateSmartZoom();if(!event)return false;
    CGEventPost(kCGHIDEventTap,event);CFRelease(event);return true;
}
