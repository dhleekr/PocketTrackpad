import Foundation
import CoreFoundation
import CryptoKit

enum BLEWire {
    static let service="7647DA20-730B-49AA-AB58-7812CE562410"
    static let input="7647DA21-730B-49AA-AB58-7812CE562410"
    static let reply="7647DA22-730B-49AA-AB58-7812CE562410"
    static let reverseService="7647DA30-730B-49AA-AB58-7812CE562410"
    static let maxFrame=16384
    static func valid(_ events:[[String:Any]])->Bool {
        let types:Set<String>=["move","scroll","magnify","dockSwipe","click","double","right","down","up","shortcut","status"]
        let shortcuts:Set<String>=["mission","appWindows","desktopLeft","desktopRight"]
        guard (1...64).contains(events.count) else {return false}
        for e in events {
            guard let t=e["type"] as? String,types.contains(t) else {return false}
            for key in ["x","y"] where e[key] != nil {
                guard let n=e[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,abs(n.doubleValue)<=2000 else {return false}
            }
            if let value=e["t"] {
                guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,(0...10_000_000_000).contains(n.doubleValue) else{return false}
            }
            if t=="dockSwipe" {
                guard let x=e["x"] as? NSNumber,abs(x.doubleValue)<=2,
                    let y=e["y"] as? NSNumber,abs(y.doubleValue)<=10,
                    let name=e["name"] as? String,["horizontal","vertical"].contains(name),
                    let phase=e["phase"] as? String,["began","changed","ended","cancelled"].contains(phase) else{return false}
            }
            if t=="magnify" {
                guard let x=e["x"] as? NSNumber,x.doubleValue.isFinite,abs(x.doubleValue)<=1,
                    let phase=e["phase"] as? String,["began","changed","ended","cancelled"].contains(phase) else{return false}
            }
            if t=="shortcut" {guard let n=e["name"] as? String,shortcuts.contains(n) else {return false}}
            if let value=e["phase"] {guard let p=value as? String,Set(["began","changed","ended","cancelled"]).contains(p) else{return false}}
            if let value=e["momentum"] {guard let p=value as? String,Set(["none","began","changed","ended"]).contains(p) else{return false}}
            if let n=e["count"] {guard let v=n as? NSNumber,CFGetTypeID(v) != CFBooleanGetTypeID(),[1.0,2.0].contains(v.doubleValue) else {return false}}
        }
        return true
    }
}

// Direction-bound proofs authenticate both endpoints without transmitting the QR secret.
enum BLEProof {
    static func make(role:String,nonce:String,token:String)->String {
        HMAC<SHA256>.authenticationCode(for:Data((role+":"+nonce).utf8),using:SymmetricKey(data:Data(token.utf8))).map{String(format:"%02x",$0)}.joined()
    }
    static func valid(_ proof:String,role:String,nonce:String,token:String?)->Bool {
        guard let token,token.utf8.count>=32,nonce.utf8.count==128,nonce.allSatisfy({$0.isHexDigit}),proof.utf8.count==64 else{return false}
        let expected=Array(make(role:role,nonce:nonce,token:token).utf8),received=Array(proof.utf8)
        return zip(expected,received).reduce(UInt8(0)){$0 | ($1.0 ^ $1.1)} == 0
    }
    static func nonce()->String {UUID().uuidString.replacingOccurrences(of:"-",with:"")+UUID().uuidString.replacingOccurrences(of:"-",with:"")}
}
struct BLEFrames {
    private var bytes=Data()
    mutating func append(_ incoming:Data) throws->[Data] {
        guard bytes.count+incoming.count<=BLEWire.maxFrame*2 else {bytes.removeAll();throw Failure.oversized}
        bytes.append(incoming);var result=[Data]()
        while let end=bytes.firstIndex(of:10) {
            guard end-bytes.startIndex<=BLEWire.maxFrame else {bytes.removeAll();throw Failure.oversized}
            result.append(Data(bytes[..<end]));bytes.removeSubrange(...end)
        }
        guard bytes.count<=BLEWire.maxFrame else {bytes.removeAll();throw Failure.oversized}
        return result
    }
    mutating func reset(){bytes.removeAll()}
    enum Failure:Error {case oversized}
}
struct LatencySamples {
    private(set) var values=[Double]()
    mutating func add(_ ms:Double){guard ms.isFinite,ms>=0 else{return};values.append(ms);if values.count>60 {values.removeFirst(values.count-60)}}
    var summary:String {
        guard !values.isEmpty else {return NSLocalizedString("Not measured",tableName:nil,bundle:.main,value:"Not measured",comment:"")}
        let s=values.sorted();return String(format:NSLocalizedString("Median %.0f · 95%% %.0f ms (%d samples)",tableName:nil,bundle:.main,value:"Median %.0f · 95%% %.0f ms (%d samples)",comment:""),s[s.count/2],s[min(s.count-1,Int(Double(s.count)*0.95))],s.count)
    }
}

struct BLEAccess {
    private(set) var peer:UUID?
    mutating func authorize(_ candidate:UUID,supplied:String,expected:String?)->String {
        if let peer,peer != candidate {return "busy"}
        guard let expected,expected.utf8.count>=32 else{return "pairing"}
        let a=Array(supplied.utf8),b=Array(expected.utf8)
        guard a.count==b.count else{return "pairing"}
        var difference:UInt8=0
        for (x,y) in zip(a,b){difference |= x ^ y}
        guard difference==0 else{return "pairing"}
        peer=candidate;return "ok"
    }
    func accepts(_ candidate:UUID)->Bool {peer==candidate}
    mutating func reset(){peer=nil}
}

enum ConnectionActivity {case active,inactive,background}
enum ConnectionEffect:Equatable {case resumeExisting,releaseOnly,suspend}
enum ConnectionLifecycle {
    static func effect(for activity:ConnectionActivity)->ConnectionEffect {
        switch activity {case .active:return .resumeExisting;case .inactive:return .releaseOnly;case .background:return .suspend}
    }
}
struct ConnectionEpoch {
    private(set) var value:UInt64=0
    mutating func advance(){value &+= 1}
    func matches(_ snapshot:UInt64)->Bool {value==snapshot}
}


// Wait for service publication before recovering a stalled discovery session.
enum BLEDiscoveryRecovery {
    static func shouldRestart(enabled:Bool,hasPeer:Bool,isAdvertising:Bool,elapsed:Double)->Bool {
        enabled && !hasPeer && !isAdvertising && elapsed>=5
    }
}


// Bound data accepted by CoreBluetooth, not merely our own notification queue.
// Control boundaries have two reserved credits; continuous input is coalesced
// while waiting for credit, preserving its full relative movement.
struct BLESendWindow {
    private var lastSent:Double?
    static let frameInterval=1.0/120.0
    func canSend(at now:Double,outstanding:Int,urgent:Bool)->Bool {
        guard now.isFinite,outstanding>=0,outstanding<(urgent ? 6:4) else{return false}
        return urgent || lastSent == nil || now-lastSent!>=Self.frameInterval-0.000001
    }
    mutating func didSend(at now:Double){lastSent=now}
    mutating func reset(){lastSent=nil}
}
