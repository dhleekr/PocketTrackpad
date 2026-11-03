import Foundation
import CoreGraphics

/// A renewable lease prevents a lost release or disconnected phone from deleting forever.
struct KeyRepeatState {
    private(set) var key:PadQuickKey?
    private var next=0.0,pulse=0.0,began=0.0
    var delay=0.4,interval=0.06
    mutating func begin(_ key:PadQuickKey,at now:Double)->Bool {
        guard key.repeatable,now.isFinite else{return false}
        self.key=key;pulse=now;began=now;next=now+(key == .backspace ? min(delay,0.28):delay);return true
    }
    mutating func heartbeat(_ key:PadQuickKey,at now:Double){if self.key==key,now.isFinite{pulse=now}}
    mutating func end(_ key:PadQuickKey?=nil){if key==nil || self.key==key{self.key=nil}}
    mutating func tick(at now:Double)->PadQuickKey? {
        guard let key else{return nil}
        guard now-pulse<0.5 else{self.key=nil;return nil}
        guard now>=next else{return nil}
        let held=now-began
        let cadence=key == .backspace ? (held>=1.8 ? 0.016:held>=0.8 ? 0.028:0.05):interval
        next=now+cadence // Never replay a burst after a delayed timer.
        return key
    }
}

final class MacKeyRepeater {
    private let queue=DispatchQueue(label:"PocketTrackpad.key-repeat")
    private var state=KeyRepeatState()
    private var timer:DispatchSourceTimer?
    init(){
        let defaults=UserDefaults.standard
        if let ticks=defaults.object(forKey:"InitialKeyRepeat") as? Double{state.delay=min(1.5,max(0.15,ticks/60))}
        if let ticks=defaults.object(forKey:"KeyRepeat") as? Double{state.interval=min(0.2,max(1.0/60,ticks/60))}
    }
    func handle(_ key:PadQuickKey,phase:String){queue.sync {
        let now=ProcessInfo.processInfo.systemUptime
        if phase=="began" {
            stopLocked()
            guard state.begin(key,at:now) else{return}
            post(key,repeating:false)
            let timer=DispatchSource.makeTimerSource(queue:queue)
            timer.schedule(deadline:.now()+0.008,repeating:0.008)
            timer.setEventHandler{[weak self] in
                guard let self else{return}
                if let key=self.state.tick(at:ProcessInfo.processInfo.systemUptime){self.post(key,repeating:true)}
                if self.state.key==nil{self.stopLocked()}
            }
            self.timer=timer;timer.resume()
        }else if phase=="changed"{state.heartbeat(key,at:now)}
        else{state.end(key);if state.key==nil{stopLocked()}}
    }}
    private func post(_ key:PadQuickKey,repeating:Bool){
        for event in MacQuickKeys.events(for:key){
            if repeating,event.type == .keyDown{event.setIntegerValueField(.keyboardEventAutorepeat,value:1)}
            event.post(tap:.cghidEventTap)
        }
    }
    func stop(){queue.sync{stopLocked()}}
    private func stopLocked(){state.end();timer?.cancel();timer=nil}
    deinit{timer?.cancel()}
}
