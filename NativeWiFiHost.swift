import Foundation
import Network

// This receiver has no Python, web-server or developer-tool runtime dependency.
final class NativeWiFiHost {
    private let queue=DispatchQueue(label:"local.pockettrackpad.secure.host",qos:.userInteractive)
    private var listener:NWListener?
    private var sessions=[UUID:(connection:NWConnection,decoder:PadFrameDecoder,last:Date)]()
    private var active:UUID?
    private var timer:DispatchSourceTimer?
    private let apply:([String:Any])->String
    private let report:(String)->Void
    init(token:String,port:UInt16=8766,apply:@escaping ([String:Any])->String,report:@escaping (String)->Void)throws{
        self.apply=apply;self.report=report
        let listener=try NWListener(using:PadSecureLink.parameters(token:token),on:NWEndpoint.Port(rawValue:port)!);self.listener=listener;listener.newConnectionLimit=8
        listener.stateUpdateHandler={[weak self] state in if case .failed=state{self?.report("Wi-Fi unavailable")}}
        listener.newConnectionHandler={[weak self] connection in self?.accept(connection)}
        listener.start(queue:queue)
        let timer=DispatchSource.makeTimerSource(queue:queue);self.timer=timer;timer.schedule(deadline:.now()+1,repeating:1)
        timer.setEventHandler{[weak self] in guard let self else{return};for(id,session) in self.sessions where Date().timeIntervalSince(session.last)>5{self.close(id)}};timer.resume()
    }
    private func accept(_ connection:NWConnection){
        guard sessions.count<8 else{connection.cancel();return};let id=UUID();sessions[id]=(connection,PadFrameDecoder(),Date())
        connection.stateUpdateHandler={[weak self] state in
            guard let self else{return}
            switch state {
            case .ready:
                guard self.active==nil else{self.send(["status":"busy"],id:id);self.queue.asyncAfter(deadline:.now()+0.1){self.close(id)};return}
                self.active=id;self.report("Wi-Fi connected");self.send(["status":self.apply(["type":"status"])=="ready" ? "ok":"permission"],id:id);self.receive(id)
            case .failed,.cancelled:self.close(id)
            default:break
            }
        };connection.start(queue:queue)
    }
    private func receive(_ id:UUID){
        guard let session=sessions[id],active==id else{return}
        session.connection.receive(minimumIncompleteLength:1,maximumLength:PadSecureLink.maxFrame+4){[weak self] data,_,complete,error in
            guard let self else{return}
            guard error==nil,let data,!data.isEmpty,var session=self.sessions[id] else{self.close(id);return}
            do {
                let frames=try session.decoder.append(data);session.last=Date();self.sessions[id]=session
                for frame in frames {
                    guard let object=try JSONSerialization.jsonObject(with:frame) as? [String:Any],let number=object["id"] as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID(),let events=object["events"] as? [[String:Any]],BLEWire.valid(events) else{throw PadSecureLink.Failure.invalidFrame}
                    if events.contains(where:{["move","scroll","magnify","dockSwipe"].contains($0["type"] as? String ?? "")}) {
                        var marker:[String:Any]=["type":"status","name":"transportFrame","transport":"wifi","sequence":number.intValue]
                        if let t=object["frameTime"] as? Double,t.isFinite{marker["t"]=t}
                        _ = self.apply(marker)
                    }
                    if let value=LatencySnapshotReporter.value(in:object) {_ = self.apply(["type":"status","name":"connectionLatency","transport":"wifi","x":value])}
                    var status="ok";for event in events{if self.apply(event)=="permission"{status="permission"}}
                    self.send(["status":status,"id":number],id:id)
                }
                if complete{self.close(id)}else{self.receive(id)}
            }catch{self.close(id)}
        }
    }
    private func send(_ object:[String:Any],id:UUID){
        var object=object;object["keyRepeatTuning"]=true;object["unifiedKeyRepeat"]=true;object["protocol"]=6
        guard let session=sessions[id],let data=try? JSONSerialization.data(withJSONObject:object),let frame=try? PadSecureLink.frame(data) else{return}
        session.connection.send(content:frame,completion:.contentProcessed{[weak self] error in if error != nil{self?.close(id)}})
    }
    private func close(_ id:UUID){
        guard let session=sessions.removeValue(forKey:id) else{return}
        if active==id{_ = apply(["type":"up"]);active=nil;report("Waiting for iPhone")};session.connection.cancel()
    }
    deinit{timer?.cancel();listener?.cancel();for session in sessions.values{session.connection.cancel()}}
}
