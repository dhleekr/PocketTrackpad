import Foundation
@main struct EndpointCheck {
    static func main() {
        let token=String(repeating:"a",count:32)
        let valid=["http://10.1.2.3:8765/#\(token)","http://172.16.0.1/#\(token)","http://172.31.255.254/?v=0.4#\(token)","http://192.168.1.2/#\(token)","http://127.0.0.1/#\(token)","http://my-mac.local/#\(token)"]
        let invalid=["https://10.1.2.3/#\(token)","http://8.8.8.8/#\(token)","http://172.32.0.1/#\(token)","http://172.15.0.1/#\(token)","http://evil.10.1.2.3/#\(token)","http://10.999.1.2/#\(token)","http://10.1.2.3/#short","http://user:pass@10.1.2.3/#\(token)","http://10.1.2.3:0/#\(token)"]
        var passed=0
        for address in valid { guard (try? PairingEndpoint(address)) != nil else { print("FAIL valid local endpoint");exit(1) };passed+=1 }
        for address in invalid { guard (try? PairingEndpoint(address)) == nil else { print("FAIL invalid or external endpoint was accepted");exit(1) };passed+=1 }
        print("PASS \(passed) pairing endpoint checks; only local destinations accepted")
    }
}
