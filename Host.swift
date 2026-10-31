import Cocoa
import ApplicationServices
import CoreImage

@_silgen_name("PocketPostDock") private func PocketPostDock(_ progress:Double,_ velocity:Double,_ axis:Int32,_ phase:Int32)->Bool
@_silgen_name("PocketPostMagnify") private func PocketPostMagnify(_ delta:Double,_ phase:Int32)->Bool

// The permission-owning GUI process also owns every generated input event.
final class InputEngine {
    #if POCKET_LOCAL_TEST
    var localWheelOnly=false
    #endif
    private var dragging = false
    private var magnifying = false
    private var dockAxis:Int32=0
    private var dockProgress=0.0
    private var lastInput = Date()
    private var cursorPosition = CGEvent(source:nil)?.location ?? .zero
    private var lastMotion = Date.distantPast
    private var scrollStream=NativeScrollStream()
    private let eventLock = NSLock()
    private let screens: [CGRect]
    private var watchdog: DispatchSourceTimer!
    private let playback=MotionPlayback()
    private let diagnostics=PadDiagnostics()
    private var diagnosticDeadline:Double?
    private var displayClock:MotionDisplayClock?
    private var pacingAvailable=false
    private var arrivalCadence=InputCadence(),sourceCadence=InputCadence(),renderCadence=InputCadence(),packetCadence=InputCadence(),sendCadence=InputCadence()
    private let timingFolder=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PocketTrackpad")
    init() {
        var ids = [CGDirectDisplayID](repeating:0,count:32)
        var count: UInt32 = 0
        CGGetActiveDisplayList(32,&ids,&count)
        screens = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
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
    private func clamp(_ target:CGPoint)->CGPoint {
        if screens.contains(where:{$0.contains(target)}) { return target }
        return screens.map { bounds in CGPoint(x:max(bounds.minX,min(bounds.maxX-0.01,target.x)),y:max(bounds.minY,min(bounds.maxY-0.01,target.y))) }.min { a,b in hypot(a.x-target.x,a.y-target.y)<hypot(b.x-target.x,b.y-target.y) } ?? target
    }
    private func releaseDrag() {
        playback.discard();if let cancelled=scrollStream.cancel(){NativeScrollStream.post(cancelled)}
        if dockAxis != 0 {_ = PocketPostDock(dockProgress,0,dockAxis,8);dockAxis=0;dockProgress=0}
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
                let axis:Int32=d["name"] as? String=="horizontal" ? 1:2
                let phase=d["phase"] as? String ?? "changed"
                // A zero-distance begin is ignored by the Dock on macOS 27.
                // Wait for the first movement and begin at that actual progress.
                if dockAxis==0 && phase != "ended" && phase != "cancelled" && x != 0 {
                    if PocketPostDock(x,0,axis,1){dockAxis=axis;dockProgress=x}
                    return "ok"
                }
                if dockAxis != 0 {
                    dockProgress=x
                    _ = PocketPostDock(x,y,dockAxis,phase=="ended" ? 4:phase=="cancelled" ? 8:2)
                    if phase=="ended" || phase=="cancelled" {dockAxis=0;dockProgress=0}
                }
            } else if kind == "magnify" {
                let phase=d["phase"] as? String ?? "changed"
                if phase=="ended" || phase=="cancelled" { if magnifying{_ = PocketPostMagnify(0,4)};magnifying=false }
                else {
                    if !magnifying { magnifying=PocketPostMagnify(0,1) }
                    if magnifying && x != 0 { _ = PocketPostMagnify(x,2) }
                }
            } else if kind == "move" {
                let target = clamp(CGPoint(x:p.x+x,y:p.y+y))
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
                    NativeScrollStream.post(event,companionEnabled:!localWheelOnly)
                    #else
                    NativeScrollStream.post(event)
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
                let chars = Array(text.utf16)
                let event = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:true)
                chars.withUnsafeBufferPointer { event?.keyboardSetUnicodeString(stringLength:chars.count,unicodeString:$0.baseAddress) }
                event?.post(tap:.cghidEventTap)
                let up = CGEvent(keyboardEventSource:nil,virtualKey:0,keyDown:false)
                chars.withUnsafeBufferPointer { up?.keyboardSetUnicodeString(stringLength:chars.count,unicodeString:$0.baseAddress) }
                up?.post(tap:.cghidEventTap)
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
                    "play":(49,[]) ]
                if name == "mission" {
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
    private var bluetooth:BLEReverseHost?
    private var permissionTimer:Timer?
    private var status:NSTextField!
    private var pairingLink=""
    private var hidAfterConnection=false
    private var connectionState=HostConnectionState()
    #if POCKET_LOCAL_TEST
    private var pageTestTimer:Timer?
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
        let result=engine.handle(input)
        if input["type"] as? String=="status",result=="ready" {
            DispatchQueue.main.async{[weak self] in guard let self,!self.hidAfterConnection else{return};self.hidAfterConnection=true;self.window.orderOut(nil)}
        }
        return result
    }
    private func report(_ text:String,from transport:HostTransport){
        DispatchQueue.main.async{[weak self] in
            guard let self else{return}
            self.connectionState.update(text,from:transport)
            self.status.stringValue=MacText(self.connectionState.message)
            if text=="Wi-Fi connected" || text=="Bluetooth connected" {
                // A fresh authenticated session hides a QR reopened after an earlier session.
                if self.engine.handle(["type":"status"])=="ready" {
                    self.hidAfterConnection=true;self.window.orderOut(nil)
                }
            } else if !self.connectionState.connected {
                self.hidAfterConnection=false
            }
        }
    }
    func applicationDidFinishLaunching(_ notification:Notification){
        NSApp.setActivationPolicy(.accessory)
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:440,height:500),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        window.title="PocketTrackpad for Mac";window.delegate=self;window.isReleasedWhenClosed=false
        let title=NSTextField(labelWithString:"PocketTrackpad")
        title.font = .systemFont(ofSize:27,weight:.semibold);title.frame=NSRect(x:30,y:441,width:380,height:37);window.contentView?.addSubview(title)
        let subtitle=NSTextField(wrappingLabelWithString:MacText("Your iPhone. Your Mac trackpad."))
        subtitle.textColor = .secondaryLabelColor;subtitle.frame=NSRect(x:30,y:408,width:380,height:26);window.contentView?.addSubview(subtitle)
        status=NSTextField(labelWithString:MacText("Waiting for iPhone"));status.alignment = .center;status.frame=NSRect(x:25,y:365,width:390,height:24);window.contentView?.addSubview(status)
        let qr=NSImageView(frame:NSRect(x:128,y:155,width:184,height:184));qr.imageScaling = .scaleProportionallyUpOrDown;window.contentView?.addSubview(qr)
        let hint=NSTextField(wrappingLabelWithString:MacText("Open PocketTrackpad on iPhone and scan this QR. Then choose Wi-Fi or Bluetooth."))
        hint.alignment = .center;hint.font = .systemFont(ofSize:13);hint.textColor = .secondaryLabelColor;hint.frame=NSRect(x:35,y:104,width:370,height:45);window.contentView?.addSubview(hint)
        let copy=NSButton(title:MacText("Copy pairing link"),target:self,action:#selector(copyPairing));copy.frame=NSRect(x:30,y:62,width:185,height:32);window.contentView?.addSubview(copy)
        let permission=NSButton(title:MacText("Enable Mac control"),target:self,action:#selector(enableControl));permission.frame=NSRect(x:225,y:62,width:185,height:32);window.contentView?.addSubview(permission)
        let note=NSTextField(labelWithString:MacText("Closing this window keeps the connection running."));note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor;note.frame=NSRect(x:30,y:25,width:290,height:22);window.contentView?.addSubview(note)
        let quit=NSButton(title:MacText("Quit"),target:NSApp,action:#selector(NSApplication.terminate(_:)));quit.frame=NSRect(x:337,y:20,width:73,height:29);window.contentView?.addSubview(quit)
        #if POCKET_LOCAL_TEST
        let testWheel=NSButton(title:"Test wheel",target:self,action:#selector(testWheel));testWheel.frame=NSRect(x:20,y:340,width:190,height:25);window.contentView?.addSubview(testWheel)
        let testPan=NSButton(title:"Test wheel + pan",target:self,action:#selector(testPan));testPan.frame=NSRect(x:220,y:340,width:190,height:25);window.contentView?.addSubview(testPan)
        let testForward=NSButton(title:"Test forward",target:self,action:#selector(testForward));testForward.frame=NSRect(x:420,y:340,width:150,height:25);window.contentView?.addSubview(testForward)
        let testCancel=NSButton(title:"Test cancel",target:self,action:#selector(testCancel));testCancel.frame=NSRect(x:580,y:340,width:150,height:25);window.contentView?.addSubview(testCancel)
        #endif
        window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        do {
            let key=try PairingKey.load()
            let address=MacNetworkAddress.ipv4() ?? "127.0.0.1"
            pairingLink="pockettrackpad://\(address):8766/#\(key)"
            if let filter=CIFilter(name:"CIQRCodeGenerator") {
                filter.setValue(Data(pairingLink.utf8),forKey:"inputMessage");filter.setValue("M",forKey:"inputCorrectionLevel")
                if let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:8,y:8)),let cg=CIContext().createCGImage(output,from:output.extent){qr.image=NSImage(cgImage:cg,size:NSSize(width:184,height:184))}
            }
            wifi=try NativeWiFiHost(token:key,apply:{[weak self] in self?.apply($0) ?? "invalid"},report:{[weak self] in self?.report($0,from:.wifi)})
            bluetooth=BLEReverseHost(apply:{[weak self] in self?.apply($0) ?? "invalid"},report:{[weak self] in self?.report($0,from:.bluetooth)})
        }catch{status.stringValue=MacText("Could not start. Reopen PocketTrackpad.")}
        permissionTimer=Timer.scheduledTimer(withTimeInterval:1,repeats:true){[weak self] _ in
            self?.window.title=AXIsProcessTrusted() ? "PocketTrackpad for Mac":MacText("PocketTrackpad · Enable Mac control")
        }
    }
    @objc private func copyPairing(){NSPasteboard.general.clearContents();NSPasteboard.general.setString(pairingLink,forType:.string)}
    @objc private func enableControl(){
        let options=[kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"){NSWorkspace.shared.open(url)}
    }
    func windowShouldClose(_ sender:NSWindow)->Bool{sender.orderOut(nil);return false}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool{window.makeKeyAndOrderFront(nil);sender.activate(ignoringOtherApps:true);return false}
    func applicationWillTerminate(_ notification:Notification){permissionTimer?.invalidate();_ = engine.handle(["type":"up"]);wifi=nil;bluetooth=nil}
}

@main struct PocketTrackpadMain {
    static func main(){let app=NSApplication.shared;let delegate=Host();app.delegate=delegate;app.run()}
}
