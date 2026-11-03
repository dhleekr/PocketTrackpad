import Foundation
import Cocoa
import CoreAudio

/// A fixed command adapter, not a general-purpose keyboard or settings editor.
/// File transforms are tested against fixtures; this runs only after a phone mic request.
enum GPTDictationBinding {
    static let command="globalDictationHold"
    enum Failure:Error {case malformed,conflict,changed,unsafePath,restartRequired}
    struct Shortcut:Equatable {
        let key:UInt16,flags:UInt64
        static func parse(_ text:String)->Shortcut? {
            let parts=text.lowercased().split(separator:"+").map{String($0).trimmingCharacters(in:.whitespaces)}
            guard let last=parts.last,parts.count>1 else{return nil}
            let codes:[String:UInt16]=["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,"f13":105,"f14":107,"f15":113,"f16":106,"f17":64,"f18":79,"f19":80,"f20":90]
            guard let key=codes[last] else{return nil}
            var flags:UInt64=0
            for modifier in parts.dropLast(){
                switch modifier {
                case "ctrl","control":flags |= CGEventFlags.maskControl.rawValue
                case "alt","option":flags |= CGEventFlags.maskAlternate.rawValue
                case "cmd","command","meta":flags |= CGEventFlags.maskCommand.rawValue
                case "shift":flags |= CGEventFlags.maskShift.rawValue
                default:return nil
                }
            }
            guard flags & (CGEventFlags.maskControl.rawValue|CGEventFlags.maskAlternate.rawValue|CGEventFlags.maskCommand.rawValue) != 0 else{return nil}
            return Shortcut(key:key,flags:flags)
        }
    }
    struct Plan {let shortcut:Shortcut;let replacement:Data?}
    static func plan(_ original:Data?)throws->Plan {
        var bindings=[[String:Any]]()
        if let original {
            guard original.count<=1_048_576,let array=try? JSONSerialization.jsonObject(with:original) as? [[String:Any]] else{throw Failure.malformed}
            bindings=array
        }
        guard !bindings.contains(where:{($0["command"] as? String)=="-"+command}) else{throw Failure.conflict}
        let existing=bindings.filter{($0["command"] as? String)==command}
        if !existing.isEmpty {
            // Never undo an explicit unbinding, conditional shortcut, or unusual custom key.
            guard let binding=existing.last,binding["when"]==nil,let key=binding["key"] as? String,let shortcut=Shortcut.parse(key) else{throw Failure.conflict}
            guard !bindings.contains(where:{($0["command"] as? String) != command && ($0["key"] as? String).flatMap(Shortcut.parse)==shortcut}) else{throw Failure.conflict}
            return Plan(shortcut:shortcut,replacement:nil)
        }
        guard !bindings.contains(where:{($0["command"] as? String)=="-"+command}) else{throw Failure.conflict}
        for key in ["Ctrl+Command+Alt+H","Ctrl+Command+Alt+F18","Ctrl+Command+Alt+F19","Ctrl+Command+Alt+F20"] {
            let shortcut=Shortcut.parse(key)!
            guard !bindings.contains(where:{($0["key"] as? String).flatMap(Shortcut.parse)==shortcut}) else{continue}
            bindings.append(["command":command,"key":key])
            return Plan(shortcut:shortcut,replacement:try JSONSerialization.data(withJSONObject:bindings,options:[.prettyPrinted,.sortedKeys]))
        }
        throw Failure.conflict
    }
    /// Preserve all existing entries and an exact backup. Never touch app databases or conversations.
    static func register(at url:URL,processIdentity:String,defaults:UserDefaults)throws->Shortcut {
        let fm=FileManager.default,marker="microphone.dictationBindingProcess"
        if (try? url.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink)==true{throw Failure.unsafePath}
        let original:Data?
        if fm.fileExists(atPath:url.path){original=try Data(contentsOf:url)}else{original=nil}
        let plan=try plan(original)
        if let replacement=plan.replacement {
            try fm.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            let current=fm.fileExists(atPath:url.path) ? try Data(contentsOf:url):nil
            guard current==original else{throw Failure.changed}
            if let original {
                let backup=url.deletingLastPathComponent().appendingPathComponent("keybindings.pockettrackpad-"+UUID().uuidString+".backup")
                try original.write(to:backup,options:.withoutOverwriting)
                try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:backup.path)
            }
            try replacement.write(to:url,options:.atomic)
            try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
            defaults.set(processIdentity,forKey:marker)
            throw Failure.restartRequired
        }
        guard defaults.string(forKey:marker) != processIdentity else{throw Failure.restartRequired}
        return plan.shortcut
    }
}

