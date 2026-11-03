// Local-test receiver only: system gesture metadata, never keys, text or screen pixels.
#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <sys/stat.h>
static FILE *capture;
static CFMachPortRef captureTap,sessionTap;
static CFRunLoopSourceRef captureSource,sessionSource;
static unsigned captured;
static CGEventRef observe(CGEventTapProxy proxy,CGEventType type,CGEventRef event,void *context){
 (void)proxy;
 if(type==kCGEventTapDisabledByTimeout || type==kCGEventTapDisabledByUserInput){if(captureTap)CGEventTapEnable(captureTap,true);return event;}
 if((type<29 || type>32) || !capture || captured>=2048)return event;
 long long subtype=CGEventGetIntegerValueField(event,110);

 fprintf(capture,"{\"tap\":\"%s\",\"eventType\":%u,\"sourcePID\":%lld,\"subtype\":%lld,\"timestamp\":%llu,\"axis\":%lld,\"progress\":%.9g,\"phase\":%lld,\"phase2\":%lld,\"velocityX\":%.9g,\"velocityY\":%.9g,\"data\":\"",(const char *)context,type,(long long)CGEventGetIntegerValueField(event,41),subtype,(unsigned long long)CGEventGetTimestamp(event),(long long)CGEventGetIntegerValueField(event,123),CGEventGetDoubleValueField(event,124),(long long)CGEventGetIntegerValueField(event,132),(long long)CGEventGetIntegerValueField(event,134),CGEventGetDoubleValueField(event,129),CGEventGetDoubleValueField(event,130));
 CFDataRef bytes=CGEventCreateData(NULL,event);
 if(bytes){const UInt8 *p=CFDataGetBytePtr(bytes);CFIndex n=CFDataGetLength(bytes);for(CFIndex i=0;i<n;i++)fprintf(capture,"%02x",p[i]);CFRelease(bytes);}
 fprintf(capture,"\"}\n");fflush(capture);captured++;return event;
}
void PocketStopGestureCapture(void){
 if(sessionTap){CGEventTapEnable(sessionTap,false);CFMachPortInvalidate(sessionTap);CFRelease(sessionTap);sessionTap=NULL;}
 if(sessionSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),sessionSource,kCFRunLoopCommonModes);CFRelease(sessionSource);sessionSource=NULL;}
 if(captureTap){CGEventTapEnable(captureTap,false);CFMachPortInvalidate(captureTap);CFRelease(captureTap);captureTap=NULL;}
 if(captureSource){CFRunLoopRemoveSource(CFRunLoopGetMain(),captureSource,kCFRunLoopCommonModes);CFRelease(captureSource);captureSource=NULL;}
 if(capture){fclose(capture);capture=NULL;}
}
bool PocketStartGestureCapture(const char *path){
 PocketStopGestureCapture();captured=0;
 capture=fopen(path,"w");if(!capture)return false;chmod(path,0600);
 CGEventMask mask=(((CGEventMask)1)<<29)|(((CGEventMask)1)<<30)|(((CGEventMask)1)<<31)|(((CGEventMask)1)<<32);
 captureTap=CGEventTapCreate(kCGHIDEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,observe,"hid");
 if(!captureTap){PocketStopGestureCapture();return false;}
 sessionTap=CGEventTapCreate(kCGSessionEventTap,kCGHeadInsertEventTap,kCGEventTapOptionListenOnly,mask,observe,"session");
 if(sessionTap){sessionSource=CFMachPortCreateRunLoopSource(NULL,sessionTap,0);CFRunLoopAddSource(CFRunLoopGetMain(),sessionSource,kCFRunLoopCommonModes);CGEventTapEnable(sessionTap,true);}
 captureSource=CFMachPortCreateRunLoopSource(NULL,captureTap,0);CFRunLoopAddSource(CFRunLoopGetMain(),captureSource,kCFRunLoopCommonModes);CGEventTapEnable(captureTap,true);return true;
}
