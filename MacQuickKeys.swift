import CoreGraphics

/// Construct the same key sequence used by the receiver; tests inspect without posting it.
enum MacQuickKeys {
    static func events(for key:PadQuickKey)->[CGEvent] {
        let source=CGEventSource(stateID:.privateState)
        var events=[CGEvent]()
        if key.shift,let modifier=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:true){
            modifier.type = .flagsChanged;modifier.flags = .maskShift;events.append(modifier)
        }
        for down in [true,false] {
            if let event=CGEvent(keyboardEventSource:source,virtualKey:key.keyCode,keyDown:down){
                event.flags=key.shift ? .maskShift:[];events.append(event)
            }
        }
        if key.shift,let modifier=CGEvent(keyboardEventSource:source,virtualKey:56,keyDown:false){
            modifier.type = .flagsChanged;modifier.flags=[];events.append(modifier)
        }
        return events
    }
}
