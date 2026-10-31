import Foundation
import Cocoa
import Security
import Darwin

enum PairingKey {
    static func load()throws->String{
        let folder=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PocketTrackpad",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let file=folder.appendingPathComponent("pairing.key")
        if let value=try? String(contentsOf:file,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines),value.utf8.count>=32{
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);return value
        }
        var bytes=[UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else{throw PadSecureLink.Failure.closed}
        let value=Data(bytes).base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        try Data(value.utf8).write(to:file,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path);return value
    }
}
enum MacNetworkAddress {
    static func ipv4()->String?{
        var interfaces:UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces)==0,let first=interfaces else{return nil};defer{freeifaddrs(interfaces)}
        var current:UnsafeMutablePointer<ifaddrs>?=first
        while let item=current {
            defer{current=item.pointee.ifa_next}
            guard let addr=item.pointee.ifa_addr,addr.pointee.sa_family==UInt8(AF_INET),String(cString:item.pointee.ifa_name).hasPrefix("en") else{continue}
            var host=[CChar](repeating:0,count:Int(NI_MAXHOST))
            if getnameinfo(addr,socklen_t(addr.pointee.sa_len),&host,socklen_t(host.count),nil,0,NI_NUMERICHOST)==0{return String(cString:host)}
        };return nil
    }
}

enum ReceiverInstance {
    static let reopen=Notification.Name("local.doohyun.pockettrackpad.reopen")
    static func existing()->NSRunningApplication? {
        let current=NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "local.doohyun.pockettrackpad")
            .filter{!$0.isTerminated && $0.processIdentifier != current.processIdentifier &&
                (($0.launchDate ?? .distantPast)<(current.launchDate ?? .distantFuture) ||
                 ($0.launchDate==current.launchDate && $0.processIdentifier<current.processIdentifier))}
            .sorted{($0.launchDate ?? .distantPast)<($1.launchDate ?? .distantPast)}.first
    }
}
