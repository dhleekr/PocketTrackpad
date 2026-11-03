import Cocoa
import CoreBluetooth
import ApplicationServices

// Compatibility transport: the Mac initiates the encrypted link to the iPhone.
final class BLEReverseHost:NSObject,CBCentralManagerDelegate,CBPeripheralDelegate {
    private var central:CBCentralManager!
    private var peer:CBPeripheral?
    private var input:CBCharacteristic?,reply:CBCharacteristic?
    private var buffer=BLEFrames(),writes=[Data]()
    private var challenge="",authenticated=false
    private var lastSeen=Date(),attempted=[UUID:Date]()
    private let queue=DispatchQueue(label:"local.pockettrackpad.ble.reverse",qos:.userInteractive)
    private var timer:DispatchSourceTimer?
    private let apply:([String:Any])->String
    private let report:(String)->Void
    private var token:String? {
        let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PocketTrackpad/pairing.key")
        return (try? String(contentsOf:path,encoding:.utf8))?.trimmingCharacters(in:.whitespacesAndNewlines)
    }
    init(apply:@escaping ([String:Any])->String,report:@escaping (String)->Void){
        self.apply=apply;self.report=report;super.init()
        central=CBCentralManager(delegate:self,queue:queue)
        let t=DispatchSource.makeTimerSource(queue:queue);timer=t;t.schedule(deadline:.now()+1,repeating:1)
        t.setEventHandler{[weak self] in
            guard let self else{return}
            _ = self.apply(["type":"status","name":"diagBLEState","count":self.central.state.rawValue,"x":self.central.isScanning ? 1.0:0.0,"y":self.peer == nil ? 0.0:1.0])
            if self.peer != nil,Date().timeIntervalSince(self.lastSeen)>(self.authenticated ? 5:60){self.close("Waiting for iPhone")}
        };t.resume()
    }
    func centralManagerDidUpdateState(_ central:CBCentralManager){
        if central.state == .poweredOn {scan()} else {close("Bluetooth unavailable")}
    }
    private func scan(){guard central.state == .poweredOn,peer==nil else{return};central.scanForPeripherals(withServices:[CBUUID(string:BLEWire.reverseService)],options:[CBCentralManagerScanOptionAllowDuplicatesKey:true])}
    func centralManager(_ central:CBCentralManager,didDiscover peripheral:CBPeripheral,advertisementData:[String:Any],rssi RSSI:NSNumber){
        guard peer==nil,Date().timeIntervalSince(attempted[peripheral.identifier] ?? .distantPast)>10 else{return}
        attempted[peripheral.identifier]=Date();peer=peripheral;peripheral.delegate=self;lastSeen=Date();central.stopScan()
        central.connect(peripheral);report("Connecting over Bluetooth…")
    }
    func centralManager(_ central:CBCentralManager,didConnect peripheral:CBPeripheral){guard peer?.identifier==peripheral.identifier else{return};peripheral.discoverServices([CBUUID(string:BLEWire.reverseService)])}
    func centralManager(_ central:CBCentralManager,didFailToConnect peripheral:CBPeripheral,error:Error?){guard peer?.identifier==peripheral.identifier else{return};close("Bluetooth connection failed")}
    func centralManager(_ central:CBCentralManager,didDisconnectPeripheral peripheral:CBPeripheral,error:Error?){guard peer?.identifier==peripheral.identifier else{return};close("Waiting for iPhone")}
    func peripheral(_ peripheral:CBPeripheral,didDiscoverServices error:Error?){
        guard peer?.identifier==peripheral.identifier else{return}
        guard error==nil,let service=peripheral.services?.first(where:{$0.uuid==CBUUID(string:BLEWire.reverseService)}) else{close("Bluetooth service unavailable");return}
        peripheral.discoverCharacteristics([CBUUID(string:BLEWire.input),CBUUID(string:BLEWire.reply)],for:service)
    }
    func peripheral(_ peripheral:CBPeripheral,didDiscoverCharacteristicsFor service:CBService,error:Error?){
        guard peer?.identifier==peripheral.identifier else{return}
        input=service.characteristics?.first{$0.uuid==CBUUID(string:BLEWire.input)};reply=service.characteristics?.first{$0.uuid==CBUUID(string:BLEWire.reply)}
        guard error==nil,let input,reply != nil else{close("Bluetooth channel unavailable");return};peripheral.setNotifyValue(true,for:input)
    }
    func peripheral(_ peripheral:CBPeripheral,didUpdateNotificationStateFor characteristic:CBCharacteristic,error:Error?){
        guard peer?.identifier==peripheral.identifier else{return}
        guard error==nil,characteristic.isNotifying,let token else{close("Bluetooth pairing failed");return}
        _ = token // The phone sends its fresh nonce first; bind both nonces into the proofs.
    }
    private func send(_ object:[String:Any]){
        var object=object;object["protocol"]=2
        guard let peer,let reply,var data=try? JSONSerialization.data(withJSONObject:object) else{return};data.append(10)
        let size=peer.maximumWriteValueLength(for:.withoutResponse);guard size>0 else{return}
        guard writes.count+((data.count+size-1)/size)<=256 else{close("Bluetooth connection stalled");return}
        for offset in stride(from:0,to:data.count,by:size){writes.append(data.subdata(in:offset..<min(data.count,offset+size)))}
        pump(peer,reply)
    }
    private func pump(_ peer:CBPeripheral,_ reply:CBCharacteristic){while peer.canSendWriteWithoutResponse,!writes.isEmpty {peer.writeValue(writes.removeFirst(),for:reply,type:.withoutResponse)}}
    func peripheralIsReady(toSendWriteWithoutResponse peripheral:CBPeripheral){if let reply,peer?.identifier==peripheral.identifier {pump(peripheral,reply)}}
    func peripheral(_ peripheral:CBPeripheral,didUpdateValueFor characteristic:CBCharacteristic,error:Error?){
        guard peer?.identifier==peripheral.identifier,error==nil,characteristic.uuid==input?.uuid,let data=characteristic.value else{return}
        do {for frame in try buffer.append(data){
            guard let object=try JSONSerialization.jsonObject(with:frame) as? [String:Any] else{throw BLEFrames.Failure.oversized}
            if !authenticated {
                if challenge.isEmpty,let offer=object["offer"] as? String,offer.count==64,offer.allSatisfy({$0.isHexDigit}),let token {
                    challenge=offer+BLEProof.nonce();send(["challenge":challenge,"proof":BLEProof.make(role:"host",nonce:challenge,token:token)]);continue
                }
                guard !challenge.isEmpty,object["hello"] as? String==challenge,let proof=object["proof"] as? String,BLEProof.valid(proof,role:"phone",nonce:challenge,token:token) else{close("Pairing failed. Scan the Mac QR again.");return}
                authenticated=true;_ = apply(["type":"status","name":"diagBLEAuth"]);lastSeen=Date();send(["status":apply(["type":"status"])=="ready" ? "ok":"permission"]);report("Bluetooth connected");continue
            }
            guard let id=object["id"] as? Int,let events=object["events"] as? [[String:Any]],BLEWire.valid(events) else{throw BLEFrames.Failure.oversized}
            if events.contains(where:{["move","scroll","magnify","dockSwipe"].contains($0["type"] as? String ?? "")}) {
                var marker:[String:Any]=["type":"status","name":"transportFrame","transport":"bluetooth","sequence":id]
                if let t=object["frameTime"] as? Double,t.isFinite{marker["t"]=t}
                _ = apply(marker)
            }
            if let value=LatencySnapshotReporter.value(in:object) {_ = apply(["type":"status","name":"connectionLatency","transport":"bluetooth","x":value])}
            lastSeen=Date();var status="ok";for event in events{if apply(event)=="permission" {status="permission"}};send(["status":status,"id":id])
        }} catch{close("Bluetooth connection closed")}
    }
    func peripheral(_ peripheral:CBPeripheral,didModifyServices invalidatedServices:[CBService]){
        guard peer?.identifier==peripheral.identifier,invalidatedServices.contains(where:{$0.uuid==CBUUID(string:BLEWire.reverseService)}) else{return}
        close("Waiting for iPhone")
    }
    private func close(_ text:String){
        if authenticated {_ = apply(["type":"up"])}
        let old=peer;peer=nil;input=nil;reply=nil;authenticated=false;challenge="";buffer.reset();writes=[]
        if let old{central?.cancelPeripheralConnection(old)};report(text);scan()
    }
}
