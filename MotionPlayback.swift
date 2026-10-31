import Foundation
import CoreVideo

struct MotionValue:Equatable {var x:Double=0;var y:Double=0}

// Interpolate recorded positions only. Never predict beyond the newest input.
struct MotionTimeline {
    private struct Point {var time:Double;var value:MotionValue}
    private var points=[Point]()
    private var offset:Double?
    private var lastSource:Double?
    private var lastArrival:Double?
    private(set) var output=MotionValue()
    var delay=1.0/60.0
    var bufferedCount:Int {points.count}
    mutating func append(x:Double,y:Double,sourceTime:Double?,arrival:Double) {
        guard x.isFinite,y.isFinite,arrival.isFinite else{return}
        let source=sourceTime.flatMap{$0.isFinite && $0>=0 ? $0:nil}
        if let previous=lastArrival,arrival-previous>0.08 {
            points=[];offset=nil;lastSource=nil
        }
        var time=arrival
        if let source {
            if let lastSource,(source<lastSource-0.1 || source-lastSource>0.25) {points=[];offset=nil}
            let candidate=arrival-source
            if let old=offset {
                if candidate<old {
                    let shift=candidate-old
                    for i in points.indices {points[i].time += shift}
                    offset=candidate
                }
            } else {offset=candidate}
            time=source+(offset ?? candidate)
            // A growing transport backlog moves new source samples behind the
            // playhead. Re-anchor from the last delivered position instead of
            // reducing output to one jump per late packet. Never extrapolate.
            if time<arrival-delay {
                offset=candidate;time=arrival
                points=[Point(time:arrival-delay,value:output)]
            }
            lastSource=source
        }
        if points.isEmpty {points.append(Point(time:time-delay,value:output))}
        let value=MotionValue(x:x,y:y)
        if let last=points.last,time<=last.time {points[points.count-1]=Point(time:last.time,value:value)}
        else {points.append(Point(time:time,value:value))}
        if points.count>64 {points.removeFirst(points.count-64)}
        lastArrival=arrival
    }
    mutating func sample(at now:Double)->MotionValue {
        let time=now-delay
        while points.count>1,points[1].time<=time {points.removeFirst()}
        guard let first=points.first else{return output}
        if points.count>1 {
            let second=points[1]
            let t=min(1,max(0,(time-first.time)/max(0.000001,second.time-first.time)))
            output=MotionValue(x:first.value.x+(second.value.x-first.value.x)*t,y:first.value.y+(second.value.y-first.value.y)*t)
        } else {output=first.value}
        return output
    }
    mutating func finish()->MotionValue {
        if let last=points.last {output=last.value}
        points=[];offset=nil;lastSource=nil;lastArrival=nil;return output
    }
}

// Small aggregate timing counters; no positions, pairing keys or text are recorded.
struct InputCadence {
    private var previous:Double?
    private var gaps=[Double]()
    private(set) var count=0
    mutating func record(_ time:Double) {
        if let previous {let gap=time-previous;if gap>=0 && gap<0.25 {gaps.append(gap*1000);if gaps.count>512{gaps.removeFirst()}}}
        previous=time;count+=1
    }
    var intervalsMS:[Double] {gaps}
    var summary:[String:Double] {
        let values=gaps.sorted()
        func percentile(_ p:Double)->Double {values.isEmpty ? 0:values[min(values.count-1,Int(Double(values.count-1)*p))]}
        return ["samples":Double(count),"p50_ms":percentile(0.5),"p95_ms":percentile(0.95),"max_ms":values.last ?? 0]
    }
}

