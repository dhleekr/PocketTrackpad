import Cocoa
import ApplicationServices
import CoreImage

@_silgen_name("PocketPostDockMotion") private func PocketPostDockMotion(_ progress:Double,_ delta:Double,_ velocity:Double,_ axis:Int32,_ phase:Int32)->Bool
@_silgen_name("PocketPostDock") private func PocketPostDock(_ progress:Double,_ velocity:Double,_ axis:Int32,_ phase:Int32)->Bool
@_silgen_name("PocketPostNotification") private func PocketPostNotification(_ progress:Double,_ delta:Double,_ velocity:Double,_ phase:Int32)->Bool
@_silgen_name("PocketPostRotate") private func PocketPostRotate(_ delta:Double,_ phase:Int32)->Bool
@_silgen_name("PocketPostSmartZoom") private func PocketPostSmartZoom()->Bool
@_silgen_name("PocketPostMagnify") private func PocketPostMagnify(_ delta:Double,_ phase:Int32)->Bool

#if POCKET_LOCAL_TEST
@_silgen_name("PocketStartGestureCapture") private func PocketStartGestureCapture(_ path:UnsafePointer<CChar>)->Bool
@_silgen_name("PocketStopGestureCapture") private func PocketStopGestureCapture()
#endif

// The permission-owning GUI process also owns every generated input event.
final class InputEngine {
    #if POCKET_LOCAL_TEST
    var localWheelOnly=false
    #endif
    private var dragging = false
    private var magnifying = false
    private var rotating=false
    private let keyRepeater=MacKeyRepeater()
    private var dockAxis:Int32=0
    private var dockProgress=0.0
    private var lastInput = Date()
    private var cursorPosition = CGEvent(source:nil)?.location ?? .zero
    private var lastMotion = Date.distantPast
    private var scrollStream=NativeScrollStream()
    private let eventLock = NSLock()
    private var cursorBounds=CursorBounds(readDisplays:{
        var ids=[CGDirectDisplayID](repeating:0,count:32),count:UInt32=0
        guard CGGetActiveDisplayList(UInt32(ids.count),&ids,&count) == .success else{return []}
        return ids.prefix(Int(count)).map{CGDisplayBounds($0)}
    })
    private var watchdog: DispatchSourceTimer!
    private let playback=MotionPlayback()
    private let diagnostics=PadDiagnostics()
    private var diagnosticDeadline:Double?
    private var displayClock:MotionDisplayClock?
    private var pacingAvailable=false
    private var arrivalCadence=InputCadence(),sourceCadence=InputCadence(),renderCadence=InputCadence(),packetCadence=InputCadence(),sendCadence=InputCadence()
    private let timingFolder=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PocketTrackpad")
    init() {
        watchdog = DispatchSource.makeTimerSource(queue:DispatchQueue.global())
        watchdog.schedule(deadline:.now()+1,repeating:1)
        watchdog.setEventHandler { [weak self] in
            guard let self else { return }
            self.eventLock.lock();defer { self.eventLock.unlock() }
            if Date().timeIntervalSince(self.lastInput)>3 { self.releaseDrag() }
            self.writeTimingIfRequested()
            self.finishDiagnosticsIfReady()
        }
        watchdog.resume()
        let clock=MotionDisplayClock{[weak self] in self?.advanceMotionFrame()}
        pacingAvailable=clock.start();displayClock=clock
    }
    deinit {displayClock=nil;watchdog?.cancel()}
    private func writeTimingIfRequested(){
        guard FileManager.default.fileExists(atPath:timingFolder.appendingPathComponent("timing.enabled").path) else{return}
        let report:[String:Any]=["source":sourceCadence.summary,"arrival":arrivalCadence.summary,"render":renderCadence.summary,"packets":packetCadence.summary,"sender":sendCadence.summary,"display_pacing":pacingAvailable,"playback_delay_ms":1000.0/60.0,"intervals_ms":["source":sourceCadence.intervalsMS,"packets":packetCadence.intervalsMS,"sender":sendCadence.intervalsMS,"render":renderCadence.intervalsMS]]
        if let data=try? JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]){try? data.write(to:timingFolder.appendingPathComponent("timing.json"),options:.atomic)}
    }
    private func finishDiagnosticsIfReady(){
        let now=ProcessInfo.processInfo.systemUptime
        let requested=timingFolder.appendingPathComponent("diagnostics-ble.request")
        if FileManager.default.fileExists(atPath:requested.path){
            try? FileManager.default.removeItem(at:requested)
            diagnostics.start(bluetooth:true,remoteClock:true);diagnosticDeadline=now+15
        }
        guard let deadline=diagnosticDeadline,now>=deadline else{return}
        diagnosticDeadline=nil;let report=diagnostics.finish(),url=timingFolder.appendingPathComponent("diagnostics-latest.json")
        DispatchQueue.global(qos:.utility).async {
            if let data=try? JSONEncoder().encode(report){try? data.write(to:url,options:.atomic)}
        }
    }
    private func advanceMotionFrame(){
        eventLock.lock();defer{eventLock.unlock()}
        guard playback.active else{return}
        guard AXIsProcessTrusted() else{playback.discard();return}
        playback.frame(at:ProcessInfo.processInfo.systemUptime){[self] event in
            renderCadence.record(ProcessInfo.processInfo.systemUptime);_ = applyEvent(event)
        }
    }
    private func releaseDrag() {
        keyRepeater.stop();playback.discard();if let cancelled=scrollStream.cancel(){NativeScrollStream.post(cancelled)}
        if dockAxis != 0 {if dockAxis==9{_ = PocketPostNotification(dockProgress,0,0,8)}else{_ = PocketPostDock(dockProgress,0,dockAxis,8)};dockAxis=0;dockProgress=0}
        if rotating{_ = PocketPostRotate(0,4);rotating=false}
        if magnifying { _ = PocketPostMagnify(0,4);magnifying=false }
        if dragging {
            let release=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:CGEvent(source:nil)?.location ?? .zero,mouseButton:.left)
            release?.flags=[];release?.post(tap:.cghidEventTap)
            dragging=false
        }
    }
    func handle(_ d: [String:Any])->String {
        eventLock.lock();defer { eventLock.unlock() }
        if d["type"] as? String=="status",let name=d["name"] as? String {
            if name=="diagnosticBeginWiFi" || name=="diagnosticBeginBluetooth" {
                diagnostics.start(bluetooth:name=="diagnosticBeginBluetooth",remoteClock:true)
                diagnosticDeadline=ProcessInfo.processInfo.systemUptime+15;return "ok"
            }
            if name=="diagBLEState" {
                diagnostics.record(.bleState,count:d["count"] as? Int,pending:Int(d["y"] as? Double ?? 0),value:d["x"] as? Double);return "ok"
            }
            if name=="diagBLEAuth" {diagnostics.record(.bleAuth);return "ok"}
        }
        lastInput=Date()
        if d["type"] as? String=="status",d["name"] as? String=="transportFrame" {
            playback.setDelay(d["transport"] as? String=="bluetooth" ? 1.0/30.0:1.0/60.0){[self] event in _ = applyEvent(event)}
            diagnostics.record(.receive,source:d["t"] as? Double,sequence:d["sequence"] as? Int)
            packetCadence.record(ProcessInfo.processInfo.systemUptime)
            if let t=d["t"] as? Double,t.isFinite{sendCadence.record(t)}
            return "ok"
        }
        diagnostics.record(.gesture,source:d["t"] as? Double,event:d["type"] as? String,phase:d["phase"] as? String,momentum:d["momentum"] as? String,value:hypot(d["x"] as? Double ?? 0,d["y"] as? Double ?? 0))
        guard AXIsProcessTrusted() else{playback.discard();return "permission"}
        if pacingAvailable {
            let now=ProcessInfo.processInfo.systemUptime
            if MotionPlayback.isContinuous(d){arrivalCadence.record(now);if let source=d["t"] as? Double{sourceCadence.record(source)}}
            if playback.accept(d,at:now,apply:{[self] event in _ = applyEvent(event)}){return "ok"}
        }
        return applyEvent(d)
    }
    private func applyEvent(_ d:[String:Any])->String {
        do {
            guard let kind = d["type"] as? String else { throw NSError(domain:"input",code:1) }
            if kind == "status" { return AXIsProcessTrusted() ? "ready" : "permission" }
            guard AXIsProcessTrusted() else { return "permission" }
            let x = (d["x"] as? Double ?? 0), y = (d["y"] as? Double ?? 0)
            let observed = CGEvent(source:nil)?.location ?? .zero
            let p = Date().timeIntervalSince(lastMotion)<0.15 ? cursorPosition : observed
            if kind == "dockSwipe" {
                let axis:Int32=d["name"] as? String=="horizontal" ? 1:d["name"] as? String=="scale" ? 3:d["name"] as? String=="notification" ? 9:2
                let phase=d["phase"] as? String ?? "changed"
                // A zero-distance begin is ignored by the Dock on macOS 27.
                // Wait for the first movement and begin at that actual progress.
                if dockAxis==0 && phase != "ended" && phase != "cancelled" && x != 0 {
                    if axis==9 ? PocketPostNotification(x,x,0,1):(axis==2 ? PocketPostDockMotion(x,x,0,axis,1):PocketPostDock(x,0,axis,1)){dockAxis=axis;dockProgress=x}
                    return "ok"
                }
                if dockAxis != 0 {
                    let delta=x-dockProgress;dockProgress=x
                    let nativePhase:Int32=phase=="ended" ? 4:phase=="cancelled" ? 8:2
                    if dockAxis==9{_ = PocketPostNotification(x,delta,y,nativePhase)}else if dockAxis==2{_ = PocketPostDockMotion(x,delta,y,dockAxis,nativePhase)}else{_ = PocketPostDock(x,y,dockAxis,nativePhase)}
                    if phase=="ended" || phase=="cancelled" {dockAxis=0;dockProgress=0}
                }
            }else if kind == "key",let name=d["name"] as? String,let key=PadQuickKey(rawValue:name),key.repeatable {
                keyRepeater.handle(key,phase:d["phase"] as? String ?? "cancelled")
            }else if kind == "smartZoom" {_ = PocketPostSmartZoom()
            }else if kind == "rotate" {
                let phase=d["phase"] as? String ?? "changed"
                if phase=="ended" || phase=="cancelled"{if rotating{_ = PocketPostRotate(0,4)};rotating=false}
                else{if !rotating{rotating=PocketPostRotate(0,1)};if rotating && x != 0{_ = PocketPostRotate(x,2)}}
            } else if kind == "magnify" {
                let phase=d["phase"] as? String ?? "changed"
                if phase=="ended" || phase=="cancelled" { if magnifying{_ = PocketPostMagnify(0,4)};magnifying=false }
                else {
                    if !magnifying { magnifying=PocketPostMagnify(0,1) }
                    if magnifying && x != 0 { _ = PocketPostMagnify(x,2) }
                }
            } else if kind == "move" {
                let target = cursorBounds.clamp(CGPoint(x:p.x+x,y:p.y+y),at:ProcessInfo.processInfo.systemUptime)
                cursorPosition=target; lastMotion=Date()
                if let event=CGEvent(mouseEventSource:nil,mouseType:dragging ? .leftMouseDragged : .mouseMoved,mouseCursorPosition:target,mouseButton:.left) {
                    event.post(tap:.cghidEventTap)
                    diagnostics.record(.output,source:d["t"] as? Double,event:"move",value:hypot(x,y))
                }
            } else if kind == "scroll" {
                let phase = d["phase"] as? String ?? "changed"
                let momentum = d["momentum"] as? String ?? "none"
                if let event=scrollStream.event(x:x,y:y,phase:phase,momentum:momentum) {
                    #if POCKET_LOCAL_TEST
                    NativeScrollStream.post(event,companionEnabled:!localWheelOnly && d["name"] as? String != "contentOnly")
                    #else
                    NativeScrollStream.post(event,companionEnabled:d["name"] as? String != "contentOnly")
                    #endif
                    let actualPhase=[1:"began",2:"changed",4:"ended",8:"cancelled"][Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))]
                    let actualMomentum=[0:"none",1:"began",2:"changed",3:"ended"][Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))]
                    diagnostics.record(.output,source:d["t"] as? Double,event:"scroll",phase:actualPhase,momentum:actualMomentum,value:hypot(event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1),event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)))
                }
            } else if kind == "down" {
                if !dragging {
                    dragging=true
                    let press=CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:p,mouseButton:.left)
                    press?.flags=[];press?.post(tap:.cghidEventTap)
                }
            } else if kind == "up" { releaseDrag()
            } else if kind == "text", let text = d["text"] as? String {
                guard PadTextInput.valid(text) else{return "invalid"}
                for chars in PadTextInput.keyboardChunks(text) {
                    for down in [true,false] {
                        let event=CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:down)
                        event?.flags=[]
                        chars.withUnsafeBufferPointer{event?.keyboardSetUnicodeString(stringLength:chars.count,unicodeString:$0.baseAddress)}
                        event?.post(tap:.cghidEventTap)
                    }
                }
            } else if kind == "shortcut", let name = d["name"] as? String {
                let bindings:[String:(CGKeyCode,CGEventFlags)] = [
                    "back":(33,.maskCommand), "forward":(30,.maskCommand),
                    "desktopLeft":(123,.maskControl), "desktopRight":(124,.maskControl),
                    "mission":(126,.maskControl), "appWindows":(125,.maskControl),
                    "copy":(8,.maskCommand), "paste":(9,.maskCommand), "cut":(7,.maskCommand),
                    "undo":(6,.maskCommand), "selectAll":(0,.maskCommand),
                    "enter":(36,[]), "escape":(53,[]), "tab":(48,[]), "delete":(51,[]),
                    "left":(123,[]), "right":(124,[]), "up":(126,[]), "down":(125,[]),
                    "spotlight":(49,.maskCommand), "showDesktop":(103,[]), "switchApp":(48,.maskCommand),
                    "play":(49,[]), "lookup":(2,[.maskControl,.maskCommand]) ]
                if let key=PadQuickKey(rawValue:name){
                    for event in MacQuickKeys.events(for:key){event.post(tap:.cghidEventTap)}
                } else if ["notifications","apps"].contains(name){
                    MacSystemActions.perform(name)
                } else if name == "mission" {
                    // Invoke the system utility rather than depending on a configurable hotkey.
                    DispatchQueue.main.async {
                        NSWorkspace.shared.open(URL(fileURLWithPath:"/System/Applications/Mission Control.app"))
                    }
                } else if let (key,flags) = bindings[name] {
                    let source=CGEventSource(stateID:.hidSystemState)
                    let modifiers:[(CGEventFlags,CGKeyCode)]=[(.maskControl,59),(.maskCommand,55),(.maskAlternate,58),(.maskShift,56)]
                    var active=CGEventFlags()
                    for (flag,code) in modifiers where flags.contains(flag) {
                        active.insert(flag)
                        let modifier=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true)
                        modifier?.type = .flagsChanged;modifier?.flags=active;modifier?.post(tap:.cghidEventTap)
                    }
                    let keyFlags:CGEventFlags=(123...126).contains(key) ? flags.union([.maskNumericPad,.maskSecondaryFn]):flags
                    for down in [true,false] {
                        let event=CGEvent(keyboardEventSource:source,virtualKey:key,keyDown:down)
                        event?.flags=keyFlags;event?.post(tap:.cghidEventTap)
                    }
                    for (flag,code) in modifiers.reversed() where flags.contains(flag) {
                        active.remove(flag)
                        let modifier=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false)
                        modifier?.type = .flagsChanged;modifier?.flags=active;modifier?.post(tap:.cghidEventTap)
                    }
                }
            } else if kind == "click" || kind == "right" || kind == "double" {
                let right = kind == "right"
                for index in 1...(kind == "double" ? 2 : 1) {
                let downEvent = CGEvent(mouseEventSource:nil,mouseType:right ? .rightMouseDown : .leftMouseDown,mouseCursorPosition:p,mouseButton:right ? .right : .left)
                // A tap carries no keyboard modifier from a previous synthetic shortcut.
                downEvent?.flags=[]
                downEvent?.setIntegerValueField(.mouseEventClickState,value:Int64(kind == "double" ? index : min(2,max(1,d["count"] as? Int ?? 1)))); downEvent?.post(tap:.cghidEventTap)
                let upEvent = CGEvent(mouseEventSource:nil,mouseType:right ? .rightMouseUp : .leftMouseUp,mouseCursorPosition:p,mouseButton:right ? .right : .left)
                upEvent?.flags=[]
                upEvent?.setIntegerValueField(.mouseEventClickState,value:Int64(kind == "double" ? index : min(2,max(1,d["count"] as? Int ?? 1)))); upEvent?.post(tap:.cghidEventTap)
                }
            }
            return "ok"
        } catch { return "invalid" }
    }
}

