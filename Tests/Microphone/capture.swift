import Foundation
import AudioToolbox
import CoreAudio

final class Capture {
 let lock=NSLock();var peak:Float=0,frames=0
 func read(_ buffer:AudioQueueBufferRef){
  let count=Int(buffer.pointee.mAudioDataByteSize)/4,values=buffer.pointee.mAudioData.assumingMemoryBound(to:Float.self)
  lock.lock();for i in 0..<count{peak=max(peak,abs(values[i]))};frames+=count/2;lock.unlock()
 }
 func snapshot()->(Float,Int){lock.lock();defer{lock.unlock()};return(peak,frames)}
 func reset(){lock.lock();peak=0;frames=0;lock.unlock()}
}
func check(_ status:OSStatus)throws{if status != noErr{throw NSError(domain:"CoreAudioProbe",code:Int(status))}}
func run()throws {
 guard MacVirtualMicrophone.deviceID() != 0 else{throw NSError(domain:"Install the PocketTrackpad microphone first",code:1)}
 let capture=Capture(),route=MacVirtualMicrophone()
 // Do not select a default microphone and never address ChatGPT or Codex.
 try route.start(selectAsInput:false)
 var format=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
 var input:AudioQueueRef?
 try check(AudioQueueNewInput(&format,{context,queue,buffer,_,_,_ in
  if let context{Unmanaged<Capture>.fromOpaque(context).takeUnretainedValue().read(buffer)}
  AudioQueueEnqueueBuffer(queue,buffer,0,nil)
 },Unmanaged.passUnretained(capture).toOpaque(),nil,nil,0,&input))
 guard let input else{fatalError()}
 defer{AudioQueueStop(input,true);AudioQueueDispose(input,true);route.stop(restore:false)}
 var uid=MacVirtualMicrophone.uid as CFString
 try check(AudioQueueSetProperty(input,kAudioQueueProperty_CurrentDevice,&uid,UInt32(MemoryLayout<CFString>.size)))
 for _ in 0..<3{var buffer:AudioQueueBufferRef?;try check(AudioQueueAllocateBuffer(input,7680,&buffer));try check(AudioQueueEnqueueBuffer(input,buffer!,0,nil))}
 try check(AudioQueueStart(input,nil))
 var sample=0
 for _ in 0..<75 {
  var data=Data(count:1920)
  data.withUnsafeMutableBytes{raw in for i in 0..<960{let value=Int16(sin(Double(sample+i)*2*Double.pi*440/48000)*3276);raw.storeBytes(of:value.littleEndian,toByteOffset:i*2,as:Int16.self)}}
  sample+=960;try route.append(data);Thread.sleep(forTimeInterval:0.02)
 }
 let signal=capture.snapshot();guard signal.0>0.05,signal.0<0.2 else{throw NSError(domain:"No synthetic audio received through HAL",code:2)}
 route.stop(restore:false);Thread.sleep(forTimeInterval:0.3);capture.reset();Thread.sleep(forTimeInterval:0.25)
 let silence=capture.snapshot();guard silence.0<0.0001 else{throw NSError(domain:"Audio did not become silent after stop",code:3)}
 print("PASS real HAL audio: tone peak",signal.0,"captured frames",signal.1,"after-stop peak",silence.0)
}
do{try run()}catch{print("FAIL",error);exit(1)}
