import Foundation
import CoreAudio
import AudioToolbox

/// Route this connection only; never change the Mac speaker/output device.
final class MacVirtualMicrophone:MicrophoneAudioRouting {
    static let uid="PocketTrackpadMicrophone_UID"
    private var queue:AudioQueueRef?
    private var device:AudioDeviceID=0,previousInput:AudioDeviceID=0
    private let lock=NSLock()
    private var pcm=[Float](),offset=0,running=false
    enum Failure:Error{case missingDevice,audio(OSStatus)}
    static func deviceID(_ identifier:String=MacVirtualMicrophone.uid)->AudioDeviceID {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyTranslateUIDToDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var uid:CFString=identifier as CFString,result:AudioDeviceID=0,size=UInt32(MemoryLayout<AudioDeviceID>.size)
        let status=AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,UInt32(MemoryLayout<CFString>.size),&uid,&size,&result)
        return status==noErr ? result:0
    }
    private func defaultInput()->AudioDeviceID {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var result:AudioDeviceID=0,size=UInt32(MemoryLayout<AudioDeviceID>.size)
        _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&result);return result
    }
    private func setInput(_ id:AudioDeviceID)throws {
        var id=id,address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        let status=AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,UInt32(MemoryLayout<AudioDeviceID>.size),&id)
        if status != noErr{throw Failure.audio(status)}
    }
    func start()throws{try start(selectAsInput:true)}
    func start(selectAsInput:Bool)throws {
        device=Self.deviceID();guard device != 0 else{throw Failure.missingDevice}
        previousInput=defaultInput()
        if previousInput != 0,previousInput != device {
            var address=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var uid:CFString?,size=UInt32(MemoryLayout<CFString?>.size)
            if AudioObjectGetPropertyData(previousInput,&address,0,nil,&size,&uid)==noErr,let uid{UserDefaults.standard.set(uid as String,forKey:"microphone.previousInputUID")}
        }else if let saved=UserDefaults.standard.string(forKey:"microphone.previousInputUID"){previousInput=Self.deviceID(saved)}
        var format=AudioStreamBasicDescription(mSampleRate:48000,mFormatID:kAudioFormatLinearPCM,mFormatFlags:kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked,mBytesPerPacket:8,mFramesPerPacket:1,mBytesPerFrame:8,mChannelsPerFrame:2,mBitsPerChannel:32,mReserved:0)
        let status=AudioQueueNewOutput(&format,{context,queue,buffer in
            guard let context else{return};Unmanaged<MacVirtualMicrophone>.fromOpaque(context).takeUnretainedValue().fill(queue,buffer)
        },Unmanaged.passUnretained(self).toOpaque(),nil,nil,0,&queue)
        guard status==noErr,let queue else{throw Failure.audio(status)}
        do {
            var uid=Self.uid as CFString
            try check(AudioQueueSetProperty(queue,kAudioQueueProperty_CurrentDevice,&uid,UInt32(MemoryLayout<CFString>.size)))
            lock.lock();running=true;pcm=[];offset=0;lock.unlock()
            for _ in 0..<3 {
                var buffer:AudioQueueBufferRef?
                try check(AudioQueueAllocateBuffer(queue,7680,&buffer))
                guard let buffer else{throw Failure.audio(-1)}
                memset(buffer.pointee.mAudioData,0,7680);buffer.pointee.mAudioDataByteSize=7680
                try check(AudioQueueEnqueueBuffer(queue,buffer,0,nil))
            }
            try check(AudioQueueStart(queue,nil));if selectAsInput{try setInput(device)}
        }catch{stop(restore:true);throw error}
    }
    func append(_ data:Data)throws {
        guard !data.isEmpty,data.count<=16000,data.count%2==0 else{throw Failure.audio(-1)}
        var decoded=[Float]();decoded.reserveCapacity(data.count)
        data.withUnsafeBytes{raw in
            for i in stride(from:0,to:raw.count,by:2){let value=Float(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:i,as:Int16.self)))/32768;decoded.append(value);decoded.append(value)}
        }
        lock.lock();defer{lock.unlock()};guard running else{return}
        if offset>0{pcm.removeFirst(offset);offset=0}
        pcm+=decoded
        let maximum=48000*2*160/1000
        if pcm.count>maximum{pcm.removeFirst(pcm.count-maximum)}
    }
    private func fill(_ queue:AudioQueueRef,_ buffer:AudioQueueBufferRef){
        let capacity=1920
        let output=buffer.pointee.mAudioData.assumingMemoryBound(to:Float.self)
        lock.lock()
        guard running else{lock.unlock();return}
        let count=min(capacity,pcm.count-offset)
        if count>0{pcm.withUnsafeBufferPointer{output.update(from:$0.baseAddress!+offset,count:count)};offset+=count}
        if count<capacity{(output+count).initialize(repeating:0,count:capacity-count)}
        lock.unlock()
        buffer.pointee.mAudioDataByteSize=UInt32(capacity*4);_ = AudioQueueEnqueueBuffer(queue,buffer,0,nil)
    }
    private func pendingDuration()->Double {
        lock.lock();defer{lock.unlock()}
        return min(0.35,Double(pcm.count-offset)/96000+0.1)
    }
    func drain()async{try? await Task.sleep(for:.seconds(pendingDuration()))}
    func stop(restore:Bool){
        lock.lock();running=false;pcm=[];offset=0;lock.unlock()
        if let queue{AudioQueueStop(queue,true);AudioQueueDispose(queue,true)};queue=nil
        // If GPT stop could not be confirmed, leave a silent virtual mic selected.
        // Restoring the physical mic while GPT is still listening would record the room.
        if restore{restoreInput()}
    }
    private func availableOtherInputs()->[AudioDeviceID] {
        var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain),size:UInt32=0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr,size>0,size<=65536 else{return []}
        var devices=[AudioDeviceID](repeating:0,count:Int(size)/MemoryLayout<AudioDeviceID>.size)
        let read=devices.withUnsafeMutableBytes{AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!)}
        guard read==noErr else{return []}
        return devices.filter{id in
            guard id != device else{return false}
            var streams=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioObjectPropertyScopeInput,mElement:kAudioObjectPropertyElementMain),bytes:UInt32=0
            return AudioObjectGetPropertyDataSize(id,&streams,0,nil,&bytes)==noErr && bytes>0
        }.sorted{left,right in
            func builtIn(_ id:AudioDeviceID)->Bool{
                var transport=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyTransportType,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain),value:UInt32=0,bytes:UInt32=4
                return AudioObjectGetPropertyData(id,&transport,0,nil,&bytes,&value)==noErr && value==kAudioDeviceTransportTypeBuiltIn
            }
            return builtIn(left) && !builtIn(right)
        }
    }
    func restoreInput(){
        guard device != 0 else{return}
        if defaultInput()==device {
            let inputs=availableOtherInputs()
            let saved=UserDefaults.standard.string(forKey:"microphone.previousInputUID").map(Self.deviceID) ?? 0
            let target=[previousInput,saved].first{inputs.contains($0)} ?? inputs.first
            if let target{try? setInput(target)}
        }
        if defaultInput() != device{UserDefaults.standard.removeObject(forKey:"microphone.previousInputUID")}
        previousInput=0
    }
    /// Recover a stale virtual default left by an earlier receiver session.
    static func restoreAbandonedInput(){
        let recovery=MacVirtualMicrophone();recovery.device=deviceID();recovery.restoreInput()
    }
    private func check(_ status:OSStatus)throws{if status != noErr{throw Failure.audio(status)}}
    deinit{stop(restore:true)}
}
