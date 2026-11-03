#pragma once
#include <stdint.h>
void PocketLoopbackReset(void);
void PocketLoopbackWrite(int64_t firstFrame,uint32_t count,const float *stereo);
void PocketLoopbackRead(int64_t firstFrame,uint32_t count,float *stereo);
