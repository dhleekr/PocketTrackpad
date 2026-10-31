import Cocoa
import WebKit
final class Pages:NSObject,WKURLSchemeHandler {
 func webView(_ webView:WKWebView,start task:WKURLSchemeTask){let b=task.request.url!.lastPathComponent=="b";let text="<html><head><title>Page \(b ? "B":"A")</title></head><body style='font:32px system-ui;margin:50px'><h1>Page \(b ? "B":"A")</h1><p>Native page-history comparison</p><a href='pockettest://pages/\(b ? "a":"b")'>Open Page \(b ? "A":"B")</a></body></html>";let d=Data(text.utf8);task.didReceive(URLResponse(url:task.request.url!,mimeType:"text/html",expectedContentLength:d.count,textEncodingName:"utf-8"));task.didReceive(d);task.didFinish()}
 func webView(_ webView:WKWebView,stop task:WKURLSchemeTask){}
}
final class Probe:NSObject,WKNavigationDelegate {
 var window:NSWindow!,web:WKWebView!,label:NSTextField!,timer:Timer?,monitor:Any?,received=0
 let pages=Pages()
 func start(){
  window=NSWindow(contentRect:NSRect(x:100,y:100,width:900,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="PocketTrackpad page-channel comparison"
  let c=WKWebViewConfiguration();c.setURLSchemeHandler(pages,forURLScheme:"pockettest")
  web=WKWebView(frame:NSRect(x:0,y:95,width:900,height:555),configuration:c);web.navigationDelegate=self;web.allowsBackForwardNavigationGestures=true;window.contentView!.addSubview(web)
  label=NSTextField(labelWithString:"Open Page B first");label.frame=NSRect(x:20,y:62,width:850,height:25);window.contentView!.addSubview(label)
  for (i,title) in ["Wheel only","Wheel + pan","System wheel + pan"].enumerated(){let b=NSButton(title:title,target:self,action:i==0 ? #selector(old):i==1 ? #selector(fixed):#selector(system));b.frame=NSRect(x:20+i*280,y:15,width:260,height:35);window.contentView!.addSubview(b)}
  monitor=NSEvent.addLocalMonitorForEvents(matching:NSEvent.EventTypeMask(rawValue:(1<<22)|(1<<29))){[weak self] e in if let self,e.windowNumber==self.window.windowNumber{self.received+=1};return e}
  web.load(URLRequest(url:URL(string:"pockettest://pages/a")!));window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
 }
 func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){label.stringValue="Current: \(web.url!.lastPathComponent); canGoBack: \(web.canGoBack)"}
 @objc func old(){run(companion:false,system:false)}
 @objc func fixed(){run(companion:true,system:false)}
 @objc func system(){run(companion:true,system:true)}
 func run(companion:Bool,system:Bool){
  guard web.canGoBack else{label.stringValue="Open Page B first";return}
  guard NSWorkspace.shared.frontmostApplication?.processIdentifier==getpid() else {label.stringValue="Test window is not frontmost";return}
  received=0;var frame=0,stream=NativeScrollStream()
  label.stringValue="Testing…"
  func post(_ event:CGEvent){
   let p=window.convertPoint(toScreen:NSPoint(x:450,y:350));event.location=CGPoint(x:p.x,y:NSScreen.screens.first!.frame.maxY-p.y)
   event.setIntegerValueField(CGEventField(rawValue:51)!,value:Int64(window.windowNumber))
   if system{event.postToPid(getpid())}else if let e=NSEvent(cgEvent:event){NSApp.postEvent(e,atStart:false)}
  }
  timer=Timer(timeInterval:1.0/120,repeats:true){[weak self] timer in
   guard let self else{timer.invalidate();return};frame+=1
   let terminal=frame>36
   if let e=stream.event(x:terminal ? 0:4,y:0,phase:terminal ? "ended":frame==1 ? "began":"changed",momentum:"none") {post(e);if companion,let pan=NativeScrollStream.companion(for:e){post(pan)}}
   if terminal{timer.invalidate();DispatchQueue.main.asyncAfter(deadline:.now()+0.75){self.label.stringValue="Done: \(self.web.url!.lastPathComponent); delivered: \(self.received)"}}
  };RunLoop.main.add(timer!,forMode:.common)
 }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular);let probe=Probe();probe.start();app.run()
