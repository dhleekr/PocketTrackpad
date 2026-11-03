#import <Cocoa/Cocoa.h>
#include <assert.h>
extern CGEventRef PocketCreateRotate(double,int);
extern CGEventRef PocketCreateSmartZoom(void);
int main(void){@autoreleasepool{
 CGEventRef rotate=PocketCreateRotate(15,2);assert(rotate);
 NSEvent *event=[NSEvent eventWithCGEvent:rotate];assert(event.type==NSEventTypeRotate);assert(fabs(event.rotation-15)<.001);CFRelease(rotate);
 assert(!PocketCreateRotate(NAN,2));assert(!PocketCreateRotate(181,2));assert(!PocketCreateRotate(1,9));
 CGEventRef smart=PocketCreateSmartZoom();assert(smart);assert([NSEvent eventWithCGEvent:smart].type==NSEventTypeSmartMagnify);CFRelease(smart);
 puts("PASS native rotation and smart magnify decode as actual AppKit gesture events; invalid values rejected");
}}
