import Cocoa
import WebKit
final class Pages:NSObject,WKURLSchemeHandler {
    func webView(_ webView:WKWebView,start task:WKURLSchemeTask){
        let b=task.request.url?.lastPathComponent=="b"
        let html="<html><head><meta name='viewport' content='width=device-width'><title>Page \(b ? "B":"A")</title></head><body style='font:32px system-ui;margin:50px'><h1>Page \(b ? "B":"A")</h1><p>Native horizontal page swipe fixture.</p><a href='pockettest://pages/\(b ? "a":"b")'>Open Page \(b ? "A":"B")</a></body></html>"
        let data=Data(html.utf8);task.didReceive(URLResponse(url:task.request.url!,mimeType:"text/html",expectedContentLength:data.count,textEncodingName:"utf-8"));task.didReceive(data);task.didFinish()
    }
    func webView(_ webView:WKWebView,stop task:WKURLSchemeTask){}
}
final class TestWindow:NSWindow {
    var received=0
    override func sendEvent(_ event:NSEvent){
        if event.type == .scrollWheel {
            received+=1
            if let cg=event.cgEvent,cg.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()),let data=cg.data {
                let fields=(0...180).reduce(into:[String:Double]()){result,n in if let field=CGEventField(rawValue:UInt32(n)){let value=cg.getDoubleValueField(field);if value != 0 {result[String(n)]=value}}}
                let record:[String:Any] = ["fields":fields,"data":(data as Data).base64EncodedString(),"t":event.timestamp]
                if let encoded=try? JSONSerialization.data(withJSONObject:record),let file=try? FileHandle(forWritingTo:URL(fileURLWithPath:"/tmp/pocket-native-scroll.jsonl")){try? file.seekToEnd();try? file.write(contentsOf:encoded+Data([10]));try? file.close()}
            }
            if received<=3 || event.phase == .ended {
                let text="received=\(received) phase=\(event.phase.rawValue) dx=\(event.scrollingDeltaX)\n"
                let url=URL(fileURLWithPath:"/tmp/pocket-page-swipe-routing.log")
                if !FileManager.default.fileExists(atPath:url.path){FileManager.default.createFile(atPath:url.path,contents:nil)}
                if let f=try? FileHandle(forWritingTo:url){try? f.seekToEnd();try? f.write(contentsOf:Data(text.utf8));try? f.close()}
            }
        }
        super.sendEvent(event)
    }
}
final class Probe:NSObject,WKNavigationDelegate {
    var web:WKWebView!,label:NSTextField!,window:NSWindow!,timer:Timer?
    let pages=Pages()
    func start(){
        FileManager.default.createFile(atPath:"/tmp/pocket-native-scroll.jsonl",contents:nil)
        window=TestWindow(contentRect:NSRect(x:100,y:100,width:900,height:650),styleMask:[.titled,.closable],backing:.buffered,defer:false);window.title="PocketTrackpad native page-swipe test"
        let config=WKWebViewConfiguration();config.setURLSchemeHandler(pages,forURLScheme:"pockettest")
        web=WKWebView(frame:NSRect(x:0,y:95,width:900,height:555),configuration:config);web.navigationDelegate=self;web.allowsBackForwardNavigationGestures=true;window.contentView!.addSubview(web)
        label=NSTextField(labelWithString:"Open Page B using the link before testing");label.frame=NSRect(x:20,y:62,width:850,height:25);window.contentView!.addSubview(label)
        let old=NSButton(title:"Legacy zero-began",target:self,action:#selector(legacy));old.frame=NSRect(x:20,y:15,width:220,height:35);window.contentView!.addSubview(old)
        let fixed=NSButton(title:"Corrected page swipe",target:self,action:#selector(corrected));fixed.frame=NSRect(x:260,y:15,width:240,height:35);window.contentView!.addSubview(fixed)
        web.load(URLRequest(url:URL(string:"pockettest://pages/a")!));window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){label.stringValue="Current: \(webView.url?.lastPathComponent ?? "?"); canGoBack: \(webView.canGoBack)"}
    @objc func legacy(){run(legacy:true)}
    @objc func corrected(){run(legacy:false)}
    func run(legacy:Bool){
        DispatchQueue.main.asyncAfter(deadline:.now()+2){self.execute(legacy:legacy)}
    }
    func execute(legacy:Bool){
        guard AXIsProcessTrusted() else{label.stringValue="Input permission missing";return}
        guard web.canGoBack else{label.stringValue="Open Page B first";return}
        label.stringValue=legacy ? "Testing legacy zero-began…":"Testing directional began…"
        var stream=NativeScrollStream(),frame=0
        let point=window.convertPoint(toScreen:NSPoint(x:450,y:350));let screenHeight=NSScreen.screens.first!.frame.maxY
        let original=CGEvent(source:nil)!.location
        CGWarpMouseCursorPosition(CGPoint(x:point.x,y:screenHeight-point.y))
        func post(_ e:CGEvent?){e?.location=CGEvent(source:nil)?.location ?? CGPoint(x:point.x,y:screenHeight-point.y);e?.post(tap:.cghidEventTap)}
        if legacy {let e=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:0,wheel2:0,wheel3:0);e?.setIntegerValueField(.scrollWheelEventIsContinuous,value:1);e?.setIntegerValueField(.scrollWheelEventScrollPhase,value:1);post(e)}
        timer=Timer(timeInterval:1.0/120.0,repeats:true){[weak self] timer in
            guard let self else{timer.invalidate();return};frame+=1
            if frame<=36 {
                if legacy {let e=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:0,wheel2:4,wheel3:0);e?.setIntegerValueField(.scrollWheelEventIsContinuous,value:1);e?.setIntegerValueField(.scrollWheelEventScrollPhase,value:2);post(e)}
                else{post(stream.event(x:4,y:0,phase:frame==1 ? "began":"changed",momentum:"none"))}
            } else {post(stream.event(x:0,y:0,phase:"ended",momentum:"none"));timer.invalidate();DispatchQueue.main.asyncAfter(deadline:.now()+1){CGWarpMouseCursorPosition(original);self.label.stringValue="Replay finished — current: \(self.web.url?.lastPathComponent ?? "?")"}}
        };RunLoop.main.add(timer!,forMode:.common)
    }
}
let app=NSApplication.shared;app.setActivationPolicy(.regular);let probe=Probe();probe.start();app.run()