final class MotionPlayback {
    private var timeline=MotionTimeline()
    private var delay=1.0/60.0
    func setDelay(_ value:Double,apply:([String:Any])->Void){
        guard value.isFinite,abs(value-delay)>0.000001 else{return}
        flush(apply:apply);delay=min(0.05,max(1.0/240.0,value));timeline.delay=delay
    }
    private var template=[String:Any]()
    private var key=""
    private var target=MotionValue(),emitted=MotionValue()
    private var absolute=false
    private var pendingBegin=false,pendingMomentumBegin=false
    var active:Bool {!key.isEmpty}
    static func isContinuous(_ event:[String:Any])->Bool {
        let type=event["type"] as? String ?? "",phase=event["phase"] as? String ?? "changed"
        let momentum=event["momentum"] as? String ?? "none"
        return type=="move" || (["scroll","magnify","dockSwipe"].contains(type) && phase=="changed") || (type=="scroll" && phase=="ended" && momentum=="changed")
    }
    // Returns false for a boundary after draining motion, so the caller can
    // apply the click/release/terminal phase immediately and in order.
    func accept(_ event:[String:Any],at now:Double,apply:([String:Any])->Void)->Bool {
        if Self.isContinuous(event){enqueue(event,at:now,apply:apply);return true}
        let type=event["type"] as? String ?? "",phase=event["phase"] as? String ?? "changed"
        let momentum=event["momentum"] as? String ?? "none"
        if type != "status" || event["name"] as? String=="motionEnd" {flush(apply:apply)}
        if type=="scroll" && (phase=="began" || momentum=="began") {
            enqueue(event,at:now,apply:apply)
            pendingBegin=phase=="began";pendingMomentumBegin=momentum=="began"
            return true
        }
        return false
    }
    func enqueue(_ event:[String:Any],at now:Double,apply:([String:Any])->Void) {
        let type=event["type"] as? String ?? ""
        let momentum=event["momentum"] as? String ?? "none"
        let nextKey=type+":"+(event["name"] as? String ?? "")+":"+(momentum=="none" ? "none":"inertia")
        if active && key != nextKey {flush(apply:apply)}
        if !active {timeline.delay=delay;key=nextKey;absolute=type=="dockSwipe";target=MotionValue();emitted=MotionValue();pendingBegin=false;pendingMomentumBegin=false}
        template=event
        let x=event["x"] as? Double ?? 0,y=event["y"] as? Double ?? 0
        if absolute {target=MotionValue(x:x,y:y)}else{target.x+=x;target.y+=y}
        timeline.append(x:target.x,y:target.y,sourceTime:event["t"] as? Double,arrival:now)
    }
    func frame(at now:Double,apply:([String:Any])->Void) {
        guard active else{return};deliver(timeline.sample(at:now),apply:apply)
    }
    private func deliver(_ value:MotionValue,apply:([String:Any])->Void) {
        guard abs(value.x-emitted.x)>1e-10 || (!absolute && abs(value.y-emitted.y)>1e-10) else{return}
        var event=template;event["x"]=absolute ? value.x:value.x-emitted.x;event["y"]=absolute ? value.y:value.y-emitted.y
        if event["type"] as? String=="scroll" {
            if pendingBegin {event["phase"]="began";pendingBegin=false}
            else if event["phase"] as? String=="began" {event["phase"]="changed"}
            if pendingMomentumBegin {event["momentum"]="began";pendingMomentumBegin=false}
            else if event["momentum"] as? String=="began" {event["momentum"]="changed"}
        }
        emitted=value;apply(event)
    }
    func flush(apply:([String:Any])->Void) {
        guard active else{return};deliver(timeline.finish(),apply:apply)
        timeline=MotionTimeline();key="";template=[:];target=MotionValue();emitted=MotionValue();pendingBegin=false;pendingMomentumBegin=false
    }
    func discard(){timeline=MotionTimeline();key="";template=[:];target=MotionValue();emitted=MotionValue();pendingBegin=false;pendingMomentumBegin=false}
}

final class MotionDisplayClock {
    private var link:CVDisplayLink?
    private let callback:()->Void
    init(_ callback:@escaping ()->Void){self.callback=callback}
    func start()->Bool {
        var value:CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&value)==kCVReturnSuccess,let value else{return false}
        link=value
        CVDisplayLinkSetOutputCallback(value,{_,_,_,_,_,context in
            guard let context else{return kCVReturnSuccess}
            Unmanaged<MotionDisplayClock>.fromOpaque(context).takeUnretainedValue().callback()
            return kCVReturnSuccess
        },Unmanaged.passUnretained(self).toOpaque())
        return CVDisplayLinkStart(value)==kCVReturnSuccess
    }
    deinit {if let link{CVDisplayLinkStop(link)}}
}
