#include "Loopback.h"
#include <stdatomic.h>
#include <string.h>
#include <limits.h>
#define CAPACITY 65536
static _Atomic int64_t frameTags[CAPACITY];
static _Atomic uint64_t values[CAPACITY];
void PocketLoopbackReset(void){for(int i=0;i<CAPACITY;i++){atomic_store(&frameTags[i],INT64_MIN);atomic_store(&values[i],0);}}
void PocketLoopbackWrite(int64_t first,uint32_t count,const float *stereo){
 for(uint32_t i=0;i<count;i++){
  int64_t frame=first+i;unsigned slot=(uint64_t)frame%CAPACITY;uint64_t packed;memcpy(&packed,stereo+2*i,8);
  atomic_store_explicit(&frameTags[slot],INT64_MIN,memory_order_release);
  atomic_store_explicit(&values[slot],packed,memory_order_release);
  atomic_store_explicit(&frameTags[slot],frame,memory_order_release);
 }
}
void PocketLoopbackRead(int64_t first,uint32_t count,float *stereo){
 memset(stereo,0,count*8);
 for(uint32_t i=0;i<count;i++){
  int64_t frame=first+i;unsigned slot=(uint64_t)frame%CAPACITY;
  if(atomic_load_explicit(&frameTags[slot],memory_order_acquire)!=frame)continue;
  uint64_t packed=atomic_load_explicit(&values[slot],memory_order_acquire);
  if(atomic_load_explicit(&frameTags[slot],memory_order_acquire)==frame)memcpy(stereo+2*i,&packed,8);
 }
}
