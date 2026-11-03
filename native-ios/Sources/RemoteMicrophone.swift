import SwiftUI
import AVFoundation

/// This button sends microphone audio, not a locally recognized transcript.
@MainActor final class RemoteMicrophone:ObservableObject {
    @Published private(set) var recording=false
    @Published private(set) var preparing=false
    @Published private(set) var finishing=false
    @Published private(set) var sending=false
    @Published private(set) var error:String?
    private var engine:AVAudioEngine?
    private var connection:PadSecureConnection?
    private var sender:Task<Void,Never>?,receiver:Task<Void,Never>?,timeout:Task<Void,Never>?
    private var continuation:AsyncStream<Data>.Continuation?
    private var generation=UUID(),session=UUID().uuidString
    private var outstanding=Set<UInt32>(),sequence:UInt32=0
    private var interruption:Any?
    var busy:Bool{recording || preparing || finishing}
    var status:String {
        if let error{return error}
        return PTText(preparing ? "Starting GPT microphone…":finishing ? "Stopping GPT microphone…":recording ? "iPhone microphone → GPT":"Tap the microphone to speak")
    }
    func toggle(client:TrackpadClient){
        if recording{stop();return}
        if preparing{cancel();return}
        guard !finishing else{return}
        guard client.ready else{client.showConnection=true;return}
        guard client.supportsRemoteMicrophone else{error=PTText("Update the Mac app to use the wireless microphone.");return}
        guard let endpoint=client.microphoneEndpoint else{error=PTText("Pair this Mac before using its microphone.");return}
        cancel();error=nil;preparing=true;let id=generation;session=UUID().uuidString
        Task {
            let allowed=await AVAudioApplication.requestRecordPermission()
            guard generation==id else{return}
            guard allowed else{preparing=false;error=PTText("Allow Microphone in iPhone Settings to dictate.");return}
            do {
                let connection=PadSecureConnection(host:endpoint.host,port:8767,token:endpoint.token)
                self.connection=connection
                timeout=Task{try? await Task.sleep(for:.seconds(28));guard !Task.isCancelled,generation==id else{return};cancel();error=PTText("Could not start the Mac microphone.")}
                try await connection.connect()
                guard generation==id else{return}
                try await command("start",using:connection)
                let result=try await connection.receive()
                guard generation==id else{return}
                guard let response=try JSONSerialization.jsonObject(with:result) as? [String:String],response["session"]==session,response["status"]=="ready" else{
                    let status=(try? JSONSerialization.jsonObject(with:result) as? [String:String])?["status"] ?? "connection"
                    throw Failure.remote(status)
                }
                try startAudio(connection:connection,id:id)
                timeout?.cancel();timeout=nil;preparing=false;recording=true
                receiver=Task{[weak self] in await self?.receive(using:connection,id:id)}
                interruption=NotificationCenter.default.addObserver(forName:AVAudioSession.interruptionNotification,object:nil,queue:.main){[weak self] _ in Task{@MainActor in self?.stop()}}
            }catch {
                guard generation==id else{return};cancel()
                if case Failure.remote(let status)=error {
                    let message:String
                    switch status {
                    case "install": message="Set up the microphone in the Mac app first."
                    case "restartGPT": message="GPT microphone connected. Quit and reopen GPT once, then tap the microphone again."
                    case "shortcutConfiguration": message="Could not register the GPT microphone shortcut. Your existing shortcuts were preserved."
                    case "alreadyRecording": message="Finish the existing Mac recording before starting the iPhone microphone."
                    case "controlPermission": message="Allow PocketTrackpad in Mac Accessibility settings."
                    case "openGPT": message="Click the GPT input window on your Mac before starting the microphone."
                    case "dictateUnavailable": message="Could not find the Dictate button in the Mac app."
                    case "dictateUnconfirmed": message="Could not confirm that Dictate started. Check the Mac app."
                    case "gpt": message="Could not open Dictate in the Mac app."
                    default: message="Could not start the Mac microphone."
                    }
                    self.error=PTText(message)
                }else{self.error=PTText("Microphone needs a Wi-Fi connection to this Mac. Trackpad connection is unchanged.")}
            }
        }
    }
    private func startAudio(connection:PadSecureConnection,id:UUID)throws {
        let audioSession=AVAudioSession.sharedInstance()
        try audioSession.setCategory(.record,mode:.measurement,options:.duckOthers)
        try audioSession.setPreferredSampleRate(48000);try audioSession.setPreferredIOBufferDuration(0.02);try audioSession.setActive(true)
        let engine=AVAudioEngine(),input=engine.inputNode,format=input.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0,
              let target=AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48000,channels:1,interleaved:false),
              let converter=AVAudioConverter(from:format,to:target) else{throw Failure.audio}
        let (stream,continuation)=AsyncStream<Data>.makeStream(bufferingPolicy:.bufferingNewest(16));self.continuation=continuation
        input.installTap(onBus:0,bufferSize:960,format:format){pcm,_ in
            let frames=AVAudioFrameCount(ceil(Double(pcm.frameLength)*48000/format.sampleRate))+16
            guard let output=AVAudioPCMBuffer(pcmFormat:target,frameCapacity:frames) else{return}
            var supplied=false,conversionError:NSError?
            converter.convert(to:output,error:&conversionError){_,state in
                if supplied{state.pointee = .noDataNow;return nil};supplied=true;state.pointee = .haveData;return pcm
            }
            guard conversionError==nil,let values=output.floatChannelData?[0] else{return}
            var offset=0
            while offset<Int(output.frameLength){
                let count=min(960,Int(output.frameLength)-offset)
                var packet=Data(count:count*2)
                packet.withUnsafeMutableBytes{raw in
                    for index in 0..<count{
                        let sample=values[offset+index],safe=sample.isFinite ? min(0.999969,max(-1,sample)):0
                        raw.storeBytes(of:Int16(safe*32768).littleEndian,toByteOffset:index*2,as:Int16.self)
                    }
                }
                continuation.yield(packet);offset+=count
            }
        }
        self.engine=engine;engine.prepare();try engine.start()
        sender=Task{[weak self] in
            do {
                for await pcm in stream {
                    guard let self,self.generation==id,!Task.isCancelled else{return}
                    while self.outstanding.count>=6 {
                        try await Task.sleep(for:.milliseconds(5));guard self.generation==id else{return}
                    }
                    try Task.checkCancellation()
                    self.sequence &+= 1;let sequence=self.sequence
                    let header=Data([1,UInt8(sequence>>24),UInt8((sequence>>16)&255),UInt8((sequence>>8)&255),UInt8(sequence&255)])
                    self.outstanding.insert(sequence);try await connection.send(header+pcm)
                }
            }catch{
                guard let self,self.generation==id,!Task.isCancelled else{return}
                self.cancel();self.error=PTText("Audio connection lost. Check that GPT has stopped recording.")
            }
        }
    }
    private func command(_ op:String,using connection:PadSecureConnection) async throws {
        try await connection.send(JSONSerialization.data(withJSONObject:["op":op,"session":session]))
    }
    private func receive(using connection:PadSecureConnection,id:UUID) async {
        do {
            while generation==id,!Task.isCancelled {
                let data=try await connection.receive()
                guard generation==id else{return}
                guard let message=try JSONSerialization.jsonObject(with:data) as? [String:String] else{throw Failure.audio}
                if let value=message["ack"],let ack=UInt32(value){outstanding=outstanding.filter{$0>ack};continue}
                if message["session"]==session,["stopped","ended"].contains(message["status"] ?? ""){cancel();return}
                if message["session"]==session,message["status"]=="checkGPT"{cancel();error=PTText("Stop recording in GPT on your Mac. The iPhone microphone is already off.");return}
            }
        }catch{guard generation==id else{return};cancel();self.error=PTText("Audio connection lost. Check that GPT has stopped recording.")}
    }
    func stop(){
        guard recording else{return};recording=false;finishing=true;releaseAudio();continuation?.finish();continuation=nil
        guard let connection else{cancel();return};let id=generation
        Task{
            await sender?.value
            guard generation==id else{return};sender=nil
            let deadline=ProcessInfo.processInfo.systemUptime+1.5
            do{
                while !outstanding.isEmpty {
                    guard generation==id else{return}
                    if ProcessInfo.processInfo.systemUptime>deadline{throw PadSecureLink.Failure.timeout}
                    try await Task.sleep(for:.milliseconds(10))
                }
                try await command("stop",using:connection)
            }catch{if generation==id{cancel();self.error=PTText("Audio connection lost. Check that GPT has stopped recording.")}}
        }
        timeout=Task{try? await Task.sleep(for:.seconds(25));guard !Task.isCancelled,generation==id else{return};cancel();error=PTText("Stop recording in GPT on your Mac. The iPhone microphone is already off.")}
    }
    private func releaseAudio(){if let engine{engine.stop();engine.inputNode.removeTap(onBus:0)};engine=nil;try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation)}
    func cancel(){
        generation=UUID();releaseAudio();sender?.cancel();sender=nil;receiver?.cancel();receiver=nil;timeout?.cancel();timeout=nil
        continuation?.finish();continuation=nil;connection?.cancel();connection=nil
        outstanding=[];sequence=0;preparing=false;recording=false;finishing=false;sending=false
        if let interruption{NotificationCenter.default.removeObserver(interruption)};interruption=nil
    }
    private enum Failure:Error{case audio,remote(String)}
}
