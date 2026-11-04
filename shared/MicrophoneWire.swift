import Foundation
import CryptoKit

enum MicrophoneAudioFormat {case pcm48k,adpcm16k}
@MainActor protocol MicrophoneConnection:AnyObject {
    var audioFormat:MicrophoneAudioFormat{get}
    func connect()async throws
    func send(_ data:Data)async throws
    func receive()async throws->Data
    func cancel()
}
extension PadSecureConnection:MicrophoneConnection {var audioFormat:MicrophoneAudioFormat{.pcm48k}}

/// The Bluetooth adapter owns only a microphone lane. Cancelling it never closes
/// the trackpad connection. Incoming messages and audio queues remain bounded.
@MainActor final class BLEMicrophoneConnection:MicrophoneConnection {
    let audioFormat:MicrophoneAudioFormat = .adpcm16k
    private let available:()->Bool,write:(Data,Bool)throws->Void,close:(String?)->Void
    private var session:String?
    private var pending=[Data](),waiter:CheckedContinuation<Data,Error>?,closed=false
    init(available:@escaping ()->Bool,write:@escaping (Data,Bool)throws->Void,close:@escaping (String?)->Void){self.available=available;self.write=write;self.close=close}
    func connect()async throws{guard available(),!closed else{throw PadSecureLink.Failure.closed}}
    func send(_ data:Data)async throws{
        guard !closed,available() else{throw PadSecureLink.Failure.closed}
        let audio=data.first==1 || data.first==2
        if !audio,let command=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],let token=command["session"] {
            guard session==nil || session==token else{throw PadSecureLink.Failure.invalidFrame};session=token
        }
        try write(data,audio)
    }
    func receive()async throws->Data {
        guard !closed else{throw PadSecureLink.Failure.closed}
        if !pending.isEmpty{return pending.removeFirst()}
        guard waiter==nil else{throw PadSecureLink.Failure.invalidFrame}
        return try await withCheckedThrowingContinuation{waiter=$0}
    }
    func deliver(_ data:Data){
        guard !closed else{return}
        if let session,let reply=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],reply["session"] != session{return}
        if let waiter{self.waiter=nil;waiter.resume(returning:data)}
        else if pending.count<16{pending.append(data)}else{cancel()}
    }
    func cancel(){guard !closed else{return};closed=true;close(session);pending=[];waiter?.resume(throwing:PadSecureLink.Failure.closed);waiter=nil}
    func disconnected(){guard !closed else{return};closed=true;pending=[];waiter?.resume(throwing:PadSecureLink.Failure.closed);waiter=nil}
}

/// Each direction uses a distinct nonce prefix; the key is derived from the
/// authenticated QR secret and both fresh BLE authentication nonces. Strict
/// counters reject replay within a connection; a new handshake creates a new key.
struct BLEMicrophoneCipher {
    enum Role:UInt32 {case phone=0x50484F4E,mac=0x4D414320}
    enum Failure:Error {case invalid,replay,exhausted}
    private let key:SymmetricKey,role:Role
    private var sent:UInt64=0,received:UInt64=0
    init(token:String,challenge:String,role:Role)throws {
        guard token.utf8.count>=32,challenge.count==128,challenge.allSatisfy(\.isHexDigit) else{throw Failure.invalid}
        self.role=role
        key=HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:Data(token.utf8)),salt:Data(challenge.utf8),info:Data("PocketTrackpad.BLEMicrophone.v1".utf8),outputByteCount:32)
    }
    mutating func seal(_ plaintext:Data)throws->Data {
        guard !plaintext.isEmpty,plaintext.count<=4096,sent<UInt64.max else{throw Failure.exhausted}
        sent+=1;var prefix=role.rawValue.bigEndian,counter=sent.bigEndian
        var nonce=withUnsafeBytes(of:&prefix){Data($0)};nonce+=withUnsafeBytes(of:&counter){Data($0)}
        guard let data=try AES.GCM.seal(plaintext,using:key,nonce:AES.GCM.Nonce(data:nonce)).combined else{throw Failure.invalid}
        return data
    }
    mutating func open(_ sealed:Data)throws->Data {
        guard (29...4124).contains(sealed.count) else{throw Failure.invalid}
        let prefix=sealed.prefix(4).reduce(UInt32(0)){($0<<8)|UInt32($1)}
        let expected:Role=role == .phone ? .mac:.phone
        let counter=sealed.dropFirst(4).prefix(8).reduce(UInt64(0)){($0<<8)|UInt64($1)}
        guard prefix==expected.rawValue,counter>received else{throw Failure.replay}
        let data=try AES.GCM.open(AES.GCM.SealedBox(combined:sealed),using:key)
        received=counter;return data
    }
}

