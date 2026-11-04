import Cocoa
import ApplicationServices

/// Explicit, user-started setup. Reads menu shortcuts and dictation settings only.
/// Never writes target preferences, reads chat fields, or starts a recording.
enum DictationShortcutDiscovery {
    enum Failure:Error {case permission,notInstalled,settingsUnavailable,notAssigned,assignmentOpened,unsupported}
    private struct Identity:Hashable {
        let element:AXUIElement
        func hash(into h:inout Hasher){h.combine(CFHash(element))}
        static func ==(a:Self,b:Self)->Bool{CFEqual(a.element,b.element)}
    }
    static func parseDisplayed(_ text:String)->GPTDictationBinding.Shortcut? {
        var value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        for (glyph,word) in [("⌃","Ctrl+"),("⌥","Alt+"),("⇧","Shift+"),("⌘","Command+")]{value=value.replacingOccurrences(of:glyph,with:word)}
        for (glyph,word) in [("␣","Space"),("↩","Return"),("⏎","Return"),("⇥","Tab"),("⎋","Escape"),("⌫","Backspace"),("←","Left"),("→","Right"),("↑","Up"),("↓","Down")]{value=value.replacingOccurrences(of:glyph,with:word)}
        return GPTDictationBinding.Shortcut.parse(value.replacingOccurrences(of:" ",with:""))
    }
    private static func value(_ node:AXUIElement,_ attribute:String)->CFTypeRef? {
        AXUIElementSetMessagingTimeout(node,0.08)
        var result:CFTypeRef?
        return AXUIElementCopyAttributeValue(node,attribute as CFString,&result) == .success ? result:nil
    }
    private static func string(_ node:AXUIElement,_ attribute:String)->String{value(node,attribute) as? String ?? ""}
    private static func children(_ node:AXUIElement)->[AXUIElement]{value(node,kAXChildrenAttribute) as? [AXUIElement] ?? []}
    private static func walk(_ root:AXUIElement,limit:Int=1000)->[AXUIElement]{
        var stack=[root],result=[AXUIElement](),seen=Set<Identity>()
        let end=ProcessInfo.processInfo.systemUptime+0.6
        while let node=stack.popLast(),result.count<limit,ProcessInfo.processInfo.systemUptime<end{
            guard seen.insert(.init(element:node)).inserted else{continue};result.append(node);stack+=children(node)
        }
        return result
    }
    private static func labels(_ node:AXUIElement,setting:Bool=false)->[String]{
        var attributes=[kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute]
        if setting,string(node,kAXRoleAttribute)==kAXStaticTextRole{attributes.append(kAXValueAttribute)}
        AXUIElementSetMessagingTimeout(node,0.08)
        var values:CFArray?
        guard AXUIElementCopyMultipleAttributeValues(node,attributes as CFArray,[],&values) == .success else{return []}
        return (values as? [Any] ?? []).compactMap{$0 as? String}.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}.filter{!$0.isEmpty}
    }
    private static func isDictation(_ name:String,bundle:String)->Bool {
        let allowed:Set<String>=["dictate","dictation","dictation shortcut","dictation hotkey","hold to dictate","push to talk","받아쓰기","받아쓰기 단축키","받아쓰기 시작"]
        return MicrophoneControlIdentity.matches(name,labels:allowed)
    }
    private static func mode(_ labels:[String],bundle:String)->DictationProfiles.Mode {
        if labels.contains(where:{$0.contains("toggle") || $0.contains("again")}){return .toggle}
        if labels.contains(where:{$0.contains("hold") || $0.contains("push to talk")}){return .hold}
        return bundle=="com.openai.codex" ? .hold:.toggle
    }
    private static func menuProfile(_ root:AXUIElement,bundle:String)->DictationProfiles.Profile? {
        guard let bar=value(root,kAXMenuBarAttribute),CFGetTypeID(bar)==AXUIElementGetTypeID() else{return nil}
        let end=ProcessInfo.processInfo.systemUptime+1.5
        for node in walk(unsafeBitCast(bar,to:AXUIElement.self)){
            guard ProcessInfo.processInfo.systemUptime<end else{break}
            let names=labels(node)
            guard names.contains(where:{isDictation($0,bundle:bundle)}),let modifiers=value(node,"AXMenuItemCmdModifiers") as? NSNumber else{continue}
            let bits=modifiers.intValue
            var flags:UInt64=bits & 8 == 0 ? CGEventFlags.maskCommand.rawValue:0
            if bits & 1 != 0{flags |= CGEventFlags.maskShift.rawValue};if bits & 2 != 0{flags |= CGEventFlags.maskAlternate.rawValue};if bits & 4 != 0{flags |= CGEventFlags.maskControl.rawValue}
            if let key=value(node,"AXMenuItemCmdVirtualKey") as? NSNumber,key.intValue>=0,key.intValue<128,flags != 0{return .init(key:key.uint16Value,flags:flags,mode:mode(names,bundle:bundle))}
        }
        return nil
    }
    private static func settingsWindow(_ root:AXUIElement)->AXUIElement? {
        let names=["settings","preferences","설정","환경설정"]
        func named(_ node:AXUIElement)->Bool{labels(node).contains{text in names.contains(where:{text==$0 || text.hasPrefix($0+" ") || text.hasSuffix(" "+$0)})}}
        for window in value(root,kAXWindowsAttribute) as? [AXUIElement] ?? [] {
            if named(window){return window}
            // Outside Settings, examine roles and routing metadata only. Never inspect
            // arbitrary message groups or text-field values to locate preferences.
            for node in walk(window,limit:1200){
                let role=string(node,kAXRoleAttribute)
                if role==kAXSheetRole || ["AXDialog","AXApplicationDialog"].contains(string(node,kAXSubroleAttribute)) {
                    if named(node){return node}
                }
                guard role=="AXWebArea",let address=value(node,kAXURLAttribute) else{continue}
                let route=(address as? URL)?.absoluteString ?? (address as? String ?? "")
                guard route.lowercased().contains("#settings") || route.lowercased().contains("/settings") else{continue}
                for container in walk(node,limit:600) where string(container,kAXRoleAttribute)==kAXGroupRole {
                    if named(container){return container}
                }
            }
        }
        return nil
    }
    private static func readSettings(_ root:AXUIElement,bundle:String)->DictationProfiles.Profile? {
        var profiles=[DictationProfiles.Profile](),unassigned=false
        let end=ProcessInfo.processInfo.systemUptime+2
        for node in walk(root){
            guard ProcessInfo.processInfo.systemUptime<end else{break}
            let names=labels(node,setting:true)
            guard names.contains(where:{isDictation($0,bundle:bundle)}) else{continue}
            var controls=[node]
            // Only a labelled dictation container or an explicit AX label relationship
            // can contribute a key. Never borrow a nearby unrelated shortcut row.
            if [kAXGroupRole,kAXRowRole].contains(string(node,kAXRoleAttribute)){controls+=walk(node,limit:60)}
            if let parent=value(node,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID(){
                for sibling in children(unsafeBitCast(parent,to:AXUIElement.self)) {
                    if let title=value(sibling,kAXTitleUIElementAttribute),CFGetTypeID(title)==AXUIElementGetTypeID(),CFEqual(title,node){controls.append(sibling)}
                }
            }
            for control in controls {
                let role=string(control,kAXRoleAttribute)
                guard [kAXButtonRole,kAXPopUpButtonRole,kAXComboBoxRole,kAXTextFieldRole,kAXStaticTextRole].contains(role),string(control,kAXSubroleAttribute) != kAXSecureTextFieldSubrole else{continue}
                for text in [string(control,kAXTitleAttribute),string(control,kAXDescriptionAttribute),string(control,kAXValueAttribute)] {
                    if ["no shortcut","not assigned","none","off","disabled","없음","사용 안 함"].contains(text.lowercased()){unassigned=true}
                    if let key=parseDisplayed(text){profiles.append(.init(key:key.key,flags:key.flags,mode:mode(names,bundle:bundle)))}
                }
            }
        }
        let unique=profiles.reduce(into:[DictationProfiles.Profile]()) {if !$0.contains($1){$0.append($1)}}
        return !unassigned && unique.count==1 ? unique[0]:nil
    }
    private static func openAssignment(_ root:AXUIElement,bundle:String)->Bool {
        for label in walk(root){
            let names=labels(label,setting:true)
            guard names.contains(where:{isDictation($0,bundle:bundle)}) else{continue}
            var fields=[label]
            if [kAXGroupRole,kAXRowRole].contains(string(label,kAXRoleAttribute)){fields+=walk(label,limit:60)}
            if let parent=value(label,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID(){
                for sibling in children(unsafeBitCast(parent,to:AXUIElement.self)) {
                    if let title=value(sibling,kAXTitleUIElementAttribute),CFGetTypeID(title)==AXUIElementGetTypeID(),CFEqual(title,label){fields.append(sibling)}
                }
            }
            for field in fields {
                let role=string(field,kAXRoleAttribute)
                if role==kAXTextFieldRole,string(field,kAXSubroleAttribute) != kAXSecureTextFieldSubrole {
                    if AXUIElementSetAttributeValue(field,kAXFocusedAttribute as CFString,kCFBooleanTrue) == .success{return true}
                }
                let explicit=names.contains{$0.contains("shortcut") || $0.contains("hotkey") || $0.contains("단축키")}
                guard role==kAXPopUpButtonRole || role==kAXComboBoxRole || (role==kAXButtonRole && explicit) else{continue}
                let pressed=AXUIElementPerformAction(field,kAXPressAction as CFString)
                guard pressed == .success || AXUIElementPerformAction(field,"AXShowMenu" as CFString) == .success else{continue}
                if role==kAXPopUpButtonRole || role==kAXComboBoxRole {
                    let custom:Set<String>=["custom","custom shortcut","custom keyboard shortcut","사용자 지정","사용자 지정 단축키"]
                    var menuRoot=field
                    if let parent=value(field,kAXParentAttribute),CFGetTypeID(parent)==AXUIElementGetTypeID(){menuRoot=unsafeBitCast(parent,to:AXUIElement.self)}
                    for option in walk(menuRoot,limit:100) where labels(option,setting:true).contains(where:{custom.contains($0.replacingOccurrences(of:"…",with:"").replacingOccurrences(of:"...",with:""))}) {
                        // Web select options may claim AXPress support without selecting.
                        // Resolve their own visible bounds; never use a fixed screen point.
                        if !clickIdentifiedControl(option,bundle:bundle){_ = AXUIElementPerformAction(option,kAXPressAction as CFString)}
                        break
                    }
                }
                return true
            }
        }
        return false
    }
    private static func clickIdentifiedControl(_ node:AXUIElement,bundle:String)->Bool {
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier==bundle,
              let position=value(node,kAXPositionAttribute),CFGetTypeID(position)==AXValueGetTypeID(),
              let size=value(node,kAXSizeAttribute),CFGetTypeID(size)==AXValueGetTypeID() else{return false}
        var point=CGPoint.zero,extent=CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position,to:AXValue.self),.cgPoint,&point),
              AXValueGetValue(unsafeBitCast(size,to:AXValue.self),.cgSize,&extent),extent.width>0,extent.height>0 else{return false}
        point.x+=extent.width/2;point.y+=extent.height/2
        for kind in [CGEventType.leftMouseDown,.leftMouseUp]{
            guard let event=CGEvent(mouseEventSource:nil,mouseType:kind,mouseCursorPosition:point,mouseButton:.left) else{return false}
            event.post(tap:.cghidEventTap)
        }
        return true
    }
    struct Snapshot {
        var profile:DictationProfiles.Profile?
        var fields:[AXUIElement]
        var settingsExposed:Bool
    }
    private static func closeSettings(_ setting:AXUIElement){
        if let close=value(setting,kAXCloseButtonAttribute),CFGetTypeID(close)==AXUIElementGetTypeID(){
            _ = AXUIElementPerformAction(unsafeBitCast(close,to:AXUIElement.self),kAXPressAction as CFString);return
        }
        for node in walk(setting,limit:500) where string(node,kAXRoleAttribute)==kAXButtonRole && labels(node).contains(where:["close","close settings","닫기","설정 닫기"].contains){
            _ = AXUIElementPerformAction(node,kAXPressAction as CFString);return
        }
    }
    /// Background-only, read-only probe. Does not activate apps or open any UI.
    static func passive(pid:pid_t,bundle:String)->Snapshot {
        let root=AXUIElementCreateApplication(pid)
        guard let setting=settingsWindow(root) else{return .init(profile:nil,fields:[],settingsExposed:false)}
        var fields=[AXUIElement]()
        for node in walk(setting){
            guard labels(node,setting:true).contains(where:{isDictation($0,bundle:bundle)}) else{continue}
            let candidates=[kAXGroupRole,kAXRowRole].contains(string(node,kAXRoleAttribute)) ? walk(node,limit:60):[node]
            fields+=candidates.filter{[kAXComboBoxRole,kAXTextFieldRole,kAXButtonRole,kAXStaticTextRole].contains(string($0,kAXRoleAttribute))}
        }
        var profile=readSettings(setting,bundle:bundle);profile?.origin="auto"
        return .init(profile:profile,fields:fields,settingsExposed:!fields.isEmpty)
    }
    static func boundValues(_ fields:[AXUIElement],bundle:String)->Snapshot {
        var found=[DictationProfiles.Profile](),missing=false,alive=false
        for field in fields {
            guard let raw=value(field,kAXValueAttribute) as? String else{continue};alive=true
            if let key=parseDisplayed(raw){found.append(.init(key:key.key,flags:key.flags,mode:bundle=="com.openai.codex" ? .hold:.toggle,origin:"auto"))}
            else if ["no shortcut","not assigned","none","off","disabled","없음","사용 안 함"].contains(raw.lowercased()){missing=true}
        }
        let unique=found.reduce(into:[DictationProfiles.Profile]()){if !$0.contains($1){$0.append($1)}}
        return .init(profile:!missing && unique.count==1 ? unique[0]:nil,fields:fields,settingsExposed:alive && (missing || !found.isEmpty))
    }
    @MainActor static func detect(bundle:String,restoreView:Bool=false)async throws->DictationProfiles.Profile {
        try Task.checkCancellation()
        guard AXIsProcessTrusted() else{throw Failure.permission}
        if bundle=="com.openai.codex",let profile=await Task.detached(priority:.userInitiated,operation:{CodexDictationPreference.read()}).value{return profile}
        let app:NSRunningApplication
        if let running=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first{app=running}
        else{
            guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else{throw Failure.notInstalled}
            app=try await withCheckedThrowingContinuation{continuation in
                NSWorkspace.shared.openApplication(at:url,configuration:NSWorkspace.OpenConfiguration()){app,error in
                    if let app{continuation.resume(returning:app)}else{continuation.resume(throwing:error ?? Failure.notInstalled)}
                }
            }
        }
        app.activate(options:[.activateIgnoringOtherApps])
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier{break}
            try await Task.sleep(for:.milliseconds(50))
        }
        let root=AXUIElementCreateApplication(app.processIdentifier)
        _ = AXUIElementSetAttributeValue(root,"AXManualAccessibility" as CFString,kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(root,"AXEnhancedUserInterface" as CFString,kCFBooleanTrue)
        if var profile=await Task.detached(priority:.userInitiated,operation:{menuProfile(root,bundle:bundle)}).value{profile.origin="auto";return profile}
        let previousSettings=await Task.detached(priority:.userInitiated){settingsWindow(root)}.value
        try Task.checkCancellation()
        // Standard app Settings shortcut, scoped to the selected foreground app.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier==app.processIdentifier else{throw Failure.settingsUnavailable}
        for down in [true,false]{
            guard let event=CGEvent(keyboardEventSource:nil,virtualKey:43,keyDown:down) else{throw Failure.settingsUnavailable}
            event.flags = .maskCommand;event.post(tap:.cghidEventTap)
        }
        var setting:AXUIElement?
        let deadline=ProcessInfo.processInfo.systemUptime+15
        for _ in 0..<20 {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime<deadline else{break}
            if let found=await Task.detached(priority:.userInitiated,operation:{settingsWindow(root)}).value{setting=found;break}
            try await Task.sleep(for:.milliseconds(150))
        }
        guard var setting=setting else{throw Failure.settingsUnavailable}
        let firstScope=setting
        if var profile=await Task.detached(priority:.userInitiated,operation:{readSettings(firstScope,bundle:bundle)}).value{
            profile.origin="auto"
            if restoreView,previousSettings==nil{closeSettings(setting)}
            return profile
        }
        let tabs=bundle=="com.anthropic.claudefordesktop" ? ["desktop app","system","voice"]:["keyboard shortcuts","shortcuts","voice"]
        for tab in tabs {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime<deadline else{break}
            let scope=setting
            let matches=await Task.detached(priority:.userInitiated){walk(scope).filter{labels($0,setting:true).contains(tab)}}.value
            if let item=matches.first,AXUIElementPerformAction(item,kAXPressAction as CFString) == .success {
                try await Task.sleep(for:.milliseconds(250))
                setting=await Task.detached(priority:.userInitiated,operation:{settingsWindow(root)}).value ?? setting
                let updatedScope=setting
                if var profile=await Task.detached(priority:.userInitiated,operation:{readSettings(updatedScope,bundle:bundle)}).value{
                    profile.origin="auto"
                    if restoreView,previousSettings==nil{closeSettings(setting)}
                    return profile
                }
            }
        }
        try Task.checkCancellation()
        let lastScope=setting
        if await Task.detached(priority:.userInitiated,operation:{openAssignment(lastScope,bundle:bundle)}).value{throw Failure.assignmentOpened}
        throw Failure.notAssigned
    }
}
