// Exercise the driver's actual Core Audio property contract without installing it.
#include "../../virtual-microphone/vendor/PocketAudio.c"
#include <assert.h>
int main(void) {
 AudioObjectPropertyAddress address={kAudioSelectorControlPropertyAvailableItems,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
 UInt32 size=0,items[4]={99,99,99,99};
 assert(NullAudio_GetControlPropertyDataSize(gAudioServerPlugInDriverRef,kObjectID_DataSource_Input_Master,0,&address,0,NULL,&size)==noErr);
 assert(size==sizeof(UInt32));
 assert(NullAudio_GetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_DataSource_Input_Master,0,&address,0,NULL,sizeof(items),&size,items)==noErr);
 assert(size==sizeof(UInt32) && items[0]==0 && items[1]==99);
 address.mSelector=kAudioSelectorControlPropertyItemName;
 UInt32 item=0;CFStringRef name=NULL;
 assert(NullAudio_GetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_DataSource_Input_Master,0,&address,sizeof(item),&item,sizeof(name),&size,&name)==noErr);
 assert(CFEqual(name,CFSTR("iPhone Microphone")));CFRelease(name);
 item=1;
 assert(NullAudio_GetControlPropertyData(gAudioServerPlugInDriverRef,kObjectID_DataSource_Input_Master,0,&address,sizeof(item),&item,sizeof(name),&size,&name)!=noErr);
 puts("PASS exactly one microphone source; phantom sources rejected");
 return 0;
}
