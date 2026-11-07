import Foundation
import Combine
import Security

struct PairingEndpoint: Equatable {
    let host: String
    let port: Int
    let token: String
    init(_ address:String) throws {
        guard let url=URLComponents(string:address.trimmingCharacters(in:.whitespacesAndNewlines)),["http","pockettrackpad"].contains(url.scheme ?? ""),let host=url.host,
              let token=url.fragment,(32...128).contains(token.count),token.allSatisfy({$0.isASCII && ($0.isLetter || $0.isNumber || $0=="-" || $0=="_")}),
              url.user==nil,url.password==nil else { throw PairingError.invalid }
        let parts=host.split(separator:".").compactMap{Int($0)}
        let privateIP=host.split(separator:".").count==4 && parts.count==4 && parts.allSatisfy{(0...255).contains($0)} && (parts[0]==10 || (parts[0]==172 && (16...31).contains(parts[1])) || (parts[0]==192 && parts[1]==168) || parts[0]==127)
        guard privateIP || host=="localhost" || host.hasSuffix(".local") else { throw PairingError.localOnly }
        let requestedPort=url.port ?? 8766
        let port=url.scheme=="http" && requestedPort==8765 ? 8766:requestedPort
        guard (1...65535).contains(port) else { throw PairingError.invalid }
        self.host=host;self.port=port;self.token=token
    }
    var origin:String { "pockettrackpad://\(host):\(port)" }
    var savedAddress:String { "\(origin)/#\(token)" }
    enum PairingError:LocalizedError {
        case invalid,localOnly
        var errorDescription:String? { self == .invalid ? PTText("Mac 앱의 전체 연결 주소 또는 QR을 사용하세요."):PTText("같은 로컬 네트워크의 Mac 주소만 연결할 수 있습니다.") }
    }
}

@MainActor
final class WiFiClient:NSObject,ObservableObject {
    @Published var ready=false
    @Published var message=PTText("Mac QR로 연결하세요.")
    @Published var latencyMS=0
    @Published var pressureAvailable=false
    @Published var showConnection=true
    @Published var sensitivity=1.6
    @Published var pressDelay=0.16
    @Published var pressClick=true
    @Published var naturalScroll=true
    var diagnostics:PadDiagnostics?
    var onLatency:((Double)->Void)?
    var pairingAddress:String? { endpoint?.savedAddress ?? Self.readPairing() }
    private var endpoint:PairingEndpoint?
    private var socket:PadSecureConnection?
    private var generation=UUID()
    private var sendBusy=false
    private var lastReply=Date()
    private var queue=[PadEvent]()
    private var queuedAt=Date()
    private var sent=[Int:TimeInterval]()
    private var sequence=0
    private var latencyReporter=LatencySnapshotReporter()
    private(set) var peakInFlight=0
    var pendingFrameCount:Int { sent.count }
    var pendingEventCount:Int { queue.count }
    private var heartbeat:Timer?
    private var receiveTask:Task<Void,Never>?
    private(set) var droppedMotionBatches=0
    struct Envelope:Encodable { var id:Int;var events:[PadEvent];var frameTime=ProcessInfo.processInfo.systemUptime;var rttMS:Double?=nil }

