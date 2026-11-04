import Foundation
import Cocoa
import CoreAudio

/// A fixed command adapter, not a general-purpose keyboard or settings editor.
/// Existing bindings are read only after a phone mic request; no settings are written.
enum GPTDictationBinding {
    static let command="globalDictationHold"
    enum Failure:Error {case malformed,conflict,changed,unsafePath,restartRequired}
    struct Shortcut:Equatable {
        let key:UInt16,flags:UInt64
        static func parse(_ text:String)->Shortcut? {
            let parts=text.lowercased().split(separator:"+").map{String($0).trimmingCharacters(in:.whitespaces)}
            guard let last=parts.last,parts.count>1 else{return nil}
            let codes:[String:UInt16]=["a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"9":25,"7":26,"8":28,"0":29,"o":31,"u":32,"i":34,"p":35,"l":37,"j":38,"k":40,"n":45,"m":46,"f13":105,"f14":107,"f15":113,"f16":106,"f17":64,"f18":79,"f19":80,"f20":90]
            let special:[String:UInt16]=["space":49,"spacebar":49,"return":36,"enter":36,"tab":48,"escape":53,"esc":53,"backspace":51,"delete":51,"left":123,"right":124,"down":125,"up":126,"f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,"f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111]
            guard let key=codes[last] ?? special[last] else{return nil}
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
    /// Read-only compatibility fallback. Never create or edit another app's settings.
    static func existing(in original:Data?)->Shortcut? {
        guard let original,original.count<=1_048_576,
              let bindings=try? JSONSerialization.jsonObject(with:original) as? [[String:Any]],
              !bindings.contains(where:{($0["command"] as? String)=="-"+command}),
              let binding=bindings.last(where:{($0["command"] as? String)==command}),
              binding["when"]==nil,let key=binding["key"] as? String,let shortcut=Shortcut.parse(key),
              !bindings.contains(where:{($0["command"] as? String) != command && ($0["key"] as? String).flatMap(Shortcut.parse)==shortcut}) else{return nil}
        return shortcut
    }

}

/// Only PocketTrackpad preferences are changed by this explicit setup.
enum DictationProfiles {
    static let codexSettingsOrigin="codex-settings"
    enum Mode:String,Codable {case hold,toggle}
    struct Profile:Codable,Equatable {let key:UInt16;let flags:UInt64;let mode:Mode;var origin:String?=nil}
    static let preferenceKey="microphone.appShortcuts.v1"
    static func load(bundle:String,defaults:UserDefaults = .standard)->Profile? {
        guard let data=defaults.data(forKey:preferenceKey),let profiles=try? JSONDecoder().decode([String:Profile].self,from:data),let value=profiles[bundle],value.key<128,value.flags & (CGEventFlags.maskControl.rawValue|CGEventFlags.maskAlternate.rawValue|CGEventFlags.maskCommand.rawValue) != 0 else{return nil}
        return value
    }
    static func configuredBundles(defaults:UserDefaults = .standard)->[String] {
        guard let data=defaults.data(forKey:preferenceKey),let profiles=try? JSONDecoder().decode([String:Profile].self,from:data) else{return []}
        return profiles.filter{$0.value.origin=="auto" || $0.value.origin==codexSettingsOrigin}.map{ $0.key }
    }
    static func save(_ profile:Profile?,bundle:String,defaults:UserDefaults = .standard){
        var profiles=(defaults.data(forKey:preferenceKey).flatMap{try? JSONDecoder().decode([String:Profile].self,from:$0)}) ?? [:]
        profiles[bundle]=profile
        if let data=try? JSONEncoder().encode(profiles){defaults.set(data,forKey:preferenceKey)}
    }
    static func display(_ profile:Profile)->String {
        let flags=CGEventFlags(rawValue:profile.flags)
        var text=""
        if flags.contains(.maskControl){text+="⌃"};if flags.contains(.maskAlternate){text+="⌥"}
        if flags.contains(.maskShift){text+="⇧"};if flags.contains(.maskCommand){text+="⌘"}
        let names:[UInt16:String]=[0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",40:"K",45:"N",46:"M",48:"⇥",49:"Space",51:"⌫",53:"Esc",105:"F13",107:"F14",113:"F15",106:"F16",64:"F17",79:"F18",80:"F19",90:"F20"]
        let extra:[UInt16:String]=[122:"F1",120:"F2",99:"F3",118:"F4",96:"F5",97:"F6",98:"F7",100:"F8",101:"F9",109:"F10",103:"F11",111:"F12",123:"←",124:"→",125:"↓",126:"↑"]
        return text+(names[profile.key] ?? extra[profile.key] ?? "Key \(profile.key)")
    }
}

/// Codex stores its global dictation shortcut separately from command overrides.
/// Decode this single preference only. Never read overrides as the live setting,
/// modify target preferences, or log any other state from this file.
enum CodexDictationPreference {
    private struct Settings:Decodable {let globalDictationHotkey:String?}
    static var url:URL {FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/.codex-global-state.json")}
    static func profile(data:Data)->DictationProfiles.Profile? {
        guard data.count<=16_777_216,let settings=try? JSONDecoder().decode(Settings.self,from:data),
              let text=settings.globalDictationHotkey,let shortcut=GPTDictationBinding.Shortcut.parse(text) else{return nil}
        return .init(key:shortcut.key,flags:shortcut.flags,mode:.hold,origin:DictationProfiles.codexSettingsOrigin)
    }
    static func read(at url:URL=Self.url)->DictationProfiles.Profile? {
        guard let values=try? url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey]),values.isRegularFile==true,
              let size=values.fileSize,size<=16_777_216,let data=try? Data(contentsOf:url,options:.mappedIfSafe) else{return nil}
        return profile(data:data)
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
    private let activity:()->Bool?
    private(set) var held=false
    private var confirmed=false
    private let mode:DictationProfiles.Mode
    private let prepareStop:()async throws->Void
    private var toggleStarted=false,toggleStopSent=false
    private let startTimeout:TimeInterval,stopTimeout:TimeInterval
    private var pressedAt:Double?
    private var inactiveSince:Double?
    init(shortcut:GPTDictationBinding.Shortcut,post:@escaping (Bool)throws->Void,capture:@escaping ()->Bool?,mode:DictationProfiles.Mode = .hold,activity:(()->Bool?)?=nil,prepareStop:@escaping ()async throws->Void={},startTimeout:TimeInterval=8,stopTimeout:TimeInterval=10){self.shortcut=shortcut;self.mode=mode;self.post=post;self.capture=capture;self.activity=activity ?? capture;self.prepareStop=prepareStop;self.startTimeout=startTimeout;self.stopTimeout=stopTimeout}
    func start()async throws {
        guard !held,!confirmed,!toggleStarted,activity()==false else{throw GPTMicrophoneControl.Failure.notConfirmed}
        held=true
        do {
            try post(true);pressedAt=ProcessInfo.processInfo.systemUptime
            if mode == .toggle{try post(false);held=false;toggleStarted=true}
            let deadline=ProcessInfo.processInfo.systemUptime+startTimeout
            while ProcessInfo.processInfo.systemUptime<deadline {
                guard held || toggleStarted else{throw CancellationError()}
                if capture()==true{confirmed=true;return}
                try await Task.sleep(for:.milliseconds(100))
            }
            throw GPTMicrophoneControl.Failure.notConfirmed
        }catch{_ = try? release();throw error}
    }

    private func release()throws {if held{try post(false);held=false}}
    func hasFinished()->Bool {
        guard confirmed,activity()==false else{inactiveSince=nil;return false}
        let now=ProcessInfo.processInfo.systemUptime
        if inactiveSince==nil{inactiveSince=now;return false}
        guard now-inactiveSince!>=0.5 else{return false}
        do{try release();return true}catch{return false}
    }
    func stop()async->Bool {
        if mode == .toggle,toggleStarted,!toggleStopSent,activity()==true {
            do{try await prepareStop();try post(true);try post(false);toggleStopSent=true}catch{try? post(false);return false}
        }
        if held,let pressedAt {
            let remaining=0.45-(ProcessInfo.processInfo.systemUptime-pressedAt)
            if remaining>0{try? await Task.sleep(for:.seconds(remaining))}
        }
        do{try release()}catch{return false}
        let deadline=ProcessInfo.processInfo.systemUptime+stopTimeout
        var inactiveStart:Double?
        repeat {
            let now=ProcessInfo.processInfo.systemUptime
            if activity()==false {
                if inactiveStart==nil{inactiveStart=now}
                if now-inactiveStart!>=0.5{return true}
            }else{inactiveStart=nil}
            try? await Task.sleep(for:.milliseconds(100))
        }while ProcessInfo.processInfo.systemUptime<deadline
        return false
    }
}
