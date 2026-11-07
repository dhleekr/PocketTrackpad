import Foundation
import CoreGraphics

/// A renewable lease prevents a lost release or disconnected phone from deleting forever.
struct KeyRepeatState {
    private(set) var key:PadQuickKey?
    private var next=0.0,pulse=0.0
    var delay=PadKeyRepeatTuning.defaultDelay,interval=1.0/60.0,backspaceRate=PadKeyRepeatTuning.defaultRate
    mutating func begin(_ key:PadQuickKey,at now:Double)->Bool {
        guard key.repeatable,now.isFinite else{return false}
        self.key=key;pulse=now;next=now+delay;return true
    }
    mutating func heartbeat(_ key:PadQuickKey,at now:Double){if self.key==key,now.isFinite{pulse=now}}
    mutating func end(_ key:PadQuickKey?=nil){if key==nil || self.key==key{self.key=nil}}
    mutating func tick(at now:Double)->PadQuickKey? {
        guard let key else{return nil}
        guard now-pulse<0.5 else{self.key=nil;return nil}
        guard now+1e-9>=next else{return nil}
        // Keep the keyboard cadence despite timer jitter, skipping missed repeats.
        let cadence=key == .backspace ? 1.0/backspaceRate:interval
        let skipped=floor(max(0,now-next)/cadence)+1
        next+=skipped*cadence
        return key
    }
}

final class MacKeyRepeater {
    private let queue=DispatchQueue(label:"PocketTrackpad.key-repeat",qos:.userInteractive)
    private var state=KeyRepeatState()
    private var timer:DispatchSourceTimer?
    private var activity:NSObjectProtocol?
    private var activeKey:PadQuickKey?
    private let deliver:(PadQuickKey,HeldKeyPhase)->Void
    private var traceEnabled=false,traceStart=0.0,traceNext=0.0,traceHeartbeats=0,traceRepeats=0
    private static let traceQueue=DispatchQueue(label:"PocketTrackpad.key-repeat.trace",qos:.utility)
    convenience init(){
        let source=CGEventSource(stateID:.privateState)
        self.init(deliver:{key,phase in
            for event in MacQuickKeys.heldEvents(for:key,phase:phase,source:source){event.post(tap:.cghidEventTap)}
        })
    }
    init(deliver:@escaping(PadQuickKey,HeldKeyPhase)->Void){self.deliver=deliver}
    private func trace(_ reason:String=""){
        guard traceEnabled else{return}
        let now=ProcessInfo.processInfo.systemUptime
        guard now>=traceNext || !reason.isEmpty else{return};traceNext=now+0.5
        let snapshot:[String:Any]=["elapsed_ms":(now-traceStart)*1000,"heartbeats":traceHeartbeats,"repeats":traceRepeats,"stop_reason":reason]
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpad-key-repeat.json")
        Self.traceQueue.async{if let data=try? JSONSerialization.data(withJSONObject:snapshot,options:.sortedKeys){try? data.write(to:url,options:.atomic)}}
    }
    func handle(_ key:PadQuickKey,phase:String,repeatDelay:Double?=nil,repeatRate:Double?=nil){queue.sync {
        let now=ProcessInfo.processInfo.systemUptime
        if phase=="began" {
            stopLocked(reason:"replaced")
            state.delay=PadKeyRepeatTuning.delay(repeatDelay);state.backspaceRate=PadKeyRepeatTuning.rate(repeatRate)
            guard state.begin(key,at:now) else{return}
            activity=ProcessInfo.processInfo.beginActivity(options:[.userInitiatedAllowingIdleSystemSleep,.latencyCritical],reason:"Respond to a held remote keyboard key")
            activeKey=key
            traceEnabled=FileManager.default.fileExists(atPath:FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpad-key-repeat-diagnostics.enabled").path)
            traceStart=now;traceNext=now;traceHeartbeats=0;traceRepeats=0
            deliver(key,.began);trace()
            let timer=DispatchSource.makeTimerSource(flags:.strict,queue:queue)
            timer.schedule(deadline:.now()+0.004,repeating:0.004,leeway:.nanoseconds(0))
            timer.setEventHandler{[weak self] in
                guard let self else{return}
                if let key=self.state.tick(at:ProcessInfo.processInfo.systemUptime){self.deliver(key,.repeated);self.traceRepeats+=1;self.trace()}
                if self.state.key==nil{self.stopLocked(reason:"lease-expired")}
            }
            self.timer=timer;timer.resume()
        }else if phase=="changed"{state.heartbeat(key,at:now);traceHeartbeats+=1;trace()}
        else{state.end(key);if state.key==nil{stopLocked(reason:phase)}}
    }}
    func stop(){queue.sync{stopLocked(reason:"input-release")}}
    private func stopLocked(reason:String){
        if let activeKey{deliver(activeKey,.ended);self.activeKey=nil;trace(reason);traceEnabled=false}
        state.end();timer?.cancel();timer=nil
        if let activity{ProcessInfo.processInfo.endActivity(activity);self.activity=nil}
    }
    deinit{timer?.cancel();if let activeKey{deliver(activeKey,.ended)};if let activity{ProcessInfo.processInfo.endActivity(activity)}}
}
