import Cocoa
import ApplicationServices

private struct MicrophoneAXIdentity:Hashable {
    let element:AXUIElement
    func hash(into hasher:inout Hasher){hasher.combine(CFHash(element))}
    static func ==(left:Self,right:Self)->Bool{CFEqual(left.element,right.element)}
}

/// Invoked only by an authenticated phone's explicit microphone start/stop.
/// Inspect button labels only, in the original focused GPT window; never read chat text.
@MainActor final class GPTMicrophoneControl:MicrophoneAppControlling {
    private var window:AXUIElement?
    private var configuredRecording:GPTShortcutRecording?
    private var preparation:Task<DictationProfiles.Profile?,Error>?
    private var appRoot:AXUIElement?
    private var started=false
    private var processID:pid_t?
    private var stopElement:AXUIElement?
    private var composerRoots=[AXUIElement]()
    private let startLabels:Set<String>=["dictate","start dictation","start recording","voice input","record audio","start voice input","음성 입력","받아쓰기","받아쓰기 시작","녹음 시작"]
    private let stopLabels:Set<String>=["stop dictation","stop recording","finish dictation","음성 입력 중지","받아쓰기 중지","녹음 중지","녹음 완료","transcribe","stop and transcribe","finish recording","confirm dictation","받아쓰기 완료","음성을 텍스트로 변환"]
    enum Failure:Error{case permission,openGPT,setupRequired,buttonUnavailable,ambiguous,notConfirmed,alreadyRecording}
    private func focusedWindow()throws->AXUIElement {
        guard AXIsProcessTrusted() else{throw Failure.permission}
        guard let app=NSWorkspace.shared.frontmostApplication,["com.openai.codex","com.openai.chat","com.anthropic.claudefordesktop"].contains(app.bundleIdentifier ?? "") else{throw Failure.openGPT}
        processID=app.processIdentifier
        let root=AXUIElementCreateApplication(app.processIdentifier);AXUIElementSetMessagingTimeout(root,0.25)
        // Electron may expose only the native window until a remote accessibility
        // client explicitly requests its renderer tree. This runs only on phone start.
        _ = AXUIElementSetAttributeValue(root,"AXManualAccessibility" as CFString,kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(root,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        var result:CFTypeRef?
        guard AXUIElementCopyAttributeValue(root,kAXFocusedWindowAttribute as CFString,&result) == .success,let result,CFGetTypeID(result)==AXUIElementGetTypeID() else{throw Failure.openGPT}
        let window=unsafeBitCast(result,to:AXUIElement.self)
        appRoot=root;composerRoots=[]
        refreshComposerRoots(in:window)
        return window
    }
    private func refreshComposerRoots(in window:AXUIElement){
        guard let root=appRoot else{return}
        let deadline=ProcessInfo.processInfo.systemUptime+0.15
        var focused:CFTypeRef?
        if AXUIElementCopyAttributeValue(root,kAXFocusedUIElementAttribute as CFString,&focused) == .success,let focused,CFGetTypeID(focused)==AXUIElementGetTypeID(){
            var element=unsafeBitCast(focused,to:AXUIElement.self),ancestors=[AXUIElement](),insideWindow=false
            for _ in 0..<64 {
                guard ProcessInfo.processInfo.systemUptime<deadline else{break}
                if CFEqual(element,window){insideWindow=true;break}
                ancestors.append(element);AXUIElementSetMessagingTimeout(element,0.01)
                var parent:CFTypeRef?
                guard AXUIElementCopyAttributeValue(element,kAXParentAttribute as CFString,&parent) == .success,let parent,CFGetTypeID(parent)==AXUIElementGetTypeID() else{break}
                let next=unsafeBitCast(parent,to:AXUIElement.self)
                if CFEqual(next,element){break};element=next
            }
            if insideWindow{composerRoots=Array(ancestors.prefix(6))}
        }
    }
    private func button(in root:AXUIElement,labels:Set<String>)throws->AXUIElement {
        // Enabling Electron accessibility is asynchronous: focus may become
        // available only after prepare(). Refresh instead of caching an empty tree.
        if composerRoots.isEmpty{refreshComposerRoots(in:root)}
        let deadline=ProcessInfo.processInfo.systemUptime+1.5
        let matches=MicrophoneButtonSearch.matches(roots:composerRoots+[root],limit:6000,hasTime:{ProcessInfo.processInfo.systemUptime<deadline},identity:{AnyHashable(MicrophoneAXIdentity(element:$0))},children:{node in
            AXUIElementSetMessagingTimeout(node,0.03)
            for attribute in ["AXVisibleChildren",kAXChildrenAttribute,kAXContentsAttribute] {
                var value:CFTypeRef?
                if AXUIElementCopyAttributeValue(node,attribute as CFString,&value) == .success,let nodes=value as? [AXUIElement],!nodes.isEmpty{return nodes}
            }
            return []
        },isMatch:{node in
            AXUIElementSetMessagingTimeout(node,0.03)
            func string(_ attribute:String)->String{
                var value:CFTypeRef?;guard AXUIElementCopyAttributeValue(node,attribute as CFString,&value) == .success else{return ""};return (value as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
            }
            let roles:Set<String>=["axbutton","axcheckbox","axradiobutton","axpopupbutton","axmenubutton","axswitch"]
            guard roles.contains(string(kAXRoleAttribute)) else{return false}
            var actions:CFArray?
            guard AXUIElementCopyActionNames(node,&actions) == .success,(actions as? [String] ?? []).contains(kAXPressAction) else{return false}
            var values:CFArray?
            let attributes=[kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute] as CFArray
            guard AXUIElementCopyMultipleAttributeValues(node,attributes,[],&values) == .success,
                  let metadata=values as? [Any],metadata.contains(where:{($0 as? String).map{MicrophoneControlIdentity.matches($0,labels:labels)} ?? false}) else{return false}
            var enabled:CFTypeRef?;_ = AXUIElementCopyAttributeValue(node,kAXEnabledAttribute as CFString,&enabled)
            return (enabled as? Bool) != false
        })
        guard matches.count==1 else{throw matches.isEmpty ? Failure.buttonUnavailable:Failure.ambiguous};return matches[0]
    }
    func prepare()async throws{
        guard AXIsProcessTrusted() else{throw Failure.permission}
        guard let app=NSWorkspace.shared.frontmostApplication,let bundle=app.bundleIdentifier else{throw Failure.openGPT}
        let setup=Task{@MainActor in try await DictationShortcutMonitor.shared.current(bundle:bundle)}
        preparation=setup
        defer{preparation=nil}
        let selected:DictationProfiles.Profile?
        do{selected=try await setup.value}catch is CancellationError{throw CancellationError()}catch{throw Failure.setupRequired}
        if let profile=selected {
            guard #available(macOS 14.2,*) else{throw Failure.notConfirmed}
            let device=MacVirtualMicrophone.deviceID();guard device != 0 else{throw Failure.notConfirmed}
            configuredRecording=GPTShortcutRecording(shortcut:.init(key:profile.key,flags:profile.flags),post:{down in
                guard !down || NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{throw Failure.openGPT}
                guard let event=CGEvent(keyboardEventSource:nil,virtualKey:profile.key,keyDown:down) else{throw Failure.notConfirmed}
                event.flags=CGEventFlags(rawValue:profile.flags);event.setIntegerValueField(.keyboardEventAutorepeat,value:0);event.post(tap:.cghidEventTap)
            },capture:{
                guard NSRunningApplication(processIdentifier:app.processIdentifier) != nil else{return false}
                return GPTAudioCapture.active(bundle:bundle,device:device)
            },mode:profile.mode,activity:{GPTAudioCapture.active(bundle:bundle,device:nil)},prepareStop:{
                guard let original=NSRunningApplication(processIdentifier:app.processIdentifier),original.bundleIdentifier==bundle else{throw Failure.openGPT}
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != original.processIdentifier {
                    original.activate(options:[.activateIgnoringOtherApps])
                    for _ in 0..<10 {
                        if NSWorkspace.shared.frontmostApplication?.processIdentifier==original.processIdentifier{
                            // Activation notification and hotkey recovery are
                            // asynchronous even after frontmostApplication flips.
                            try await Task.sleep(for:.milliseconds(150))
                            guard NSWorkspace.shared.frontmostApplication?.processIdentifier==original.processIdentifier else{throw Failure.openGPT}
                            return
                        }
                        try await Task.sleep(for:.milliseconds(50))
                    }
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier==original.processIdentifier else{throw Failure.openGPT}
            })
            return
        }
        window=try focusedWindow()
    }
    func start() async throws {
        if let configuredRecording{try await configuredRecording.start();return}
        guard let window else{throw Failure.openGPT}
        let searchDeadline=ProcessInfo.processInfo.systemUptime+3
        var start:AXUIElement?
        repeat {
            do{start=try button(in:window,labels:startLabels)}catch Failure.ambiguous{throw Failure.ambiguous}catch{}
            if start != nil{break}
            try await Task.sleep(for:.milliseconds(100))
        }while ProcessInfo.processInfo.systemUptime<searchDeadline
        guard let start else{throw Failure.buttonUnavailable}
        guard AXUIElementPerformAction(start,kAXPressAction as CFString) == .success else{throw Failure.buttonUnavailable}
        started=true
        let deadline=ProcessInfo.processInfo.systemUptime+8
        while ProcessInfo.processInfo.systemUptime<deadline {
            if let stop=try? button(in:window,labels:stopLabels){stopElement=stop;return}
            try await Task.sleep(for:.milliseconds(100))
        }
        throw Failure.notConfirmed
    }
    func hasFinished()->Bool {
        if let configuredRecording{return configuredRecording.hasFinished()}
        guard started else{return false}
        if let processID,NSRunningApplication(processIdentifier:processID)==nil{return true}
        guard let window else{return false}
        if let stopElement {
            for attribute in [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute]{
                var value:CFTypeRef?
                if AXUIElementCopyAttributeValue(stopElement,attribute as CFString,&value) == .success,
                   let name=value as? String,stopLabels.contains(name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()){return false}
            }
        }
        if let stop=try? button(in:window,labels:stopLabels){stopElement=stop;return false}
        return (try? button(in:window,labels:startLabels)) != nil
    }
    func stop() async->Bool {
        preparation?.cancel()
        if let configuredRecording{return await configuredRecording.stop()}
        if hasFinished(){window=nil;started=false;stopElement=nil;return true}
        guard started,let window else{self.window=nil;self.started=false;return true}
        guard let stop=try? button(in:window,labels:stopLabels),AXUIElementPerformAction(stop,kAXPressAction as CFString) == .success else{return false}
        let deadline=ProcessInfo.processInfo.systemUptime+16
        while ProcessInfo.processInfo.systemUptime<deadline {
            if (try? button(in:window,labels:startLabels)) != nil{self.window=nil;self.started=false;return true}
            try? await Task.sleep(for:.milliseconds(100))
        }
        return false
    }
}
