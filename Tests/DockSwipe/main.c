#include <ApplicationServices/ApplicationServices.h>
#include <math.h>
#include <stdio.h>
#include <dlfcn.h>
#include <unistd.h>
extern CGEventRef PocketCreateDockEvent(double,double,int,int);
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
return failed?1:0;}
