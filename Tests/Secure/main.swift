import Foundation

@main struct SecureTransportCheck {
    @MainActor static func main() async {
        var failures=0
        func check(_ condition:Bool,_ label:String){print("\(condition ? "PASS":"FAIL") \(label)");if !condition{failures+=1}}
        let message=Data("{\"status\":\"ok\"}".utf8)
        do {
            let framed=try PadSecureLink.frame(message);var decoder=PadFrameDecoder(),frames=[Data]()
            for byte in framed{frames += try decoder.append(Data([byte]))}
            check(frames==[message],"bytewise native framing")
            do{_ = try PadSecureLink.frame(Data(repeating:0,count:16385));check(false,"oversized frame rejected")}catch{check(true,"oversized frame rejected")}
            do{var bad=PadFrameDecoder();_ = try bad.append(Data([255,255,255,255]));check(false,"hostile length rejected")}catch{check(true,"hostile length rejected")}
            let box=InputCounter()
            let host=try NativeWiFiHost(token:String(repeating:"a",count:32),port:18766,apply:{event in box.record(event);return event["type"] as? String=="status" ? "ready":"ok"},report:{_ in})
            try await Task.sleep(nanoseconds:300_000_000)
            let wrong=PadSecureConnection(host:"127.0.0.1",port:18766,token:String(repeating:"b",count:32))
            do{try await wrong.connect();check(false,"wrong QR secret fails TLS authentication")}catch{check(true,"wrong QR secret fails TLS authentication")};wrong.cancel()
            check(box.count==0,"unauthenticated client never reaches input engine")
            let client=PadSecureConnection(host:"127.0.0.1",port:18766,token:String(repeating:"a",count:32))
            try await client.connect();let hello=try await client.receive()
            check((try JSONSerialization.jsonObject(with:hello) as? [String:String])?["status"]=="ok","native TLS handshake and ready reply")
            try await client.send(Data("{\"id\":1,\"events\":[{\"type\":\"move\",\"x\":1,\"y\":2},{\"type\":\"up\"}]}".utf8))
            let ack=try await client.receive();let reply=try JSONSerialization.jsonObject(with:ack) as? [String:Any]
            check(reply?["id"] as? Int==1 && box.count==3,"bounded native input and acknowledgment")
            client.cancel();_ = host
        }catch{print("FAIL \(error)");failures+=1}
        exit(failures==0 ? 0:1)
    }
}
final class InputCounter:@unchecked Sendable {
    private let lock=NSLock();private var value=0
    var count:Int{lock.lock();defer{lock.unlock()};return value}
    func record(_ event:[String:Any]){lock.lock();value+=1;lock.unlock()}
}
