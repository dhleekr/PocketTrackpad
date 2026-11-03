import Cocoa
import ApplicationServices

/// System UI stays with macOS; no fixed screen coordinate or user hotkey is assumed.
enum MacSystemActions {
    static func perform(_ name:String) {
        DispatchQueue.main.async {
            if name=="apps" {
                let candidates=["/System/Applications/Apps.app","/System/Applications/Launchpad.app"]
                guard let path=candidates.first(where:{FileManager.default.fileExists(atPath:$0)}) else{NSSound.beep();return}
                NSWorkspace.shared.open(URL(fileURLWithPath:path))
            } else if name=="notifications" {
                guard pressClock() else{NSSound.beep();return}
            }
        }
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
                        return AXUIElementPerformAction(node,kAXPressAction as CFString) == .success
                    }
                    next+=children(node,kAXChildrenAttribute)
                }
                nodes=next
            }
        }
        return false
    }
}
