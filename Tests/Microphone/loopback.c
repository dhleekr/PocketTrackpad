#include "../../virtual-microphone/Loopback.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void){
 float input[8]={.1f,.2f,.3f,.4f,.5f,.6f,.7f,.8f},output[8];
 PocketLoopbackReset();PocketLoopbackRead(100,4,output);for(int i=0;i<8;i++)assert(output[i]==0);
 PocketLoopbackWrite(100,4,input);PocketLoopbackRead(100,4,output);for(int i=0;i<8;i++)assert(output[i]==input[i]);
 PocketLoopbackRead(104,4,output);for(int i=0;i<8;i++)assert(output[i]==0);
 PocketLoopbackWrite(100+65536,4,input);PocketLoopbackRead(100,4,output);for(int i=0;i<8;i++)assert(output[i]==0);
 PocketLoopbackReset();PocketLoopbackRead(100+65536,4,output);for(int i=0;i<8;i++)assert(output[i]==0);
 puts("PASS microphone loopback: audio round-trip, silence on underflow, no stale replay, session erase");
}