    func start() {
        guard socket == nil else { return }
        if let saved=Self.readPairing(),let endpoint=try? PairingEndpoint(saved) { self.endpoint=endpoint;connect(endpoint) }
    }
    func pair(_ address:String,persist:Bool=true,connectNow:Bool=true) {
        do {
            let endpoint=try PairingEndpoint(address)
            self.endpoint=endpoint
            if persist { Self.savePairing(endpoint.savedAddress) }
            if connectNow { connect(endpoint) }
        } catch { message=error.localizedDescription;showConnection=true }
    }
    func forgetPairing(){
        disconnect();endpoint=nil
        let query:[CFString:Any]=[kSecClass:kSecClassGenericPassword,kSecAttrService:Self.account]
        SecItemDelete(query as CFDictionary);message=PTText("Mac QR로 연결하세요.");showConnection=true
    }
    func reconnect() { if let endpoint { connect(endpoint) } else { showConnection=true } }
    private func connect(_ endpoint:PairingEndpoint) {
        disconnect();lastReply=Date();let current=UUID();generation=current
        message=PTFormat("%@ 연결 중…",endpoint.host)
        let socket=PadSecureConnection(host:endpoint.host,port:endpoint.port,token:endpoint.token);self.socket=socket
        receiveTask=Task { [weak self] in
            do {
                try await socket.connect()
                while !Task.isCancelled {
                    let payload=try await socket.receive()
                    guard let self,self.generation==current else { return }
                    guard let reply=try JSONSerialization.jsonObject(with:payload) as? [String:Any],let status=reply["status"] as? String else { throw URLError(.cannotParseResponse) }
                    self.lastReply=Date()
                    self.keyRepeatTuning=reply["keyRepeatTuning"] as? Bool == true
                    if let version=reply["protocol"] as? Int {self.extendedInput=version>=2;self.customKeys=version>=3;self.gestureOptions=version>=4;self.remoteMicrophone=version>=5;self.continuousSystemGestures=version>=6}
                    if let id=reply["id"] as? Int,let token=self.textReceipts.removeValue(forKey:id){self.onTextAck?(token,status=="ok")}
                    self.diagnostics?.record(.ack,sequence:reply["id"] as? Int)
                    if let id=reply["id"] as? Int,let start=self.sent[id] {
                        let ms=(ProcessInfo.processInfo.systemUptime-start)*1000
                        self.latencyMS=max(1,Int(ms.rounded()));self.onLatency?(ms)
                        self.sent=self.sent.filter{$0.key>id}
                    }
                    let wasReady=self.ready;self.ready=status=="ok"
                    self.message=self.ready ? PTFormat("Mac 연결됨 · %d ms",self.latencyMS):PTText("Mac 설정에서 PocketTrackpad 입력 권한을 확인하세요.")
                    if status=="busy"{self.message=PTText("다른 아이폰이 이 Mac에 연결돼 있습니다.")}
                    if self.ready && !wasReady { self.showConnection=false }
                    self.flush()
                }
            } catch {
                guard let self,self.generation==current,!Task.isCancelled else { return }
                self.disconnect();self.message=PTFormat("연결 끊김: %@",error.localizedDescription);self.showConnection=true
            }
        }
        heartbeat=Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if !self.sent.isEmpty,Date().timeIntervalSince(self.lastReply)>2 {
                    self.disconnect();self.message=PTText("입력 응답이 멈췄습니다. Mac과 Wi-Fi를 확인하세요.");self.showConnection=true;return
                }
                if self.socket != nil { self.queue.append(PadEvent(type:"status"));self.flush() }
            }
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
    func send(_ events:[PadEvent]) {
        guard ready else { return }
        diagnostics?.record(.enqueue,source:events.last?.t,count:events.count,pending:queue.count)
        let now=Date()
        if now.timeIntervalSince(queuedAt)>0.08 && !queue.isEmpty {
            // Preserve clicks/releases, discard stale movement instead of playing a late cursor jump.
            queue.removeAll{$0.type=="move" || ($0.type=="scroll" && $0.phase=="changed")};droppedMotionBatches+=1
        }
        if queue.isEmpty { queuedAt=now }
        for event in events {
            if event.type=="dockSwipe",event.phase=="changed",let tail=queue.last,tail.type=="dockSwipe",tail.phase=="changed",tail.name==event.name {queue[queue.count-1]=event;continue}
            if var tail=queue.last,tail.type==event.type,(event.type=="move" || (event.type=="scroll" && tail.phase==event.phase && tail.momentum==event.momentum)),
               let x=tail.x,let y=tail.y,let dx=event.x,let dy=event.y,abs(x+dx)<=2000,abs(y+dy)<=2000 {
                tail.x=x+dx;tail.y=y+dy;tail.t=event.t;queue[queue.count-1]=tail
            } else { queue.append(event) }
        }
        guard queue.count<=128 else { disconnect();message=PTText("입력이 밀려 연결을 해제했습니다.");return }
        flush()
    }
    private func flush() {
        // The socket write completion provides backpressure. Application ACKs
        // measure responsiveness; waiting for them caps control rate at 4/RTT.
        guard !sendBusy,let socket,!queue.isEmpty else { return }
        let events=Array(queue.prefix(64));queue.removeFirst(events.count);sequence+=1
        let id=sequence,current=generation
        if let text=events.first(where:{$0.type=="text"}){textReceipts[id]=text.name}
        diagnostics?.record(.sendStart,source:events.last?.t,count:events.count,pending:queue.count,sequence:id)
        guard let data=try? JSONEncoder().encode(Envelope(id:id,events:events,rttMS:latencyReporter.snapshot(milliseconds:latencyMS,at:ProcessInfo.processInfo.systemUptime))),let text=String(data:data,encoding:.utf8) else { return }
        sendBusy=true;sent[id]=ProcessInfo.processInfo.systemUptime
        sent=sent.filter{$0.key>id-64};peakInFlight=max(peakInFlight,sent.count)
        Task { [weak self] in
            do { try await socket.send(Data(text.utf8)) }
            catch {
                guard let self,self.generation==current else { return }
                self.disconnect();self.message=PTFormat("입력 전송 실패: %@",error.localizedDescription);return
            }
            guard let self,self.generation==current else { return }
            self.diagnostics?.record(.sendComplete,sequence:id)
            self.sendBusy=false;self.flush()
        }
    }
    func pause() {
        guard let socket else { return }
        // Send an explicit release before ending the foreground connection.
        let current=generation
        Task { [weak self] in
            let data=try? JSONEncoder().encode(Envelope(id:-1,events:[PadEvent(type:"up")]))
            if let data,let text=String(data:data,encoding:.utf8) { try? await socket.send(Data(text.utf8)) }
            if let self,self.generation==current { self.disconnect() }
        }
    }
    func disconnect() {
        diagnostics?.record(.disconnected)
        keyRepeatTuning=false;extendedInput=false;customKeys=false;gestureOptions=false;remoteMicrophone=false;continuousSystemGestures=false;textReceipts=[:];generation=UUID();ready=false;heartbeat?.invalidate();heartbeat=nil;receiveTask?.cancel();receiveTask=nil
        socket?.cancel();socket=nil
        sendBusy=false;queue=[];sent=[:];latencyMS=0;latencyReporter=LatencySnapshotReporter()
    }
    private static let account="local.doohyun.pockettrackpad.wifi.pairing"
    private static func readPairing()->String? {
        let query:[CFString:Any]=[kSecClass:kSecClassGenericPassword,kSecAttrService:account,kSecReturnData:true,kSecMatchLimit:kSecMatchLimitOne]
        var value:CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary,&value)==errSecSuccess,let data=value as? Data else { return nil }
        return String(data:data,encoding:.utf8)
    }
    private static func savePairing(_ value:String) {
        let query:[CFString:Any]=[kSecClass:kSecClassGenericPassword,kSecAttrService:account]
        let changes:[CFString:Any]=[kSecValueData:Data(value.utf8)]
        if SecItemUpdate(query as CFDictionary,changes as CFDictionary)==errSecItemNotFound {
            var entry=query;entry[kSecValueData]=Data(value.utf8);entry[kSecAttrAccessible]=kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(entry as CFDictionary,nil)
        }
    }
}
