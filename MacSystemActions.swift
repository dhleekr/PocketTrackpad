import Cocoa
import ApplicationServices

@_silgen_name("PocketPostNotification") private func PocketPostNotification(_ progress:Double,_ delta:Double,_ velocity:Double,_ phase:Int32)->Bool

/// System UI stays with macOS; no fixed screen coordinate or user hotkey is assumed.
enum MacSystemActions {
    static func perform(_ name:String) {
        DispatchQueue.main.async {
            if name=="apps" {
                let candidates=["/System/Applications/Apps.app","/System/Applications/Launchpad.app"]
                guard let path=candidates.first(where:{FileManager.default.fileExists(atPath:$0)}) else{NSSound.beep();return}
                NSWorkspace.shared.open(URL(fileURLWithPath:path))
            } else if name=="notifications" {
                if #available(macOS 27.0,*){animateNotification()}else{guard pressClock() else{NSSound.beep();return}}
            }
        }
    }
    #if POCKET_LOCAL_TEST
    static func testCloseNotification(){animateNotification(closing:true)}
    #endif
    private static func animateNotification(closing:Bool=false){
        let direction=closing ? -1.0:1.0
        guard PocketPostNotification(direction*0.02,direction*0.02,0,1) else{NSSound.beep();return}
        var step=0,previous=direction*0.02
        let timer=Timer(timeInterval:1.0/60,repeats:true){timer in
            step+=1;let progress=direction*min(1,Double(step)/16)
            _ = PocketPostNotification(progress,progress-previous,0,2);previous=progress
            if step>=16{_ = PocketPostNotification(progress,0,direction*5,4);timer.invalidate()}
        }
        RunLoop.main.add(timer,forMode:.common)
    }
    private static func children(_ element:AXUIElement,_ attribute:String)->[AXUIElement] {
        var value:CFTypeRef?
        guard AXUIElementCopyAttributeValue(element,attribute as CFString,&value) == .success else{return []}
        if let array=value as? [AXUIElement]{return array}
        if let value,CFGetTypeID(value)==AXUIElementGetTypeID(){return [unsafeBitCast(value,to:AXUIElement.self)]}
        return []
    }
    private static func pressClock()->Bool {
        for bundle in ["com.apple.controlcenter","com.apple.systemuiserver"] {
            guard let app=NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else{continue}
            let root=AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(root,0.5)
            var nodes=children(root,kAXMenuBarAttribute)+children(root,"AXExtrasMenuBar")
            for _ in 0..<4 {
                var next=[AXUIElement]()
                for node in nodes.prefix(100) {
                    var value:CFTypeRef?
                    _ = AXUIElementCopyAttributeValue(node,kAXIdentifierAttribute as CFString,&value)
                    if let id=value as? String,["com.apple.menuextra.clock","com.apple.controlcenter.Clock","Clock"].contains(id) {
                        if AXUIElementPerformAction(node,kAXPressAction as CFString) == .success{return true}
                    }
                    next+=children(node,kAXChildrenAttribute)
                }
                nodes=next
            }
        }
        return false
    }
}
