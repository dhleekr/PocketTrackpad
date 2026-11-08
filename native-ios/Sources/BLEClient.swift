import Foundation
import CoreBluetooth
import Combine

// The iPhone advertises only while this foreground transport is selected.
@MainActor final class BLEPeripheralClient:NSObject,ObservableObject,@preconcurrency CBPeripheralManagerDelegate {
    @Published var ready=false
    @Published var message=PTText("Bluetooth 연결을 선택하세요.")
    @Published var latencyMS=0
    var diagnostics:PadDiagnostics?
    var onLatency:((Double)->Void)?
    private var manager:CBPeripheralManager?
    private var input:CBMutableCharacteristic?,reply:CBMutableCharacteristic?,microphoneInput:CBMutableCharacteristic?,microphoneReply:CBMutableCharacteristic?
    private var microphoneCipher:BLEMicrophoneCipher?,microphoneBuffer=PadFrameDecoder(),microphoneQueue=MicrophoneBLEQueue()
    private var microphoneSubscribed=false,microphoneSupported=false
    private var microphoneConnection:BLEMicrophoneConnection?
    var bluetoothMicrophone:Bool{authenticated && ready && microphoneSubscribed && microphoneSupported && microphoneCipher != nil}
    private var peer:CBCentral?,token:String?,nonce=""
    private var enabled=false,authenticated=false,hostVerified=false
    private var buffer=BLEFrames(),packets=[Data](),queue=[PadEvent]()
    private var sent=[Int:TimeInterval]()
    private var sequence=0,lastReply=Date(),queuedAt=Date()
    private var timer:Timer?
    private var frameTimer:Timer?
    private var latencyReporter=LatencySnapshotReporter()
    private var sendWindow=BLESendWindow()
    private var advertiseStarted=Date()
    private var epoch=ConnectionEpoch()
    func recordDiagnosticsState(){
        diagnostics?.record(.bleState,count:manager?.state.rawValue ?? -1,pending:packets.count,value:manager?.isAdvertising == true ? 1:0)
        diagnostics?.record(.bleAuth,count:enabled ? 1:0,pending:peer == nil ? 0:1,value:authenticated ? 1:0)
    }
    func start(token:String?){
        epoch.advance();self.token=token;enabled=true
        guard token != nil else{message=PTText("Scan the Mac QR first.");return}
        if manager==nil {manager=CBPeripheralManager(delegate:self,queue:.main)}
        else if manager?.state == .poweredOn,peer==nil,!manager!.isAdvertising {advertise()}
        frameTimer?.invalidate()
        let frameTimer=Timer(timeInterval:BLESendWindow.frameInterval,repeats:true){[weak self] _ in Task{@MainActor in self?.flush();self?.pumpMicrophone()}}
        self.frameTimer=frameTimer;RunLoop.main.add(frameTimer,forMode:.common)
        timer?.invalidate();timer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in Task{@MainActor in
            guard let self,self.enabled else{return}
            if let manager=self.manager,manager.state == .poweredOn,
               BLEDiscoveryRecovery.shouldRestart(enabled:self.enabled,hasPeer:self.peer != nil,isAdvertising:manager.isAdvertising,elapsed:Date().timeIntervalSince(self.advertiseStarted)) {
                self.reconnect(token:self.token);return
            }
            if self.peer != nil,!self.authenticated,Date().timeIntervalSince(self.lastReply)>60 {self.restart(PTText("Bluetooth authentication timed out."));return}
            if self.authenticated {if Date().timeIntervalSince(self.lastReply)>8 {self.restart(PTText("No Bluetooth response. Reconnect."))}else{self.send([PadEvent(type:"status")])}}
        }}
    }
    // Explicit reconnect must discard the old CoreBluetooth session, not cancel
    // a delayed pause cleanup while leaving its subscribed central attached.
    func reconnect(token:String?) {
        epoch.advance();enabled=false;timer?.invalidate();timer=nil;frameTimer?.invalidate();frameTimer=nil
        manager?.delegate=nil;manager?.stopAdvertising();manager?.removeAllServices()
        manager=nil;clearSession();start(token:token)
    }
    func peripheralManagerDidUpdateState(_ peripheral:CBPeripheralManager){
        guard peripheral === manager else{return}
        diagnostics?.record(.bleState,count:peripheral.state.rawValue)
        if peripheral.state == .poweredOn,enabled {advertise()}
        else {ready=false;message=peripheral.state == .unauthorized ? PTText("Allow PocketTrackpad to use Bluetooth in Settings."):PTText("Turn on Bluetooth.")}
    }
    private func advertise(){
        guard let manager,enabled,manager.state == .poweredOn,let serviceID=BLEDiscovery.service(token:token) else{return}
        diagnostics?.record(.bleAdvertise)
        advertiseStarted=Date();clearSession();manager.stopAdvertising();manager.removeAllServices()
        input=CBMutableCharacteristic(type:CBUUID(string:BLEWire.input),properties:[.notifyEncryptionRequired],value:nil,permissions:[])
        reply=CBMutableCharacteristic(type:CBUUID(string:BLEWire.reply),properties:[.write,.writeWithoutResponse],value:nil,permissions:[.writeEncryptionRequired])
        microphoneInput=CBMutableCharacteristic(type:CBUUID(string:BLEWire.microphoneInput),properties:[.notifyEncryptionRequired],value:nil,permissions:[])
        microphoneReply=CBMutableCharacteristic(type:CBUUID(string:BLEWire.microphoneReply),properties:[.write,.writeWithoutResponse],value:nil,permissions:[.writeEncryptionRequired])
        let service=CBMutableService(type:CBUUID(string:serviceID),primary:true);service.characteristics=[input!,reply!,microphoneInput!,microphoneReply!];manager.add(service)
        message=PTText("Keep the Mac app open. Waiting for Bluetooth…")
    }
    func peripheralManager(_ peripheral:CBPeripheralManager,didAdd service:CBService,error:Error?){
        guard peripheral === manager,enabled,let serviceID=BLEDiscovery.service(token:token),service.uuid==CBUUID(string:serviceID) else{return}
        guard error==nil else{message=PTText("Could not start the Bluetooth service.");return}
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey:[CBUUID(string:serviceID)],CBAdvertisementDataLocalNameKey:"PocketTrackpad iPhone"])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral:CBPeripheralManager,error:Error?){
        guard peripheral === manager,enabled else{return}
        diagnostics?.record(.bleAdvertise,count:(error as NSError?)?.code ?? 0,value:peripheral.isAdvertising ? 1:0)
        if let error{message=PTFormat("Bluetooth discovery failed: %@",error.localizedDescription)}
        else {message=PTText("Bluetooth discoverable. Waiting for Mac…")}
    }
    func peripheralManager(_ peripheral:CBPeripheralManager,central:CBCentral,didSubscribeTo characteristic:CBCharacteristic){
        if peripheral === manager,enabled,central.identifier==peer?.identifier,characteristic.uuid==microphoneInput?.uuid{microphoneSubscribed=true;return}
        guard peripheral === manager,enabled,peer==nil,characteristic.uuid==input?.uuid else{return};diagnostics?.record(.bleSubscribe,count:central.maximumUpdateValueLength);peer=central;peripheral.setDesiredConnectionLatency(.low,for:central);lastReply=Date();nonce=BLEProof.nonce();notify(["offer":nonce]);message=PTText("Verifying the Mac QR…")
    }
    func peripheralManager(_ peripheral:CBPeripheralManager,central:CBCentral,didUnsubscribeFrom characteristic:CBCharacteristic){
        if peripheral === manager,central.identifier==peer?.identifier,characteristic.uuid==microphoneInput?.uuid{microphoneSubscribed=false;microphoneConnection?.disconnected();microphoneConnection=nil;return}
        guard peripheral === manager,peer?.identifier==central.identifier else{return}
        clearSession()
        // Authentication stops advertising. Restore discovery after the Mac
        // disconnects so its next scan can find this iPhone again.
        if enabled { advertise() }
        message=PTText("Waiting for Bluetooth…")
    }
    func peripheralManager(_ peripheral:CBPeripheralManager,didReceiveWrite requests:[CBATTRequest]){
        guard peripheral === manager,enabled,let first=requests.first else{return}
        do {for request in requests{
            if request.characteristic.uuid==microphoneReply?.uuid {
                guard enabled,authenticated,request.central.identifier==peer?.identifier,request.offset==0,let data=request.value,microphoneCipher != nil else{throw PadSecureLink.Failure.invalidFrame}
                for frame in try microphoneBuffer.append(data){let packet=try microphoneCipher!.open(frame);microphoneConnection?.deliver(packet);lastReply=Date()}
                continue
            }
            guard enabled,request.central.identifier==peer?.identifier,request.characteristic.uuid==reply?.uuid,request.offset==0,let data=request.value else{throw BLEFrames.Failure.oversized}
            for frame in try buffer.append(data){
                guard let object=try JSONSerialization.jsonObject(with:frame) as? [String:Any] else{throw BLEFrames.Failure.oversized}
                if !authenticated {
                    // Verify the Mac before returning a phone proof. Never send the QR token.
                    if let challenge=object["challenge"] as? String,let proof=object["proof"] as? String {
                        guard !hostVerified,!nonce.isEmpty,challenge.hasPrefix(nonce),let token,BLEProof.valid(proof,role:"host",nonce:challenge,token:token) else{throw BLEFrames.Failure.oversized}
                        hostVerified=true;nonce=challenge;notify(["hello":challenge,"proof":BLEProof.make(role:"phone",nonce:challenge,token:token)]);lastReply=Date();continue
                    }
                    guard hostVerified,!nonce.isEmpty,let status=object["status"] as? String,["ok","permission"].contains(status) else{throw BLEFrames.Failure.oversized}
                    diagnostics?.record(.bleAuth,value:1)
                    guard let token else{throw PadSecureLink.Failure.closed}
                    microphoneCipher=try BLEMicrophoneCipher(token:token,challenge:nonce,role:.phone)
                    authenticated=true;manager?.stopAdvertising()
                }
                guard let status=object["status"] as? String,["ok","permission"].contains(status) else{throw BLEFrames.Failure.oversized}
                microphoneSupported=object["bluetoothMicrophone"] as? Bool == true
                keyRepeatTuning=object["keyRepeatTuning"] as? Bool == true
                if let version=object["protocol"] as? Int{extendedInput=version>=2;customKeys=version>=3;gestureOptions=version>=4;remoteMicrophone=version>=5;continuousSystemGestures=version>=6}
                if let id=object["id"] as? Int,let token=textReceipts.removeValue(forKey:id){onTextAck?(token,status=="ok")}
                diagnostics?.record(.ack,sequence:object["id"] as? Int)
                lastReply=Date();ready=status=="ok";message=ready ? PTFormat("Bluetooth connected · %d ms",latencyMS):PTText("Check PocketTrackpad input permission on the Mac.")
                if let id=object["id"] as? Int,let start=sent[id]{let ms=(ProcessInfo.processInfo.systemUptime-start)*1000;latencyMS=max(1,Int(ms.rounded()));onLatency?(ms);sent=sent.filter{$0.key>id}}
                flush()
            }
        };peripheral.respond(to:first,withResult:.success)
        }catch{peripheral.respond(to:first,withResult:.invalidAttributeValueLength);restart(PTText("Bluetooth authentication or response error. Check the Mac QR."))}
    }
    private func notify(_ object:[String:Any]){guard var data=try? JSONSerialization.data(withJSONObject:object) else{return};data.append(10);enqueue(data)}
    private func enqueue(_ data:Data){
        guard let peer,peer.maximumUpdateValueLength>0 else{return};let size=peer.maximumUpdateValueLength
        guard packets.count+(data.count+size-1)/size<=256 else{restart(PTText("Bluetooth transfer is backed up."));return}
        for offset in stride(from:0,to:data.count,by:size){packets.append(data.subdata(in:offset..<min(data.count,offset+size)))};pump()
    }
    private func pump(){guard let manager,let input,let peer else{return};while let data=packets.first{guard manager.updateValue(data,for:input,onSubscribedCentrals:[peer]) else{return};packets.removeFirst();diagnostics?.record(.sendComplete,count:data.count,pending:packets.count)}}
    func peripheralManagerIsReady(toUpdateSubscribers peripheral:CBPeripheralManager){guard peripheral === manager else{return};pump();flush();pumpMicrophone()}
    func makeMicrophoneConnection()throws->BLEMicrophoneConnection {
        guard bluetoothMicrophone,microphoneConnection==nil else{throw PadSecureLink.Failure.closed}
        let link=BLEMicrophoneConnection(available:{[weak self] in self?.bluetoothMicrophone == true},write:{[weak self] data,isAudio in
            guard let self else{throw PadSecureLink.Failure.closed};try self.sendMicrophone(data,isAudio:isAudio)
        },close:{[weak self] session in
            guard let self else{return}
            if let session,let packet=try? JSONSerialization.data(withJSONObject:["op":"cancel","session":session]){try? self.sendMicrophone(packet,isAudio:false)}
            self.microphoneConnection=nil
        })
        microphoneConnection=link;return link
    }
    private func sendMicrophone(_ data:Data,isAudio:Bool)throws {
        guard bluetoothMicrophone,microphoneCipher != nil else{throw PadSecureLink.Failure.closed}
        try microphoneQueue.enqueue(PadSecureLink.frame(microphoneCipher!.seal(data)),isAudio:isAudio);pumpMicrophone()
    }
    private func pumpMicrophone(){
        guard authenticated,packets.isEmpty,let manager,let input=microphoneInput,let peer,microphoneSubscribed else{return}
        for _ in 0..<2 {
            guard let packet=microphoneQueue.next(maximum:peer.maximumUpdateValueLength),manager.updateValue(packet,for:input,onSubscribedCentrals:[peer]) else{return}
            microphoneQueue.sent(packet.count)
        }
    }
    private(set) var extendedInput=false
    private(set) var customKeys=false
    private(set) var keyRepeatTuning=false
    private(set) var gestureOptions=false
    private(set) var remoteMicrophone=false
    private(set) var continuousSystemGestures=false
    var onTextAck:((String,Bool)->Void)?
    private var textReceipts=[Int:String]()
    func send(_ events:[PadEvent]){
        guard authenticated,ready || events.allSatisfy({$0.type=="status" || $0.type=="up"}) else{return}
        diagnostics?.record(.enqueue,source:events.last?.t,count:events.count,pending:queue.count)
        // Relative deltas are accumulated while waiting for transport credit.
        // Dropping an old relative delta permanently loses finger movement.
        for e in events{
            if e.type=="magnify",e.phase=="changed",var tail=queue.last,tail.type=="magnify",tail.phase=="changed",let x=tail.x,let dx=e.x,abs(x+dx)<=1 {tail.x=x+dx;tail.t=e.t;queue[queue.count-1]=tail;continue}
            if e.type=="dockSwipe",e.phase=="changed",let tail=queue.last,tail.type=="dockSwipe",tail.phase=="changed",tail.name==e.name {queue[queue.count-1]=e;continue}
            if var tail=queue.last,tail.type==e.type,(e.type=="move" || (e.type=="scroll" && tail.phase==e.phase && tail.momentum==e.momentum)),let x=tail.x,let y=tail.y,let dx=e.x,let dy=e.y,abs(x+dx)<=2000,abs(y+dy)<=2000{tail.x=x+dx;tail.y=y+dy;tail.t=e.t;queue[queue.count-1]=tail}else{queue.append(e)}
        }
        if queue.count>128{restart(PTText("Bluetooth input is backed up."));return};flush()
    }
    private func flush(){
        guard authenticated,packets.isEmpty,!queue.isEmpty else{return}
        let urgent=queue.contains{event in
            if !["move","scroll","magnify","rotate","dockSwipe"].contains(event.type){return true}
            return event.phase=="began" || event.phase=="cancelled" || (event.phase=="ended" && (event.momentum==nil || event.momentum=="none" || event.momentum=="ended"))
        }
        let now=ProcessInfo.processInfo.systemUptime
        guard sendWindow.canSend(at:now,outstanding:sent.count,urgent:urgent) else{return}
        sendWindow.didSend(at:now)
        let events=Array(queue.prefix(16));queue.removeFirst(events.count);sequence+=1
        if let text=events.first(where:{$0.type=="text"}){textReceipts[sequence]=text.name}
        diagnostics?.record(.sendStart,source:events.last?.t,count:events.count,pending:queue.count,sequence:sequence)
        guard var data=try? JSONEncoder().encode(WiFiClient.Envelope(id:sequence,events:events,rttMS:latencyReporter.snapshot(milliseconds:latencyMS,at:now))) else{return};data.append(10);sent[sequence]=ProcessInfo.processInfo.systemUptime;sent=sent.filter{$0.key>sequence-64};enqueue(data)
    }
    func pause(){
        send([PadEvent(type:"up")]);enabled=false;timer?.invalidate();timer=nil;frameTimer?.invalidate();frameTimer=nil;manager?.stopAdvertising()
        let snapshot=epoch.value
        DispatchQueue.main.asyncAfter(deadline:.now()+0.12){[weak self] in
            guard let self,self.epoch.matches(snapshot),!self.enabled else{return}
            self.manager?.removeAllServices();self.clearSession()
        }
    }
    private func clearSession(){microphoneConnection?.disconnected();microphoneConnection=nil;microphoneCipher=nil;microphoneBuffer=PadFrameDecoder();microphoneQueue.reset();microphoneSubscribed=false;microphoneSupported=false;keyRepeatTuning=false;extendedInput=false;customKeys=false;gestureOptions=false;remoteMicrophone=false;continuousSystemGestures=false;textReceipts=[:];latencyMS=0;latencyReporter=LatencySnapshotReporter();sendWindow.reset();ready=false;authenticated=false;hostVerified=false;peer=nil;nonce="";buffer.reset();packets=[];queue=[];sent=[:]}
    private func restart(_ text:String){clearSession();if enabled{advertise()};message=text}
}