/// Only metadata about the target's active microphone route. No audio samples or UI text.
@available(macOS 14.2,*) enum GPTAudioCapture {
    static func active(bundle:String,device:AudioDeviceID?)->Bool? {
        func ids(_ object:AudioObjectID,_ selector:AudioObjectPropertySelector,_ scope:AudioObjectPropertyScope=kAudioObjectPropertyScopeGlobal)->[AudioObjectID]? {
            var address=AudioObjectPropertyAddress(mSelector:selector,mScope:scope,mElement:kAudioObjectPropertyElementMain),size:UInt32=0
            guard AudioObjectGetPropertyDataSize(object,&address,0,nil,&size)==noErr,size%4==0,size<=65_536 else{return nil}
            var result=[AudioObjectID](repeating:0,count:Int(size)/4)
            if result.isEmpty{return []}
            let status=result.withUnsafeMutableBytes{AudioObjectGetPropertyData(object,&address,0,nil,&size,$0.baseAddress!)}
            guard status==noErr else{return nil};return Array(result.prefix(Int(size)/4))
        }
        guard let processes=ids(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyProcessObjectList) else{return nil}
        var unknown=false
        for process in processes {
            var address=AudioObjectPropertyAddress(mSelector:kAudioProcessPropertyBundleID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            var value:Unmanaged<CFString>?,size=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status=AudioObjectGetPropertyData(process,&address,0,nil,&size,&value)
            guard status==noErr,let name=value?.takeRetainedValue() as String? else{unknown=true;continue}
            guard name==bundle || name.hasPrefix(bundle+".") else{continue}
            address.mSelector=kAudioProcessPropertyIsRunningInput
            var running:UInt32=0;size=4
            guard AudioObjectGetPropertyData(process,&address,0,nil,&size,&running)==noErr else{unknown=true;continue}
            guard running != 0 else{continue}
            guard let device else{return true}
            guard let devices=ids(process,kAudioProcessPropertyDevices,kAudioObjectPropertyScopeInput) else{unknown=true;continue}
            if devices.contains(device){return true}
        }
        return unknown ? nil:false
    }
}

/// Hold-to-dictate is deliberately used under a toggle UI: release is idempotent,
/// unlike a second toggle which could accidentally start another recording.
@MainActor final class GPTShortcutRecording {
    let shortcut:GPTDictationBinding.Shortcut
    private let post:(Bool)throws->Void
    private let capture:()->Bool?
    private(set) var held=false
    private var confirmed=false
    private let startTimeout:TimeInterval,stopTimeout:TimeInterval
    private var pressedAt:Double?
    private var inactiveSince:Double?
    init(shortcut:GPTDictationBinding.Shortcut,post:@escaping (Bool)throws->Void,capture:@escaping ()->Bool?,startTimeout:TimeInterval=8,stopTimeout:TimeInterval=10){self.shortcut=shortcut;self.post=post;self.capture=capture;self.startTimeout=startTimeout;self.stopTimeout=stopTimeout}
    func start()async throws {
        guard !held,!confirmed,capture()==false else{throw GPTMicrophoneControl.Failure.notConfirmed}
        held=true
        do {
            try post(true);pressedAt=ProcessInfo.processInfo.systemUptime
            let deadline=ProcessInfo.processInfo.systemUptime+startTimeout
            while ProcessInfo.processInfo.systemUptime<deadline {
                guard held else{throw CancellationError()}
                if capture()==true{confirmed=true;return}
                try await Task.sleep(for:.milliseconds(100))
            }
            throw GPTMicrophoneControl.Failure.notConfirmed
        }catch{_ = try? release();throw error}
    }

    private func release()throws {if held{try post(false);held=false}}
    func hasFinished()->Bool {
        guard confirmed,capture()==false else{inactiveSince=nil;return false}
        let now=ProcessInfo.processInfo.systemUptime
        if inactiveSince==nil{inactiveSince=now;return false}
        guard now-inactiveSince!>=0.5 else{return false}
        do{try release();return true}catch{return false}
    }
    func stop()async->Bool {
        if held,let pressedAt {
            let remaining=0.45-(ProcessInfo.processInfo.systemUptime-pressedAt)
            if remaining>0{try? await Task.sleep(for:.seconds(remaining))}
        }
        do{try release()}catch{return false}
        let deadline=ProcessInfo.processInfo.systemUptime+stopTimeout
        var inactiveStart:Double?
        repeat {
            let now=ProcessInfo.processInfo.systemUptime
            if capture()==false {
                if inactiveStart==nil{inactiveStart=now}
                if now-inactiveStart!>=0.5{return true}
            }else{inactiveStart=nil}
            try? await Task.sleep(for:.milliseconds(100))
        }while ProcessInfo.processInfo.systemUptime<deadline
        return false
    }
}