func MacText(_ key:String)->String {NSLocalizedString(key,comment:"")}

final class Host:NSObject,NSApplicationDelegate,NSWindowDelegate {
    private var window:NSWindow!
    private let engine=InputEngine()
    private var wifi:NativeWiFiHost?
    private var microphone:MacMicrophoneHost?
    private var dictationSetup:DictationSetupController?
    private var microphoneStatus:NSTextField!
    private var bluetooth:BLEReverseHost?
    private var permissionTimer:Timer?
    private var shortcutNoticeObserver:NSObjectProtocol?
    private var status:NSTextField!
    private var pairingLink=""
    private var latencyLabel:NSTextField!
    private var connectionState=HostConnectionState()
    #if POCKET_LOCAL_TEST
    private var pageTestTimer:Timer?
    @objc private func testNotification(){MacSystemActions.perform("notifications")}
    @objc private func testNotificationClose(){MacSystemActions.testCloseNotification()}
    @objc private func testWheel(){runPageTest(companion:false)}
    @objc private func testPan(){runPageTest(companion:true)}
    @objc private func testForward(){runPageTest(companion:true,direction:-1)}
    @objc private func testCancel(){runPageTest(companion:true,cancel:true)}
    private func runPageTest(companion:Bool,direction:Double=1,cancel:Bool=false){
        status.stringValue="Open the gesture test window within 5 seconds"
        DispatchQueue.main.asyncAfter(deadline:.now()+5){[weak self] in
            guard let self else{return}
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier=="local.doohyun.pockettrackpad.gesturetest" else{self.status.stringValue="Aborted: test window not frontmost";return}
            guard AXIsProcessTrusted() else{self.status.stringValue="Input permission missing";return}
            let saved=CGEvent(source:nil)!.location
            CGWarpMouseCursorPosition(CGPoint(x:550,y:NSScreen.screens.first!.frame.maxY-450))
            self.engine.localWheelOnly = !companion
            var frame=0
            self.pageTestTimer=Timer(timeInterval:1.0/120,repeats:true){[weak self] timer in
                guard let self else{timer.invalidate();return};frame+=1
                _ = self.engine.handle(["type":"scroll","x":frame<=36 ? (cancel ? (frame<=18 ? 1.0:-1.0):4.0)*direction:0.0,"y":0.0,"phase":frame>36 ? (cancel ? "cancelled":"ended"):frame==1 ? "began":"changed","momentum":"none","t":ProcessInfo.processInfo.systemUptime])
                if frame>36{timer.invalidate();DispatchQueue.main.asyncAfter(deadline:.now()+0.75){CGWarpMouseCursorPosition(saved);self.engine.localWheelOnly=false;self.status.stringValue="Controlled test complete"}}
            };RunLoop.main.add(self.pageTestTimer!,forMode:.common)
        }
    }
    #endif
    private func apply(_ input:[String:Any])->String {
        if input["type"] as? String=="status",input["name"] as? String=="connectionLatency",
           let value=input["x"] as? Double,let channel=input["transport"] as? String {
            DispatchQueue.main.async{[weak self] in
                guard let self else{return}
                self.connectionState.updateLatency(value,from:channel == "bluetooth" ? .bluetooth:.wifi,at:ProcessInfo.processInfo.systemUptime)
                self.refreshLatency()
            }
            return "ok"
        }
        return engine.handle(input)
    }
    private func refreshLatency(){
        guard connectionState.connected else{latencyLabel.stringValue="";return}
        if let value=connectionState.roundTripMS(at:ProcessInfo.processInfo.systemUptime) {
            latencyLabel.stringValue=String(format:MacText("Connection round-trip: %d ms"),value)
        } else {
            latencyLabel.stringValue=MacText("Connection round-trip: waiting for iPhone measurement")
        }
    }
    private func report(_ text:String,from transport:HostTransport){
        DispatchQueue.main.async{[weak self] in
            guard let self else{return}
            self.connectionState.update(text,from:transport)
            self.status.stringValue=MacText(self.connectionState.message)
            self.refreshLatency()
        }
    }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        _ = engine.handle(["type":"up"])
        Task{@MainActor in MacNotice.shared.dismiss();DictationShortcutMonitor.shared.stop();await microphone?.shutdown();MacVirtualMicrophone.restoreAbandonedInput();sender.reply(toApplicationShouldTerminate:true)}
        return .terminateLater
    }
    @MainActor @objc private func setupDictation(){
        guard window.attachedSheet==nil else{return}
        let setup=DictationSetupController();dictationSetup=setup;setup.present(on:window,installMicrophone:{[weak self] in self?.installMicrophone()})
    }
    @MainActor private func showDictationSettings(){
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true);setupDictation()
    }
    @objc private func setupMicrophone(){
        let installed=MacVirtualMicrophone.deviceID() != 0
        let alert=NSAlert()
        alert.messageText=MacText(installed ? "iPhone microphone is ready":"Set up iPhone microphone")
        alert.informativeText=MacText(installed ? "The virtual microphone is installed. Open Sound settings to check your input device, or reinstall if it is missing. Select the iPhone microphone in PocketTrackpad to start dictation.":"The macOS Installer will guide you through installing the optional virtual microphone. Only the installer requests administrator authorization. Audio restarts briefly; finish calls and recordings first.")
        alert.addButton(withTitle:MacText(installed ? "Open Sound settings":"Install microphone"))
        alert.addButton(withTitle:MacText(installed ? "Reinstall microphone":"Cancel"))
        if installed{alert.addButton(withTitle:MacText("Cancel"))}
        alert.beginSheetModal(for:window){[weak self] result in
            if installed && result == .alertFirstButtonReturn {
                if let url=URL(string:"x-apple.systempreferences:com.apple.preference.sound"){NSWorkspace.shared.open(url)}
            } else if (!installed && result == .alertFirstButtonReturn) || (installed && result == .alertSecondButtonReturn){self?.installMicrophone()}
        }
    }
    private func installMicrophone(){
        guard let package=Bundle.main.url(forResource:"PocketTrackpadMicrophone",withExtension:"pkg",subdirectory:"Microphone") else{
            let alert=NSAlert();alert.alertStyle = .warning
            alert.messageText=MacText("Microphone installer unavailable")
            alert.informativeText=MacText("Download the latest Mac app from the PocketTrackpad website and try again.")
            alert.beginSheetModal(for:window);return
        }
        // The signed package is opened by macOS Installer. The receiver never elevates itself.
        NSWorkspace.shared.open(package)
    }
    @objc private func revealConnection(_ notification:Notification){
        window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.setActivationPolicy(.accessory)
        Task{@MainActor in DictationShortcutMonitor.shared.start()}
        shortcutNoticeObserver=NotificationCenter.default.addObserver(forName:Notification.Name("PocketTrackpadDictationShortcutChanged"),object:nil,queue:.main){[weak self] notice in
            guard notice.userInfo?["available"] as? Bool == false else{return}
            Task{@MainActor [weak self] in MacNotice.shared.show(settings:{[weak self] in self?.showDictationSettings()})}
        }
        DistributedNotificationCenter.default().addObserver(self,selector:#selector(revealConnection(_:)),name:ReceiverInstance.reopen,object:String(ProcessInfo.processInfo.processIdentifier))
        let menu=NSMenu(),applicationItem=NSMenuItem(),applicationMenu=NSMenu()
        let controlMenu=NSMenuItem(title:MacText("Computer setup…"),action:#selector(enableControl),keyEquivalent:"");controlMenu.target=self;applicationMenu.addItem(controlMenu)
        let microphoneMenu=NSMenuItem(title:MacText("Microphone setup…"),action:#selector(setupMicrophone),keyEquivalent:"");microphoneMenu.target=self;applicationMenu.addItem(microphoneMenu)
        #if POCKET_LOCAL_TEST
        let testNotification=NSMenuItem(title:"Test Notification Center",action:#selector(testNotification),keyEquivalent:"");testNotification.target=self;applicationMenu.addItem(testNotification)
        let testClose=NSMenuItem(title:"Test Notification Center Close",action:#selector(testNotificationClose),keyEquivalent:"");testClose.target=self;applicationMenu.addItem(testClose)
        #endif
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(NSMenuItem(title:MacText("Quit PocketTrackpad"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        applicationItem.submenu=applicationMenu;menu.addItem(applicationItem);NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:380,height:420),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="PocketTrackpad for Mac";window.delegate=self;window.isReleasedWhenClosed=false
        window.contentMinSize=NSSize(width:380,height:420)
        guard let content=window.contentView else{return}
        func label(_ text:String,size:CGFloat=13,secondary:Bool=false)->NSTextField {
            let field=NSTextField(wrappingLabelWithString:text)
            field.font = .systemFont(ofSize:size);field.textColor=secondary ? .secondaryLabelColor:.labelColor
            field.setContentCompressionResistancePriority(.required,for:.vertical)
            return field
        }
        let title=label("PocketTrackpad",size:20);title.font = .systemFont(ofSize:20,weight:.semibold)
        let subtitle=label(MacText("Your iPhone. Your Mac trackpad."),size:12,secondary:true)
        let identity=NSStackView(views:[title,subtitle]);identity.orientation = .vertical;identity.alignment = .leading;identity.spacing=3
        let icon=NSImageView(image:NSApp.applicationIconImage);icon.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant:34),icon.heightAnchor.constraint(equalToConstant:34)])
        let heading=NSStackView(views:[icon,identity]);heading.orientation = .horizontal;heading.alignment = .centerY;heading.spacing=10
        status=label(MacText("Waiting for iPhone"),size:13);status.alignment = .center
        latencyLabel=label("",size:11,secondary:true);latencyLabel.alignment = .center
        latencyLabel.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular)
        latencyLabel.toolTip=MacText("Round-trip time between iPhone and Mac, not total input-to-display latency.")
        let connection=NSStackView(views:[status,latencyLabel]);connection.orientation = .vertical;connection.alignment = .centerX;connection.spacing=4
        let qr=NSImageView();qr.imageScaling = .scaleProportionallyUpOrDown
        qr.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([qr.widthAnchor.constraint(equalToConstant:144),qr.heightAnchor.constraint(equalToConstant:144)])
        let hint=label(MacText("Open PocketTrackpad on iPhone and scan this QR. Then choose Wi-Fi or Bluetooth."),size:12,secondary:true);hint.alignment = .center
        let separator=NSBox();separator.boxType = .separator
        let setup=NSButton(title:MacText("Settings…"),target:self,action:#selector(setupDictation))
        setup.bezelStyle = .rounded;setup.font = .systemFont(ofSize:13)
        setup.image=NSImage(systemSymbolName:"gearshape",accessibilityDescription:nil);setup.imagePosition = .imageLeading
        setup.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([setup.widthAnchor.constraint(equalToConstant:132),setup.heightAnchor.constraint(equalToConstant:30)])
        microphoneStatus=label("",size:12,secondary:true);microphoneStatus.isHidden=true
        microphoneStatus.alignment = .center
        let note=label(MacText("Closing this window keeps the connection running."),size:11,secondary:true)
        note.alignment = .center
        let footer=NSStackView(views:[note]);footer.orientation = .vertical;footer.alignment = .centerX
        let stack=NSStackView(views:[heading,connection,qr,hint,separator,setup,microphoneStatus]);stack.orientation = .vertical;stack.alignment = .centerX;stack.spacing=12
        for item in [stack,footer]{item.translatesAutoresizingMaskIntoConstraints=false;content.addSubview(item)}
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:22),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-22),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:20),stack.bottomAnchor.constraint(lessThanOrEqualTo:footer.topAnchor,constant:-16),footer.leadingAnchor.constraint(equalTo:stack.leadingAnchor),footer.trailingAnchor.constraint(equalTo:stack.trailingAnchor),footer.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-16)])
        for item in [heading,connection,hint,separator,microphoneStatus!]{item.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true}
        microphoneStatus.setContentHuggingPriority(.defaultLow,for:.horizontal)
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        #if POCKET_LOCAL_TEST
        if ProcessInfo.processInfo.arguments.contains("--capture-trackpad") {
            let path=NSTemporaryDirectory()+"PocketTrackpad-native-gestures.jsonl"
            let started=path.withCString{PocketStartGestureCapture($0)}
            status.stringValue=started ? "Gesture capture ready (60 seconds)":"Gesture capture unavailable"
            DispatchQueue.main.asyncAfter(deadline:.now()+60){PocketStopGestureCapture()}
        }
        #endif
        do {
            let key=try PairingKey.load()
            let address=MacNetworkAddress.ipv4() ?? "127.0.0.1"
            pairingLink="pockettrackpad://\(address):8766/#\(key)"
            if let filter=CIFilter(name:"CIQRCodeGenerator") {
                filter.setValue(Data(pairingLink.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
                if let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)),let cg=CIContext().createCGImage(output,from:output.extent){qr.image=NSImage(cgImage:cg,size:NSSize(width:184,height:184))}
            }
            microphone=try? MacMicrophoneHost(token:key,report:{[weak self] text in
                let failed=text.hasPrefix("Microphone start failed:")
                let message:String
                if text.hasSuffix("setupRequired") || text.hasSuffix("buttonUnavailable"){message="Connect a dictation shortcut in the Mac app first."}
                else if text.hasSuffix("alreadyRecording"){message="Finish the existing GPT recording before starting the iPhone microphone."}
                else{message=failed ? "Could not open GPT dictation. Click the GPT input and try again.":text}
                self?.microphoneStatus.stringValue=MacText(message)
                if failed{Task{@MainActor [weak self] in MacNotice.shared.show(settings:{[weak self] in self?.showDictationSettings()})}}
                self?.microphoneStatus.isHidden = !(failed || text=="iPhone microphone active" || text=="Stop recording in GPT; virtual microphone is silent")
                // Bounded startup stages only: no audio, transcripts, tokens or window contents.
                let url=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("PocketTrackpad-microphone-stages.json")
                var events=(try? JSONSerialization.jsonObject(with:Data(contentsOf:url))) as? [[String:String]] ?? []
                events.append(["time":ISO8601DateFormatter().string(from:Date()),"stage":text])
                if let data=try? JSONSerialization.data(withJSONObject:Array(events.suffix(32))),FileManager.default.createFile(atPath:url.path,contents:data,attributes:[.posixPermissions:0o600]) == false {return}
            })
            wifi=try NativeWiFiHost(token:key,apply:{[weak self] in self?.apply($0) ?? "invalid"},report:{[weak self] in self?.report($0,from:.wifi)})
            bluetooth=BLEReverseHost(apply:{[weak self] in self?.apply($0) ?? "invalid"},report:{[weak self] in self?.report($0,from:.bluetooth)},microphoneReceive:{[weak self] packet,peer,send in Task{@MainActor in await self?.microphone?.receiveBluetooth(packet,peer:peer,send:send)}},microphoneClose:{[weak self] peer in Task{@MainActor in await self?.microphone?.closeBluetooth(peer:peer)}})
        }catch{status.stringValue=MacText("Could not start. Reopen PocketTrackpad.")}
        permissionTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in
            self?.refreshLatency()
            setup.toolTip=MacText(AXIsProcessTrusted() ? "Mac control enabled":"Enable Mac control")
            self?.window.title=AXIsProcessTrusted() ? "PocketTrackpad for Mac":MacText("PocketTrackpad · Enable Mac control")
        }
    }
    @objc private func enableControl(){
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"){NSWorkspace.shared.open(url)}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{sender.orderOut(nil);return false}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{window.makeKeyAndOrderFront(nil);sender.activate(ignoringOtherApps:true);return false}
    func applicationWillTerminate(_ notification:Notification){if let shortcutNoticeObserver{NotificationCenter.default.removeObserver(shortcutNoticeObserver)};DistributedNotificationCenter.default().removeObserver(self);permissionTimer?.invalidate();_ = engine.handle(["type":"up"]);wifi=nil;bluetooth=nil}
}

@main struct PocketTrackpadMain {
    static func main(){
        let app=NSApplication.shared
        if let existing=ReceiverInstance.existing() {
            DistributedNotificationCenter.default().postNotificationName(ReceiverInstance.reopen,object:String(existing.processIdentifier),userInfo:nil,deliverImmediately:true)
            existing.activate(options:[.activateAllWindows,.activateIgnoringOtherApps])
            return
        }
        let delegate=Host();app.delegate=delegate;app.run()
    }
}
