#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdio.h>
#include <dlfcn.h>
#include <unistd.h>
extern CGEventRef PocketCreateDockMotionEvent(double,double,double,int,int);
extern CGEventRef PocketCreateDockEvent(double,double,int,int);
extern CGEventRef PocketCreateNotificationEvent(double,double,double,int);
int main(void){int failed=0;for(int axis=1;axis<=2;axis++)for(int phase=1;phase<=8;phase*=2){CGEventRef e=PocketCreateDockEvent(0.4,0.5,axis,phase);int ok=e && CGEventGetIntegerValueField(e,(CGEventField)110)==23 && CGEventGetIntegerValueField(e,(CGEventField)123)==axis && CGEventGetIntegerValueField(e,(CGEventField)132)==phase && fabs(fabs(CGEventGetDoubleValueField(e,(CGEventField)124))-0.4)<0.00001;printf("%s native system gesture axis=%d phase=%d\n",ok?"PASS":"FAIL",axis,phase);failed+=!ok;if(e)CFRelease(e);}CGEventRef reverse=PocketCreateDockEvent(0.3,-0.5,2,4);int ok=reverse && CGEventGetIntegerValueField(reverse,(CGEventField)132)==8;printf("%s reversal cancels instead of committing\n",ok?"PASS":"FAIL");failed+=!ok;if(reverse)CFRelease(reverse);ok=PocketCreateDockEvent(NAN,0,2,1)==NULL && PocketCreateDockEvent(0,0,7,1)==NULL;printf("%s malformed gesture rejected\n",ok?"PASS":"FAIL");failed+=!ok;if(__builtin_available(macOS 27.0,*)) {
CFTypeRef(*copy)(CGEventRef)=dlsym(RTLD_DEFAULT,"CGEventCopyIOHIDEvent");
CFIndex(*integer)(CFTypeRef,uint32_t)=dlsym(RTLD_DEFAULT,"IOHIDEventGetIntegerValue");
double(*number)(CFTypeRef,uint32_t)=dlsym(RTLD_DEFAULT,"IOHIDEventGetDoubleValue");
uint32_t(*flags)(CFTypeRef)=dlsym(RTLD_DEFAULT,"IOHIDEventGetEventFlags");
for(int axis=1;axis<=2;axis++)for(int phase=1;phase<=8;phase*=2){
CGEventRef event=PocketCreateDockEvent(0.015,0.1,axis,phase);
CFTypeRef hid=event&&copy?copy(event):NULL;
int matched=hid&&integer&&number&&flags&&integer(hid,(23<<16)+1)==axis&&integer(hid,(23<<16)+5)==3&&fabs(number(hid,(23<<16)+2)-(axis==1 ? -0.015:0.015))<0.00002&&flags(hid)==(uint32_t)phase<<24&&(axis==1 ? CGEventGetDoubleValueField(event,124)>0:CGEventGetDoubleValueField(event,124)<0)&&CGEventGetIntegerValueField(event,101)==0&&CGEventGetIntegerValueField(event,41)==getpid();
printf("%s live HID payload axis=%d phase=%d\n",matched?"PASS":"FAIL",axis,phase);failed+=!matched;
if(hid)CFRelease(hid);if(event)CFRelease(event);
}}
if(__builtin_available(macOS 27.0,*)) {
CGEventRef close=PocketCreateDockEvent(-0.273438,-5.335236,2,4);
int velocity=close && CGEventGetIntegerValueField(close,138)==3 && CGEventGetIntegerValueField(close,136)==1 && fabs(CGEventGetDoubleValueField(close,129)-5.335236)<0.0001 && fabs(CGEventGetDoubleValueField(close,130)-5.335236)<0.0001;
printf("%s Mission Control close velocity matches physical trackpad in both wrapper fields\n",velocity?"PASS":"FAIL");failed+=!velocity;if(close)CFRelease(close);
}
CGEventRef scale=PocketCreateDockEvent(0.6,0.0,3,2);
int scaling=scale && CGEventGetIntegerValueField(scale,123)==3;
printf("%s continuous desktop scale motion is supported\n",scaling?"PASS":"FAIL");failed+=!scaling;if(scale)CFRelease(scale);
CGEventRef notification=PocketCreateNotificationEvent(0.56,0.15,18.9,4);
CFTypeRef(*copyFluid)(CGEventRef)=dlsym(RTLD_DEFAULT,"CGEventCopyIOHIDEvent");
CFIndex(*getFluidInt)(CFTypeRef,uint32_t)=dlsym(RTLD_DEFAULT,"IOHIDEventGetIntegerValue");
double(*getFluidDouble)(CFTypeRef,uint32_t)=dlsym(RTLD_DEFAULT,"IOHIDEventGetDoubleValue");
CFTypeRef fluid=notification&&copyFluid?copyFluid(notification):NULL;
int fluidOK=notification&&CGEventGetIntegerValueField(notification,138)==1&&fabs(CGEventGetDoubleValueField(notification,125)+0.15)<0.0001&&CGEventGetType(notification)==31&&CGEventGetIntegerValueField(notification,110)==27&&fluid&&getFluidInt&&getFluidDouble&&getFluidInt(fluid,(27<<16)+1)==9&&getFluidInt(fluid,(27<<16)+5)==1&&fabs(getFluidDouble(fluid,(27<<16)+2)-0.56)<0.0001&&fabs(getFluidDouble(fluid,(27<<16)+3)+0.15)<0.0001;
printf("%s Notification Center matches physical FluidTouchGesture payload\n",fluidOK?"PASS":"FAIL");failed+=!fluidOK;
if(fluid)CFRelease(fluid);if(notification)CFRelease(notification);
CGEventRef closePanel=PocketCreateNotificationEvent(-0.6,-0.1,-3,4);
int closeOK=closePanel && CGEventGetIntegerValueField(closePanel,123)==1 && fabs(CGEventGetDoubleValueField(closePanel,124)-0.6)<0.0001 && fabs(CGEventGetDoubleValueField(closePanel,125)-0.1)<0.0001 && fabs(CGEventGetDoubleValueField(closePanel,129)-3)<0.0001;
printf("%s Notification Center close uses ordinary fluid motion and positive native progress\n",closeOK?"PASS":"FAIL");failed+=!closeOK;if(closePanel)CFRelease(closePanel);
CGEventRef down=PocketCreateDockMotionEvent(-0.02,-0.02,0,2,1);
int downOK=down && fabs(CGEventGetDoubleValueField(down,126)+0.02)<0.0001;
CFTypeRef downHID=down&&copyFluid?copyFluid(down):NULL;
if(__builtin_available(macOS 27.0,*)){downOK=downOK && downHID && fabs(getFluidDouble(downHID,(23<<16)+4)+0.02)<0.0001;}
printf("%s Mission Control close carries physical per-frame vertical displacement\n",downOK?"PASS":"FAIL");failed+=!downOK;
if(downHID)CFRelease(downHID);if(down)CFRelease(down);
return failed?1:0;}
