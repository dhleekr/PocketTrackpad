import Foundation
@MainActor func run()async throws {
    let token=String(repeating:"test-only-",count:6),challenge=String(repeating:"ab",count:64)
    var phone=try BLEMicrophoneCipher(token:token,challenge:challenge,role:.phone),mac=try BLEMicrophoneCipher(token:token,challenge:challenge,role:.mac)
    let first=try phone.seal(Data("start".utf8));let openedFirst=try mac.open(first);assert(openedFirst==Data("start".utf8))
    do{_ = try mac.open(first);assertionFailure("replay accepted")}catch{}
    let second=try phone.seal(Data("stop".utf8));var corrupt=second;corrupt[20]^=1
    do{_ = try mac.open(corrupt);assertionFailure("tampering accepted")}catch{}
    let openedSecond=try mac.open(second);assert(openedSecond==Data("stop".utf8))
    var stranger=try BLEMicrophoneCipher(token:String(repeating:"wrong-key-",count:6),challenge:challenge,role:.mac)
    do{_ = try stranger.open(second);assertionFailure("wrong QR key accepted")}catch{}
    let response=try mac.seal(Data("ready".utf8));let openedResponse=try phone.open(response);assert(openedResponse==Data("ready".utf8))
    var queue=MicrophoneBLEQueue();try queue.enqueue(Data(repeating:1,count:20),isAudio:true)
    assert(queue.next(maximum:10)==Data(repeating:1,count:10));queue.sent(10)
    try queue.enqueue(Data(repeating:2,count:20),isAudio:true);try queue.enqueue(Data([9]),isAudio:false)
    assert(queue.next(maximum:10)==Data(repeating:1,count:10));queue.sent(10)
    assert(queue.next(maximum:10)==Data([9]));queue.sent(1);assert(queue.empty,"stop must discard pending audio without breaking a partial frame")
    var pcm=Data(),energy=0.0,error=0.0
    for i in 0..<640{var sample=Int16(sin(Double(i)*2*Double.pi*440/16000)*16000).littleEndian;withUnsafeBytes(of:&sample){pcm.append(contentsOf:$0)}}
    let encoded=try MicrophoneADPCM.encode(pcm),decoded=try MicrophoneADPCM.decode48k(encoded)
    assert(encoded.count<pcm.count/3 && decoded.count==pcm.count*3)
    for i in 0..<640 {
        let a=pcm.withUnsafeBytes{Double(Int16(littleEndian:$0.loadUnaligned(fromByteOffset:i*2,as:Int16.self)))}
        let b=decoded.withUnsafeBytes{Double(Int16(littleEndian:$0.loadUnaligned(fromByteOffset:i*6,as:Int16.self)))}
        energy+=a*a;error+=(a-b)*(a-b)
    }
    assert(10*log10(energy/max(1,error))>18,"speech transport codec distorted the signal")
    do{_ = try MicrophoneADPCM.decode48k(Data([255,255,0,0,89]));assertionFailure("invalid codec header accepted")}catch{}
    var written=[Data](),closed=0
    let link=BLEMicrophoneConnection(available:{true},write:{data,_ in written.append(data)},close:{_ in closed+=1})
    try await link.connect();try await link.send(Data("start".utf8));link.deliver(Data("ready".utf8));let received=try await link.receive();assert(received==Data("ready".utf8))
    link.cancel();link.cancel();assert(closed==1 && written.count==1)
    let current=UUID().uuidString,previous=UUID().uuidString;var closedSession:String?
    let scoped=BLEMicrophoneConnection(available:{true},write:{_,_ in},close:{closedSession=$0})
    try await scoped.connect();try await scoped.send(JSONSerialization.data(withJSONObject:["op":"capabilities","session":current]))
    scoped.deliver(try JSONSerialization.data(withJSONObject:["status":"stopped","session":previous]))
    scoped.deliver(try JSONSerialization.data(withJSONObject:["status":"ready","session":current]))
    let scopedReply=try JSONSerialization.jsonObject(with:await scoped.receive()) as! [String:String]
    assert(scopedReply["status"]=="ready","late replies from a previous microphone session must be ignored")
    scoped.cancel();assert(closedSession==current)
    print("PASS BLE microphone encryption, replay/tamper rejection, stop priority, bounded independent audio frames, ADPCM quality and connection lifetime")
}
Task{@MainActor in do{try await run();exit(0)}catch{print("FAIL",error);exit(1)}}
RunLoop.main.run()
