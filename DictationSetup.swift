import Cocoa
import ApplicationServices

/// Captures a shortcut only while this explicitly focused setup control is recording.
final class DictationShortcutRecorder:NSButton {
    var profile:DictationProfiles.Profile? {didSet{refresh()}}
    var changed:(()->Void)?
    private var recording=false
    override var acceptsFirstResponder:Bool{true}
    init(){super.init(frame:.zero);bezelStyle = .rounded;target=self;action=#selector(beginRecording);setAccessibilityLabel(MacText("Dictation shortcut"));refresh()}
    required init?(coder:NSCoder){fatalError("init(coder:) is not supported")}
    private func refresh(){title=profile.map(DictationProfiles.display) ?? MacText("Click to record shortcut");setAccessibilityValue(title)}
    @objc private func beginRecording(){recording=true;window?.makeFirstResponder(self);title=MacText("Press your dictation shortcut…")}
    override func performKeyEquivalent(with event:NSEvent)->Bool{if recording{keyDown(with:event);return true};return super.performKeyEquivalent(with:event)}
    override func keyDown(with event:NSEvent){
        guard recording else{super.keyDown(with:event);return}
        if event.keyCode==53{recording=false;refresh();return}
        let flags=event.modifierFlags.intersection([.command,.control,.option,.shift])
        guard !flags.intersection([.command,.control,.option]).isEmpty else{title=MacText("Use ⌘, ⌥ or ⌃ with a key");return}
        profile = .init(key:event.keyCode,flags:UInt64(flags.rawValue),mode:profile?.mode ?? .hold)
        recording=false;changed?()
    }
}

@MainActor final class DictationSetupController:NSObject {
    private let choices:[(String,String)]=[("ChatGPT / Codex","com.openai.codex"),("ChatGPT (classic)","com.openai.chat"),("Claude Desktop","com.anthropic.claudefordesktop")]
    private let target=NSPopUpButton(),mode=NSPopUpButton(),recorder=DictationShortcutRecorder(),automatic=NSButton(),advanced=NSButton()
    private let instructions=NSTextField(wrappingLabelWithString:""),summary=NSTextField(labelWithString:"")
    private var manual=NSStackView(),accessory=NSStackView()
    private var panel:NSPanel?,detection:Task<Void,Never>?
    private var detectedNow=false,isConnecting=false,manualChanged=false
    private var shortcutObserver:NSObjectProtocol?,driverTimer:Timer?,installAction:(()->Void)?
    private let driverStatus=NSTextField(labelWithString:""),controlStatus=NSTextField(labelWithString:""),install=NSButton(),control=NSButton()
    private var appStatuses=[String:NSTextField](),appButtons=[NSButton](),validated=Set<String>(),unavailable=Set<String>()
    private var bundle:String{choices[target.indexOfSelectedItem].1}
    private func text(_ key:String,size:CGFloat=13,weight:NSFont.Weight = .regular,secondary:Bool=false)->NSTextField {
        let view=NSTextField(wrappingLabelWithString:MacText(key));view.font = .systemFont(ofSize:size,weight:weight)
        view.textColor=secondary ? .secondaryLabelColor:.labelColor
        view.setContentCompressionResistancePriority(.required,for:.vertical)
        return view
    }
    private func vertical(_ views:[NSView],spacing:CGFloat=12)->NSStackView {
        let stack=NSStackView(views:views);stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=spacing;stack.detachesHiddenViews=true
        for view in views{view.translatesAutoresizingMaskIntoConstraints=false;view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        return stack
    }
    private func button(_ button:NSButton,title:String,action:Selector){
        button.title=MacText(title);button.bezelStyle = .rounded;button.font = .systemFont(ofSize:13);button.controlSize = .regular;button.target=self;button.action=action
        button.heightAnchor.constraint(equalToConstant:30).isActive=true
    }
    private func accessRow(title:String,symbol:String,status:NSTextField,button:NSButton)->NSView {
        let icon=NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:nil) ?? NSImage());icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant:20).isActive=true;icon.heightAnchor.constraint(equalToConstant:20).isActive=true
        status.font = .systemFont(ofSize:12);status.textColor = .secondaryLabelColor
        let labels=vertical([text(title),status],spacing:2)
        let row=NSView()
        for view in [icon,labels,button]{view.translatesAutoresizingMaskIntoConstraints=false;row.addSubview(view)}
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant:48),
            icon.leadingAnchor.constraint(equalTo:row.leadingAnchor),icon.centerYAnchor.constraint(equalTo:row.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo:icon.trailingAnchor,constant:12),labels.centerYAnchor.constraint(equalTo:row.centerYAnchor),
            labels.trailingAnchor.constraint(equalTo:button.leadingAnchor,constant:-12),
            button.trailingAnchor.constraint(equalTo:row.trailingAnchor),button.centerYAnchor.constraint(equalTo:row.centerYAnchor),button.widthAnchor.constraint(equalToConstant:88)
        ])
        return row
    }
    func present(on window:NSWindow,installMicrophone:@escaping ()->Void){
        installAction=installMicrophone
        let sheet=NSPanel(contentRect:NSRect(x:0,y:0,width:440,height:450),styleMask:[.titled],backing:.buffered,defer:false)
        panel=sheet;sheet.title=MacText("Settings");sheet.isReleasedWhenClosed=false
        let heading=text("This Mac",weight:.semibold)
        button(control,title:"Allow…",action:#selector(enableControl));button(install,title:"Install…",action:#selector(installDriver))
        let access=vertical([accessRow(title:"Mac control",symbol:"cursorarrow",status:controlStatus,button:control),accessRow(title:"iPhone microphone",symbol:"mic",status:driverStatus,button:install)],spacing:8)
        let separator=NSBox();separator.boxType = .separator
        let dictation=text("Dictation",size:17,weight:.semibold)
        target.addItems(withTitles:choices.map{MacText($0.0)});target.target=self;target.action=#selector(targetChanged);target.font = .systemFont(ofSize:13);target.setAccessibilityLabel(MacText("Dictation app"))
        target.heightAnchor.constraint(equalToConstant:30).isActive=true
        summary.font = .systemFont(ofSize:13,weight:.medium)
        summary.setContentCompressionResistancePriority(.required,for:.vertical)
        instructions.font = .systemFont(ofSize:12);instructions.textColor = .secondaryLabelColor
        instructions.setContentCompressionResistancePriority(.required,for:.vertical)
        instructions.preferredMaxLayoutWidth=392
        button(automatic,title:"Connect",action:#selector(autoConnect));automatic.bezelStyle = .rounded
        advanced.title=MacText("Manual connection…");advanced.bezelStyle = .inline;advanced.font = .systemFont(ofSize:12);advanced.target=self;advanced.action=#selector(toggleManual)
        var appRows=[NSView]()
        let codexInstalled=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.openai.codex") != nil
        for index in [codexInstalled ? 0:1,2] {
            let name=choices[index].0,id=choices[index].1
            let status=NSTextField(labelWithString:"");appStatuses[id]=status
            let action=NSButton();button(action,title:"Connect",action:#selector(connectApp(_:)));action.tag=index;appButtons.append(action)
            let row=accessRow(title:name,symbol:"waveform",status:status,button:action)
            appRows.append(row)
        }
        let applications=vertical(appRows,spacing:8)
        recorder.font = .systemFont(ofSize:13);recorder.changed={[weak self] in self?.manualChanged=true;self?.updateSummary()}
        mode.font = .systemFont(ofSize:13);mode.addItems(withTitles:[MacText("Hold to dictate"),MacText("Press once to start / again to stop")]);mode.heightAnchor.constraint(equalToConstant:30).isActive=true
        mode.target=self;mode.action=#selector(manualModeChanged)
        manual=vertical([target,recorder,mode],spacing:8);manual.isHidden=true
        let done=NSButton();button(done,title:"Done",action:#selector(finish));done.keyEquivalent="\r";done.widthAnchor.constraint(equalToConstant:80).isActive=true
        let bottomSpacer=NSView();bottomSpacer.setContentHuggingPriority(.defaultLow,for:.horizontal)
        let bottom=NSStackView(views:[bottomSpacer,done]);bottom.orientation = .horizontal;bottom.alignment = .centerY
        accessory=vertical([heading,access,separator,dictation,applications,instructions,advanced,manual,bottom],spacing:12)
        accessory.setCustomSpacing(20,after:access);accessory.setCustomSpacing(20,after:separator);accessory.setCustomSpacing(20,after:manual)
        guard let content=sheet.contentView else{return};content.addSubview(accessory);accessory.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([accessory.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:24),accessory.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-24),accessory.topAnchor.constraint(equalTo:content.topAnchor,constant:24),accessory.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-20)])
        updateDriver();refresh();resize()
        driverTimer=Timer.scheduledTimer(withTimeInterval:1.5,repeats:true){[weak self] _ in self?.updateDriver()}
        shortcutObserver=NotificationCenter.default.addObserver(forName:Notification.Name("PocketTrackpadDictationShortcutChanged"),object:nil,queue:.main){[weak self] notice in
            Task{@MainActor in
                guard let self,let changed=notice.object as? String else{return}
                if notice.userInfo?["available"] as? Bool == false{self.unavailable.insert(changed);self.validated.remove(changed)}
                else{self.unavailable.remove(changed);self.validated.insert(changed)}
                self.refreshRows()
                guard changed==self.bundle,self.manual.isHidden else{return}
                self.recorder.profile=self.unavailable.contains(changed) ? nil:DictationProfiles.load(bundle:changed)
                if self.recorder.profile==nil{self.instructions.stringValue=MacText("No shortcut found. Set one in the app, then check again.")}
                self.detectedNow=true;self.updateSummary()
            }
        }
        // Read the existing Codex dictation preference without opening or changing it.
        // Each app keeps its own mapping; this never replaces the Claude connection.
        Task{@MainActor [weak self] in
            let profile=await Task.detached(priority:.userInitiated){CodexDictationPreference.read()}.value
            guard let self,self.panel != nil,let profile,DictationProfiles.load(bundle:"com.openai.codex")?.origin != "manual" else{return}
            DictationProfiles.save(profile,bundle:"com.openai.codex");DictationShortcutMonitor.shared.accept(profile,bundle:"com.openai.codex")
            self.validated.insert("com.openai.codex");self.unavailable.remove("com.openai.codex");self.refreshRows()
        }
        window.beginSheet(sheet)
    }
    private func resize(){
        guard let panel else{return}
        panel.contentView?.layoutSubtreeIfNeeded()
        let height=max(420,accessory.fittingSize.height+44)
        panel.setContentSize(NSSize(width:440,height:height))
    }
    @objc private func finish(){
        if let value=recorder.profile,manualChanged{DictationProfiles.save(.init(key:value.key,flags:value.flags,mode:mode.indexOfSelectedItem==0 ? .hold:.toggle,origin:"manual"),bundle:bundle)}
        detection?.cancel();detection=nil;MacNotice.shared.dismiss()
        driverTimer?.invalidate();driverTimer=nil
        if let observer=shortcutObserver{NotificationCenter.default.removeObserver(observer)};shortcutObserver=nil
        if let panel{panel.sheetParent?.endSheet(panel);panel.orderOut(nil)};panel=nil
    }
    @objc private func enableControl(){
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"){NSWorkspace.shared.open(url)}
    }
    @objc private func installDriver(){
        if MacVirtualMicrophone.deviceID() != 0,let url=URL(string:"x-apple.systempreferences:com.apple.preference.sound"){NSWorkspace.shared.open(url)}else{installAction?()}
    }
    private func updateDriver(){
        let ready=MacVirtualMicrophone.deviceID() != 0,trusted=AXIsProcessTrusted()
        controlStatus.stringValue=MacText(trusted ? "Enabled":"Permission needed")
        driverStatus.stringValue=MacText(ready ? "Installed":"Optional for voice input")
        control.title=MacText(trusted ? "Manage…":"Allow…");install.title=MacText(ready ? "Manage…":"Install…")
        automatic.isEnabled=ready && trusted && !isConnecting
        if #unavailable(macOS 14.2){automatic.isEnabled=false;driverStatus.stringValue=MacText("Dictation needs macOS 14.2 or later")}
        for action in appButtons{action.isEnabled=automatic.isEnabled}
    }
    @objc private func manualModeChanged(){manualChanged=true}
    @objc private func toggleManual(){
        if manual.isHidden{refresh()}
        manual.isHidden.toggle();advanced.title=MacText(manual.isHidden ? "Manual connection…":"Hide manual connection");resize()
    }
    private func updateSummary(){refreshRows();summary.stringValue=recorder.profile.map{MacText(detectedNow ? "Connected":"Saved shortcut")+" · "+DictationProfiles.display($0)} ?? MacText("Not connected");resize()}
    private func refreshRows(){
        for (id,status) in appStatuses {
            if isConnecting,id==bundle{status.stringValue=MacText("Connecting…");continue}
            if !unavailable.contains(id),let profile=DictationProfiles.load(bundle:id){status.stringValue=MacText(validated.contains(id) ? "Connected":"Saved shortcut")+" · "+DictationProfiles.display(profile)}
            else{status.stringValue=MacText("Not connected")}
        }
        for action in appButtons{action.title=MacText(DictationProfiles.load(bundle:choices[action.tag].1)==nil ? "Connect":"Check")}
    }
    @objc private func connectApp(_ sender:NSButton){target.selectItem(at:sender.tag);refresh();autoConnect()}
    @objc private func autoConnect(){
        guard automatic.isEnabled else{return}
        MacNotice.shared.dismiss()
        let selected=bundle
        // Once automatic setup is requested, never silently keep an old manual key.
        DictationProfiles.save(nil,bundle:selected);unavailable.insert(selected);validated.remove(selected);recorder.profile=nil;detectedNow=false;updateSummary()
        isConnecting=true
        automatic.isEnabled=false;target.isEnabled=false;advanced.isEnabled=false
        automatic.title=MacText("Connecting…")
        instructions.stringValue=MacText("Checking the app’s dictation settings…")
        detection=Task{@MainActor [weak self] in
            guard let self else{return}
            defer{self.isConnecting=false;self.updateDriver();self.target.isEnabled=true;self.advanced.isEnabled=true;self.automatic.title=MacText("Check again");self.refreshRows()}
            do{
                let profile=try await DictationShortcutDiscovery.detect(bundle:selected,restoreView:true)
                guard !Task.isCancelled,selected==self.bundle,self.panel != nil else{return}
                self.detectedNow=true;self.validated.insert(selected);self.unavailable.remove(selected);self.recorder.profile=profile;self.mode.selectItem(at:profile.mode == .hold ? 0:1);self.updateSummary()
                DictationProfiles.save(profile,bundle:selected)
                DictationShortcutMonitor.shared.accept(profile,bundle:selected)
                self.instructions.stringValue=MacText("Ready. Click the app’s input, then use the iPhone microphone.");self.resize()
                self.panel?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            }catch{
                guard !Task.isCancelled,self.panel != nil else{return}
                let message:String
                switch error {
                case DictationShortcutDiscovery.Failure.assignmentOpened:
                    self.instructions.stringValue=MacText("Set a shortcut in the app, then click Check again.")
                    self.resize();self.showAssignmentGuide(bundle:selected);return
                case DictationShortcutDiscovery.Failure.permission:message="Enable Mac control first, then try again."
                case DictationShortcutDiscovery.Failure.notInstalled:message="Install the selected app first, then try again."
                case DictationShortcutDiscovery.Failure.settingsUnavailable:message="The app did not expose its settings. Open its dictation settings, then read again."
                default:message="No shortcut found. Set one in the app, then check again."
                }
                self.instructions.stringValue=MacText(message);self.resize()
                MacNotice.shared.show(settings:{[weak self] in self?.panel?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)})
                self.panel?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            }
        }
    }
    private func showAssignmentGuide(bundle:String){
        MacNotice.shared.show(title:"Set a dictation shortcut",message:"Choose a shortcut in the app, then check again.",actionTitle:"Check again",sticky:true,settings:{[weak self] in self?.autoConnect()})
    }
    @objc private func targetChanged(){refresh()}
    private func refresh(){
        manualChanged=false
        detectedNow=false;automatic.title=MacText("Connect");recorder.profile=DictationProfiles.load(bundle:bundle)
        mode.selectItem(at:recorder.profile?.mode == .toggle ? 1:0);updateSummary()
        instructions.stringValue=MacText("Both apps stay connected. The microphone follows the app you’re typing in.")
    }
}
