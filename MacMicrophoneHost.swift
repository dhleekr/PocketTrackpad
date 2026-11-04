import Foundation
import Network

/// A separate authenticated TLS socket keeps audio out of the cursor/gesture queue.
@MainActor final class MacMicrophoneHost {
    private final class Session {
        let connection:NWConnection?
        let externalSend:((Data)->Void)?
        var decoder=PadFrameDecoder(),last=ProcessInfo.processInfo.systemUptime
        var token:String?,started=false,finishing=false
        init(_ connection:NWConnection){self.connection=connection;externalSend=nil}
        init(send:@escaping (Data)->Void){connection=nil;externalSend=send}
    }
    private let listener:NWListener
    private let queue=DispatchQueue(label:"PocketTrackpad.microphone.network",qos:.userInitiated)
    private var sessions=[UUID:Session](),owner:UUID?
    private var bluetoothID:UUID?,bluetoothPeer:UUID?
    private var timer:Timer?
    private var route:(any MicrophoneAudioRouting)?
    private var controls:(any MicrophoneAppControlling)?
    private var finishingTask:Task<Bool,Never>?
    private var pendingRestoration:(route:any MicrophoneAudioRouting,controls:any MicrophoneAppControlling)?
    private let report:(String)->Void
    private let makeControls:@MainActor ()->any MicrophoneAppControlling
    private let makeRoute:()->any MicrophoneAudioRouting
    private let deviceAvailable:()->Bool
    init(token:String,port:UInt16=8767,
         makeControls:@escaping @MainActor ()->any MicrophoneAppControlling={@MainActor in GPTMicrophoneControl()},
         makeRoute:@escaping ()->any MicrophoneAudioRouting={MacVirtualMicrophone()},
         deviceAvailable:@escaping ()->Bool={MacVirtualMicrophone.deviceID() != 0},
         report:@escaping (String)->Void)throws {
        self.report=report;self.makeControls=makeControls;self.makeRoute=makeRoute;self.deviceAvailable=deviceAvailable
        listener=try NWListener(using:PadSecureLink.parameters(token:token),on:NWEndpoint.Port(rawValue:port)!)
        listener.newConnectionHandler={[weak self] connection in Task{@MainActor in self?.accept(connection)}}
        listener.start(queue:queue)
        let timer=Timer(timeInterval:0.25,repeats:true){[weak self] _ in Task{@MainActor in
            guard let self else{return}
            if let pending=self.pendingRestoration,pending.controls.hasFinished(){pending.route.restoreInput();self.pendingRestoration=nil;self.report("Microphone stopped")}
            for (id,session) in self.sessions {
                if session.started,self.controls?.hasFinished()==true {
                    session.started=false;self.send(["status":"ended","session":session.token ?? ""],to:id);await self.close(id,delay:true)
                }else if ProcessInfo.processInfo.systemUptime-session.last>(session.started ? 2:30){await self.close(id)}
            }
        }}
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func accept(_ connection:NWConnection){
        guard sessions.count<2 else{connection.cancel();return}
        let id=UUID();sessions[id]=Session(connection)
        connection.stateUpdateHandler={[weak self] state in Task{@MainActor in
            guard let self else{return}
            switch state {
            case .ready:
                self.report("Microphone link authenticated")
                guard self.owner==nil else{connection.cancel();self.sessions.removeValue(forKey:id);return}
                self.owner=id;self.receive(id)
            case .failed,.cancelled:await self.close(id)
            default:break
            }
        }}
        connection.start(queue:queue)
    }
    private func receive(_ id:UUID){
        guard let session=sessions[id],owner==id,let connection=session.connection else{return}
        connection.receive(minimumIncompleteLength:1,maximumLength:8192){[weak self] data,_,complete,error in Task{@MainActor in
            guard let self,let session=self.sessions[id] else{return}
            guard error==nil,let data,!data.isEmpty else{await self.close(id);return}
            do {
                session.last=ProcessInfo.processInfo.systemUptime
                for packet in try session.decoder.append(data){if try await self.process(packet,id:id)==false{return}}

                if complete{await self.close(id)}else{self.receive(id)}
            }catch{await self.close(id)}
        }}
    }
    private func process(_ packet:Data,id:UUID)async throws->Bool {
        guard let session=sessions[id],owner==id else{return false}
        session.last=ProcessInfo.processInfo.systemUptime
        if packet.first==1 || packet.first==2 {
            if session.finishing{return true}
            guard session.started,packet.count>5,packet.count<=16005 else{throw PadSecureLink.Failure.invalidFrame}
            let sequence=packet.dropFirst().prefix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
            let encoded=Data(packet.dropFirst(5))
            try self.route?.append(packet.first==2 ? MicrophoneADPCM.decode48k(encoded):encoded)
            self.send(["ack":String(sequence),"session":session.token ?? ""],to:id)
        }else{
            guard packet.count<4096,let command=try JSONSerialization.jsonObject(with:packet) as? [String:String],let op=command["op"],let token=command["session"],UUID(uuidString:token) != nil else{throw PadSecureLink.Failure.invalidFrame}
            if op=="capabilities",session.token==nil {
                self.send(capabilities(session:token),to:id)
            }else if op=="start",session.token==nil {
                session.token=token
                self.report("Microphone start received")
                do {
                    if let pending=self.pendingRestoration {
                        guard pending.controls.hasFinished() else{throw GPTMicrophoneControl.Failure.notConfirmed}
                        pending.route.restoreInput();self.pendingRestoration=nil
                    }
                    guard self.deviceAvailable() else{throw MacVirtualMicrophone.Failure.missingDevice}
                    self.report("Finding GPT microphone button")
                    let controls=self.makeControls();self.controls=controls;try await controls.prepare()
                    guard self.sessions[id] === session,self.owner==id else{return false}
                    self.report("Starting virtual microphone")
                    let route=self.makeRoute();try route.start();self.route=route
                    self.report("Opening GPT microphone")
                    try await controls.start()
                    guard self.sessions[id] === session else{return false}
                    session.started=true;self.send(["status":"ready","session":token],to:id);self.report("iPhone microphone active")
                }catch{
                    let status:String
                    if let failure=error as? GPTMicrophoneControl.Failure {
                        switch failure {
                        case .permission: status="controlPermission"
                        case .openGPT: status="openGPT"
                        case .setupRequired: status="dictationSetup"
                        case .buttonUnavailable,.ambiguous: status="dictateUnavailable"
                        case .notConfirmed: status="dictateUnconfirmed"
                        case .alreadyRecording: status="alreadyRecording"
                        }
                    }else{status=(error as? MacVirtualMicrophone.Failure).map{if case .missingDevice=$0{return "install"};return "audio"} ?? "gpt"}
                    self.send(["status":status,"session":token],to:id)
                    await self.close(id,delay:true)
                    self.report("Microphone start failed: \(String(describing:error))")
                    return false
                }
            }else if op=="stop",session.token==token {
                session.started=false;session.finishing=true
                let confirmed=await self.finishRecording(drain:true)
                self.send(["status":confirmed ? "stopped":"checkGPT","session":token],to:id)
                await self.close(id,delay:true);return false
            }else{throw PadSecureLink.Failure.invalidFrame}
        }
        return true
    }
    func receiveBluetooth(_ packet:Data,peer:UUID,send:@escaping (Data)->Void)async {
        if let bluetoothPeer,bluetoothPeer != peer{return}
        if let command=(try? JSONSerialization.jsonObject(with:packet)) as? [String:String],let token=command["session"],UUID(uuidString:token) != nil {
            if command["op"]=="capabilities"{if let data=try? JSONSerialization.data(withJSONObject:capabilities(session:token)){send(data)};return}
            if command["op"]=="cancel"{
                if let id=bluetoothID,sessions[id]?.token==token{await close(id)}
                return
            }
        }
        if bluetoothID==nil {
            guard owner==nil else{
                if let request=(try? JSONSerialization.jsonObject(with:packet)) as? [String:String],let token=request["session"],let data=try? JSONSerialization.data(withJSONObject:["status":"alreadyRecording","session":token]){send(data)}
                return
            }
            let id=UUID();sessions[id]=Session(send:send);bluetoothID=id;bluetoothPeer=peer;owner=id
            report("Bluetooth microphone link authenticated")
        }
        guard let id=bluetoothID else{return}
        do{_ = try await process(packet,id:id)}catch{await close(id)}
    }
    func closeBluetooth(peer:UUID)async {
        guard bluetoothPeer==peer,let id=bluetoothID else{return}
        await close(id)
    }
    private func capabilities(session:String)->[String:String]{
        ["status":"capabilities","session":session,"shortcutSetup":"explicit","audioTransport":"selected-v1","stopPriority":"1","receiverVersion":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "development"]
    }
    private func send(_ object:[String:String],to id:UUID){
        guard let session=sessions[id],let data=try? JSONSerialization.data(withJSONObject:object) else{return}
        if let externalSend=session.externalSend{externalSend(data)}else if let frame=try? PadSecureLink.frame(data){session.connection?.send(content:frame,completion:.contentProcessed{_ in})}
    }
    private func finishRecording(drain:Bool=false) async->Bool {
        if let finishingTask{return await finishingTask.value}
        let route=self.route,controls=self.controls;self.route=nil;self.controls=nil
        let task=Task{@MainActor in
            if drain{await route?.drain()}
            route?.stop(restore:false)
            let confirmed=await controls?.stop() ?? true
            if confirmed{route?.restoreInput()}
            else if let route,let controls{pendingRestoration=(route,controls)}
            report(confirmed ? "Microphone stopped":"Stop recording in GPT; virtual microphone is silent")
            return confirmed
        }
        finishingTask=task;let result=await task.value;finishingTask=nil;return result
    }
    private func close(_ id:UUID,delay:Bool=false) async {
        guard let session=sessions.removeValue(forKey:id) else{return}
        if bluetoothID==id{bluetoothID=nil;bluetoothPeer=nil}
        if owner==id{_ = await finishRecording();owner=nil}
        if delay{try? await Task.sleep(for:.milliseconds(100))}
        session.connection?.cancel()
    }
    func shutdown() async {
        timer?.invalidate();listener.cancel()
        for id in Array(sessions.keys){
            if let session=sessions[id]{session.started=false;send(["status":"ended","session":session.token ?? ""],to:id)}
            await close(id)
        }
        // Explicit Quit restores the user's input even if the target app did not confirm stop.
        // Do not send another toggle: an unconfirmed prior stop might already have succeeded.
        if let pending=pendingRestoration{pending.route.restoreInput();pendingRestoration=nil}
    }
    deinit{timer?.invalidate();listener.cancel();for session in sessions.values{session.connection?.cancel()}}
}
