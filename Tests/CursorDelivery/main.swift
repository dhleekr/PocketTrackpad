import Cocoa
final class Probe:NSObject {
 var window:NSWindow!,label:NSTextField!,timer:Timer?
 var received=0,monitor:Any?
 func start(){
  window=NSWindow(contentRect:NSRect(x:200,y:200,width:720,height:180),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="PocketTrackpad cursor delivery test";window.acceptsMouseMovedEvents=true
  monitor=NSEvent.addLocalMonitorForEvents(matching:.mouseMoved){[weak self] e in self?.received+=1;return e}
  label=NSTextField(labelWithString:"Cursor delivery A/B test — no clicks or keystrokes are generated");label.frame=NSRect(x:20,y:110,width:680,height:40);window.contentView!.addSubview(label)
  for (i,title) in ["Queued pointer","Direct pointer","Unmerged pointer"].enumerated(){let b=NSButton(title:title,target:self,action:i==0 ? #selector(queued):i==1 ? #selector(direct):#selector(unmerged));b.frame=NSRect(x:10+i*235,y:30,width:230,height:40);window.contentView!.addSubview(b)}
  window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
 }
 @objc func queued(){run(warp:false)}
 @objc func direct(){run(warp:true)}
 @objc func unmerged(){run(warp:false,unmerged:true)}
 func run(warp:Bool,unmerged:Bool=false){
  guard AXIsProcessTrusted() else{label.stringValue="Input permission missing";return}
  DispatchQueue.main.asyncAfter(deadline:.now()+1){
   self.received=0;let saved=CGEvent(source:nil)!.location
   let point=self.window.convertPoint(toScreen:NSPoint(x:360,y:90))
   let original=CGPoint(x:point.x,y:NSScreen.screens.first!.frame.maxY-point.y)
   CGWarpMouseCursorPosition(original);var frame=0,errors=[Double](),delays=[Double](),last=ProcessInfo.processInfo.systemUptime
   self.timer=Timer(timeInterval:1.0/240,repeats:true){timer in
    frame+=1;let now=ProcessInfo.processInfo.systemUptime;delays.append((now-last)*1000);last=now
    let angle=Double(frame)*2*Double.pi/240,target=CGPoint(x:original.x+10*cos(angle),y:original.y+10*sin(angle))
    if warp{CGWarpMouseCursorPosition(target)}
    let event=CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:target,mouseButton:.left)!
    if unmerged {event.flags.insert(.maskNonCoalesced)}
    event.setIntegerValueField(.mouseEventDeltaX,value:0);event.setIntegerValueField(.mouseEventDeltaY,value:0);event.post(tap:.cghidEventTap)
    let observed=CGEvent(source:nil)!.location;errors.append(hypot(observed.x-target.x,observed.y-target.y))
    if frame>=240 {timer.invalidate();CGWarpMouseCursorPosition(saved);let sorted=errors.sorted(),gap=delays.sorted();self.label.stringValue="received \(self.received)/240; "+String(format:"%@ — immediate error p95 %.2f pt; tick p95 %.2f ms",unmerged ? "Unmerged":warp ? "Direct":"Queued",sorted[Int(Double(sorted.count-1)*0.95)],gap[Int(Double(gap.count-1)*0.95)])}
   };RunLoop.main.add(self.timer!,forMode:.common)
  }
 }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular);let probe=Probe();probe.start();app.run()
