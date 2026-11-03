import CoreGraphics

/// Emit balanced modifier transitions; the next physical or remote key remains unmodified.
enum MacQuickKeys {
    static func events(for key:PadQuickKey)->[CGEvent] {
        let source=CGEventSource(stateID:.privateState)
        var events=[CGEvent](),flags=CGEventFlags()
        let modifiers:[(Bool,CGKeyCode,CGEventFlags)]=[(key.command,55,.maskCommand),(key.control,59,.maskControl),(key.shift,56,.maskShift)]
        for (enabled,code,flag) in modifiers where enabled {
            flags.insert(flag)
            if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true){event.type = .flagsChanged;event.flags=flags;events.append(event)}
        }
        for down in [true,false] {
            if let event=CGEvent(keyboardEventSource:source,virtualKey:key.keyCode,keyDown:down){event.flags=flags;events.append(event)}
        }
        for (enabled,code,flag) in modifiers.reversed() where enabled {
            flags.remove(flag)
            if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false){event.type = .flagsChanged;event.flags=flags;events.append(event)}
        }
        return events
    }
}
