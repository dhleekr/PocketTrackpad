import Cocoa

@_silgen_name("PocketCreatePanCompanion") private func PocketCreatePanCompanion(_ x:Double,_ y:Double,_ phase:Int32)->Unmanaged<CGEvent>?

// Keep the began phase until the first real pixel reaches AppKit. WebKit uses
// this event's direction to decide between scrolling content and page history.
struct NativeScrollStream {
    private var remainder=CGPoint.zero
    private var beganPending=false,momentumBeganPending=false
    private var active=false,inMomentum=false
    mutating func event(x:Double,y:Double,phase:String,momentum:String)->CGEvent? {
        guard x.isFinite,y.isFinite,abs(x)<=2000,abs(y)<=2000 else{return nil}
        if phase=="began" {remainder = .zero;beganPending=true}
        if momentum=="began" {momentumBeganPending=true}
        let totalX=x+remainder.x,totalY=y+remainder.y
        let pixelX=totalX.rounded(.towardZero),pixelY=totalY.rounded(.towardZero)
        remainder=CGPoint(x:totalX-pixelX,y:totalY-pixelY)
        let terminal=(momentum=="none" && (phase=="ended" || phase=="cancelled")) || momentum=="ended"
        guard pixelX != 0 || pixelY != 0 || terminal else{return nil}
        guard let event=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:2,wheel1:Int32(pixelY),wheel2:Int32(pixelX),wheel3:0) else{return nil}
        event.setIntegerValueField(.scrollWheelEventIsContinuous,value:1)
        let scrollPhase=beganPending && momentum=="none" && !terminal ? "began":phase
        let momentumPhase=momentumBeganPending && !terminal ? "began":momentum
        event.setIntegerValueField(.scrollWheelEventScrollPhase,value:momentum=="none" ? ["began":1,"changed":2,"ended":4,"cancelled":8][scrollPhase] ?? 2:0)
        event.setIntegerValueField(.scrollWheelEventMomentumPhase,value:["none":0,"began":1,"changed":2,"ended":3][momentumPhase] ?? 0)
        if pixelX != 0 || pixelY != 0 {if momentum=="none"{beganPending=false};if momentum != "none"{momentumBeganPending=false}}
        if terminal {beganPending=false;momentumBeganPending=false;active=false;inMomentum=false}
        else {active=true;inMomentum=momentum != "none"}
        return event
    }
    // Pixel scrolling and two-finger gesture tracking are distinct channels.
    // The companion is a pan gesture (CG type 29, subtype 6), not a keyboard
    // navigation command. Keep the undocumented fields confined to this adapter.
    static func companion(for wheel:CGEvent)->CGEvent? {
        let phase=wheel.getIntegerValueField(.scrollWheelEventScrollPhase)
        guard phase != 0,let retained=PocketCreatePanCompanion(wheel.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)*5/3,wheel.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)*5/3,Int32(phase)) else{return nil}
        let event=retained.takeRetainedValue();event.location=wheel.location;event.timestamp=wheel.timestamp
        return event
    }
    static func post(_ wheel:CGEvent,companionEnabled:Bool=true){
        wheel.post(tap:.cgSessionEventTap)
        if companionEnabled {companion(for:wheel)?.post(tap:.cgSessionEventTap)}
    }
    mutating func cancel()->CGEvent? {
        guard active else{reset();return nil}
        let result=event(x:0,y:0,phase:inMomentum ? "ended":"cancelled",momentum:inMomentum ? "ended":"none")
        reset();return result
    }
    mutating func reset(){self=NativeScrollStream()}
}
