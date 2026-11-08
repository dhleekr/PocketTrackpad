import CoreGraphics

/// Emit balanced modifier transitions; the next physical or remote key remains unmodified.
enum MacQuickKeys {
    static func events(for key:PadQuickKey)->[CGEvent] {
        guard let keyCode=key.keyCode else{return []}
        let source=CGEventSource(stateID:.privateState)
        var events=[CGEvent](),flags=CGEventFlags()
        let modifiers:[(Bool,CGKeyCode,CGEventFlags)]=[(key.command,55,.maskCommand),(key.control,59,.maskControl),(key.shift,56,.maskShift)]
        for (enabled,code,flag) in modifiers where enabled {
            flags.insert(flag)
            if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true){event.type = .flagsChanged;event.flags=flags;events.append(event)}
        }
        for down in [true,false] {
            if let event=CGEvent(keyboardEventSource:source,virtualKey:keyCode,keyDown:down){event.flags=flags;events.append(event)}
        }
        for (enabled,code,flag) in modifiers.reversed() where enabled {
            flags.remove(flag)
            if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false){event.type = .flagsChanged;event.flags=flags;events.append(event)}
        }
        return events
    }
}

/// A held key has one down/up boundary; repetitions do not release it.
enum HeldKeyPhase {case began,repeated,ended}
extension MacQuickKeys {
    static func heldEvents(for key:PadQuickKey,phase:HeldKeyPhase,source:CGEventSource?)->[CGEvent] {
        guard let keyCode=key.keyCode else{return []}
        var flags=CGEventFlags(),events=[CGEvent]()
        let modifiers:[(Bool,CGKeyCode,CGEventFlags)]=[(key.command,55,.maskCommand),(key.control,59,.maskControl),(key.shift,56,.maskShift)]
        if phase == .began {
            for (enabled,code,flag) in modifiers where enabled {
                flags.insert(flag)
                if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:true){event.type = .flagsChanged;event.flags=flags;events.append(event)}
            }
        }else{for (enabled,_,flag) in modifiers where enabled{flags.insert(flag)}}
        if let event=CGEvent(keyboardEventSource:source,virtualKey:keyCode,keyDown:phase != .ended){
            event.flags=flags;event.setIntegerValueField(.keyboardEventAutorepeat,value:phase == .repeated ? 1:0);events.append(event)
        }
        if phase == .ended {
            for (enabled,code,flag) in modifiers.reversed() where enabled {
                flags.remove(flag)
                if let event=CGEvent(keyboardEventSource:source,virtualKey:code,keyDown:false){event.type = .flagsChanged;event.flags=flags;events.append(event)}
            }
        }
        return events
    }
}