/// Whole frames are retained until all their BLE fragments have been sent.
/// Stop/control frames bypass pending audio, but never truncate a partial frame.
struct MicrophoneBLEQueue {
    private var control=[Data](),audio=[Data](),active:Data?,offset=0
    var empty:Bool{active==nil && control.isEmpty && audio.isEmpty}
    mutating func enqueue(_ frame:Data,isAudio:Bool)throws {
        guard !frame.isEmpty,frame.count<=4200 else{throw PadSecureLink.Failure.invalidFrame}
        if isAudio{if audio.count>=3{audio.removeFirst()};audio.append(frame)}
        else{guard control.count<8 else{throw PadSecureLink.Failure.invalidFrame};audio=[];control.append(frame)}
    }
    mutating func next(maximum:Int)->Data? {
        guard maximum>0 else{return nil}
        if active==nil {
            if !control.isEmpty{active=control.removeFirst()}else if !audio.isEmpty{active=audio.removeFirst()}else{return nil}
            offset=0
        }
        guard let active else{return nil};return Data(active.dropFirst(offset).prefix(maximum))
    }
    mutating func sent(_ count:Int){guard let active,count>0 else{return};offset+=count;if offset>=active.count{self.active=nil;offset=0}}
    mutating func reset(){control=[];audio=[];active=nil;offset=0}
}

/// Independent IMA ADPCM packets keep BLE speech bandwidth near 64 kbit/s.
/// Every packet carries a predictor so a discarded late packet cannot corrupt
/// subsequent audio. The receiving virtual microphone remains 48 kHz PCM.
enum MicrophoneADPCM {
    private static let steps=[7,8,9,10,11,12,13,14,16,17,19,21,23,25,28,31,34,37,41,45,50,55,60,66,73,80,88,97,107,118,130,143,157,173,190,209,230,253,279,307,337,371,408,449,494,544,598,658,724,796,876,963,1060,1166,1282,1411,1552,1707,1878,2066,2272,2499,2749,3024,3327,3660,4026,4428,4871,5358,5894,6484,7132,7845,8630,9493,10442,11487,12635,13899,15289,16818,18500,20350,22385,24623,27086,29794,32767]
    private static let adjustment=[-1,-1,-1,-1,2,4,6,8]
    private static func advance(_ nibble:Int,predictor:inout Int,index:inout Int){
        let step=steps[index];var delta=step>>3
        if nibble&1 != 0{delta+=step>>2};if nibble&2 != 0{delta+=step>>1};if nibble&4 != 0{delta+=step}
        predictor=max(-32768,min(32767,predictor+(nibble&8 == 0 ? delta:-delta)))
        index=max(0,min(88,index+adjustment[nibble&7]))
    }
    static func encode(_ pcm:Data)throws->Data {
        guard !pcm.isEmpty,pcm.count%2==0,pcm.count<=2560 else{throw PadSecureLink.Failure.invalidFrame}
        let samples=pcm.withUnsafeBytes{raw in stride(from:0,to:raw.count,by:2).map{Int(Int16(littleEndian:raw.loadUnaligned(fromByteOffset:$0,as:Int16.self)))}}
        var predictor=samples[0],index=0
        // A higher initial step avoids a long attack ramp after packet boundaries.
        if samples.count>1{let delta=abs(samples[1]-samples[0]);while index<88 && steps[index]<delta{index+=1}}
        let first=UInt16(bitPattern:Int16(predictor)),count=UInt16(samples.count)
        var result=Data([UInt8(count&255),UInt8(count>>8),UInt8(first&255),UInt8(first>>8),UInt8(index)]),byte:UInt8=0,low=true
        for sample in samples.dropFirst(){
            let step=steps[index];var delta=sample-predictor,nibble=0
            if delta<0{nibble=8;delta = -delta}
            if delta>=step{nibble|=4;delta-=step};if delta>=step>>1{nibble|=2;delta-=step>>1};if delta>=step>>2{nibble|=1}
            advance(nibble,predictor:&predictor,index:&index)
            if low{byte=UInt8(nibble);low=false}else{result.append(byte|UInt8(nibble<<4));low=true}
        }
        if !low{result.append(byte)};return result
    }
    static func decode48k(_ data:Data)throws->Data {
        let bytes=Array(data);guard bytes.count>=5 else{throw PadSecureLink.Failure.invalidFrame}
        let count=Int(bytes[0])|Int(bytes[1])<<8
        guard (1...1280).contains(count),bytes[4]<=88,bytes.count==5+(count-1+1)/2 else{throw PadSecureLink.Failure.invalidFrame}
        var predictor=Int(Int16(bitPattern:UInt16(bytes[2])|UInt16(bytes[3])<<8)),index=Int(bytes[4]),samples=[Int]();samples.append(predictor)
        for n in 0..<(count-1){let byte=Int(bytes[5+n/2]),value=n%2==0 ? byte&15:byte>>4;advance(value,predictor:&predictor,index:&index);samples.append(predictor)}
        var result=Data();result.reserveCapacity(count*6)
        for i in 0..<count{let current=samples[i],next=samples[min(i+1,count-1)];for part in 0..<3{var sample=Int16(current+(next-current)*part/3).littleEndian;withUnsafeBytes(of:&sample){result.append(contentsOf:$0)}}}
        return result
    }
}
