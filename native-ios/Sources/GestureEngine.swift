import Foundation

enum PadTuning {
    static let speedRange=0.1...12.0
    static let pressRange=0.05...2.0
    static let doubleTapRange=0.1...1.0
    static func saved(_ key:String,default fallback:Double,range:ClosedRange<Double>,in store:UserDefaults = .standard)->Double {
        guard let value=store.object(forKey:key) as? Double,value.isFinite else{return fallback}
        return min(range.upperBound,max(range.lowerBound,value))
    }
    static func speedPosition(_ speed:Double)->Double {log(min(speedRange.upperBound,max(speedRange.lowerBound,speed))/speedRange.lowerBound)/log(speedRange.upperBound/speedRange.lowerBound)}
    static func speed(at position:Double)->Double {speedRange.lowerBound*pow(speedRange.upperBound/speedRange.lowerBound,min(1,max(0,position)))}
}

struct PadPoint: Equatable {
    var x: Double
    var y: Double
    var force: Double = 0 // A normalized hardware force, never contact area.
}
struct PadEvent: Codable, Equatable {
    var type: String
    var x: Double? = nil
    var y: Double? = nil
    var phase: String? = nil
    var momentum: String? = nil
    var count: Int? = nil
    var name: String? = nil
    var t: Double? = nil
    var text: String? = nil
}

enum PadHapticKind { case tap,press,release,gesture }

final class GestureEngine {
    enum Mode { case pending, scroll, pinch, drag, swipe, system }
    var emit: ([PadEvent])->Void = { _ in }
    var haptic: (PadHapticKind)->Void = { _ in }
    var surfaceWidth=0.0
    var sensitivity = 1.6
    var doubleTapInterval=0.5
    var pressDelay = 0.16
    private var secondTapCandidate=false
    private var doubleTapDragging=false
    var pressClickEnabled = true
    var hardwarePressureAvailable = false
    var naturalScroll = true
    private(set) var held = false
    private(set) var mode = Mode.pending
    private var points: [Int:PadPoint] = [:]
    private var previous = PadPoint(x:0,y:0)
    private var start = 0.0
    private var last = 0.0
    private var peakCount = 0
    private var travel = 0.0
    private var dxTotal = 0.0
    private var dyTotal = 0.0
    private var edgeCandidate=false
    private var systemAction:String?
    private var initialSpan=0.0,currentSpan=0.0
    private var initialGap = 0.0
    private var previousGap = 0.0
    private var scrollStarted = false
    private var swipeFired = false
    private var dockAxis=0,dockProgress=0.0,dockVelocity=0.0,dockLastMotion=0.0
    private var velocityX = 0.0
    private var velocityY = 0.0
    private var lastScrollTime = 0.0
    private var gainSpeed = 0.0
    private var lastTap: (time:Double,point:PadPoint)?
    private var inertia: (x:Double,y:Double,last:Double,began:Bool)?

    private func centroid(_ values:[Int:PadPoint])->PadPoint {
        let n=Double(values.count)
        return PadPoint(x:values.values.reduce(0){$0+$1.x}/n,y:values.values.reduce(0){$0+$1.y}/n)
    }
    private func gap(_ values:[Int:PadPoint])->Double {
        guard values.count==2 else { return 0 }
        let a=Array(values.values)
        return hypot(a[0].x-a[1].x,a[0].y-a[1].y)
    }
    private func nearRightEdge(_ values:[Int:PadPoint])->Bool {
        surfaceWidth>0 && values.count==2 && values.values.allSatisfy{$0.x>=surfaceWidth-min(48,max(28,surfaceWidth*0.1))}
    }
    private func span(_ values:[Int:PadPoint])->Double {
        let center=centroid(values)
        return values.values.reduce(0){$0+hypot($1.x-center.x,$1.y-center.y)}/Double(values.count)
    }
    private func finishSystem() {
        let commit=systemAction=="notifications" ? dxTotal < -48 : (initialSpan>0 && currentSpan/initialSpan<0.78)
        if commit,let action=systemAction {emit([PadEvent(type:"shortcut",name:action)]);haptic(.gesture)}
        systemAction=nil;edgeCandidate=false
    }
    private func stopInertia() {
        if inertia != nil { emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"ended")]) }
        inertia=nil
    }
    private func down() {
        guard !held else { return };held=true;mode = .drag
        emit([PadEvent(type:"down")]);haptic(.press)
    }
    private func up() {
        guard held else { return };held=false
        emit([PadEvent(type:"up")]);haptic(.release)
    }
    private func move(_ dx:Double,_ dy:Double,dt:Double) {
        guard hypot(dx,dy)>0.001 else { return }
        let speed=hypot(dx,dy)/max(0.001,dt)
        let alpha=1-exp(-max(0.001,dt)/(speed<gainSpeed ? 0.012:0.04))
        gainSpeed += (speed-gainSpeed)*alpha
        let t=min(1,max(0,(gainSpeed-35)/965))
        let gain=sensitivity*(0.3+0.8*t*t*(3-2*t))
        let x=dx*gain,y=dy*gain
        // Preserve large high-gain moves within each transport's per-event limit.
        let parts=max(1,Int(ceil(max(abs(x),abs(y))/2000)))
        emit(Array(repeating:PadEvent(type:"move",x:x/Double(parts),y:y/Double(parts)),count:parts))
    }
    private func dockEvent(_ phase:String,at now:Double) {
        guard dockAxis != 0 else{return}
        let velocity=now-dockLastMotion>0.12 ? 0:dockVelocity
        emit([PadEvent(type:"dockSwipe",x:dockProgress,y:velocity,phase:phase,name:dockAxis==1 ? "horizontal":"vertical")])
    }
    private func finishDock(cancelled:Bool,at now:Double) {
        guard dockAxis != 0 else{return}
        let cancel=cancelled || abs(dockProgress)<0.05
        dockEvent(cancel ? "cancelled":"ended",at:now)
        if !cancel,abs(dockProgress)>0.4 {haptic(.gesture)}
        dockAxis=0;dockProgress=0;dockVelocity=0
    }
    func update(_ incoming:[Int:PadPoint],at now:Double) {
        if incoming.isEmpty {
            guard !points.isEmpty else { return }
            if held {
                up()
                if !doubleTapDragging && peakCount==1 && travel<6 && now-start<0.32 {lastTap=(now,previous)}else{lastTap=nil}
            }
            else if mode == .system {finishSystem()}
            else if mode == .swipe { finishDock(cancelled:false,at:now) }
            else if mode == .pinch { emit([PadEvent(type:"magnify",x:0,phase:"ended")]) }
            else if scrollStarted {
                emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"none")])
                if now-lastScrollTime<0.09 && hypot(velocityX,velocityY)>60 {
                    inertia=(velocityX,velocityY,now,false)
                }
            } else if mode == .pending && travel<6 && now-start<0.32 {
                if peakCount==2 { emit([PadEvent(type:"right")]);haptic(.tap);lastTap=nil }
                else if peakCount==1 {
                    let double=secondTapCandidate
                    emit([PadEvent(type:"click",count:double ? 2:1)]);haptic(.tap)
                    lastTap=double ? nil:(now,previous)
                }
            }
            points=[:];scrollStarted=false;mode = .pending;return
        }
        let c=centroid(incoming)
        if points.isEmpty {
            doubleTapDragging=false
            secondTapCandidate=incoming.count==1 && (lastTap.map{now-$0.time<doubleTapInterval && hypot(c.x-$0.point.x,c.y-$0.point.y)<44} ?? false)
            if incoming.count != 1 {lastTap=nil}
            stopInertia();points=incoming;previous=c;start=now;last=now;peakCount=incoming.count
            travel=0;dxTotal=0;dyTotal=0;gainSpeed=0;scrollStarted=false;velocityX=0;velocityY=0
            edgeCandidate=nearRightEdge(incoming);systemAction=nil;initialSpan=span(incoming);currentSpan=initialSpan
            initialGap=gap(incoming);previousGap=initialGap;swipeFired=false;dockAxis=0;dockProgress=0;dockVelocity=0;mode = .pending
            return
        }
        if Set(points.keys) != Set(incoming.keys) {
            if mode == .system {points=incoming;previous=c;last=now;return}
            if mode == .swipe {points=incoming;previous=c;last=now;return}
            if mode == .pinch,incoming.count==1,points.count==2 {
                points=incoming;previous=c;last=now;return
            }
            // Real fingers lift at different times. Keep the scroll alive until the final lift.
            if scrollStarted && incoming.count==1 && peakCount==2 {
                points=incoming;previous=c;last=now;return
            }
            if scrollStarted {
                emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"none")]);scrollStarted=false
            }
            if mode == .pinch { emit([PadEvent(type:"magnify",x:0,phase:"cancelled")]) }
            peakCount=max(peakCount,incoming.count)
            // A third finger switches a held press into a system swipe without a stuck button.
            if incoming.count>=3 && held { up() }
            // Preserve swipe consumption until every finger is lifted.
            if !held { mode = swipeFired ? .swipe:.pending;dxTotal=0;dyTotal=0;initialGap=gap(incoming);previousGap=initialGap }
            edgeCandidate=nearRightEdge(incoming);initialSpan=span(incoming);currentSpan=initialSpan
            points=incoming;previous=c;last=now;return
        }
        if mode == .system && incoming.count<peakCount {points=incoming;previous=c;last=now;return}
        let dx=c.x-previous.x,dy=c.y-previous.y,dt=max(0.001,now-last)
        points=incoming;previous=c;last=now;travel+=hypot(dx,dy);dxTotal+=dx;dyTotal+=dy
        if mode == .system {
            if systemAction=="apps",incoming.count==4{currentSpan=span(incoming)}
            return
        }
        if held { move(dx,dy,dt:dt);return }
        if incoming.count==1 && peakCount==1 {
            let force=incoming.values.first!.force
            let pressure=hardwarePressureAvailable && force>=0.55
            let dwell=now-start>=max(pressDelay,secondTapCandidate ? 0.32:0) && travel<4
            if secondTapCandidate && travel>1.5 {
                doubleTapDragging=true;lastTap=nil;down();move(dx,dy,dt:dt)
            } else if pressClickEnabled && (pressure || dwell) { down();move(dx,dy,dt:dt) }
            else { move(dx,dy,dt:dt) }
        } else if incoming.count==2 && peakCount==2 {
            let spacing=gap(incoming),translation=hypot(dxTotal,dyTotal),pinch=spacing-initialGap
            if edgeCandidate && mode == .pending {
                if dxTotal < -12 && -dxTotal>abs(dyTotal)*1.4 && translation>abs(pinch) {
                    mode = .system;systemAction="notifications";lastTap=nil;return
                }
                if translation<12 && abs(pinch)<12{return}
                edgeCandidate=false
            }
            if (mode == .pending || mode == .scroll),abs(pinch)>12 && abs(pinch)>translation*1.5 {
                if scrollStarted {emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"none")]);scrollStarted=false}
                mode = .pinch;previousGap=initialGap;emit([PadEvent(type:"magnify",x:0,phase:"began")])
            } else if mode == .pending,translation>3 && translation>abs(pinch)*0.7 {mode = .scroll}
            if mode == .scroll {
                if scrollStarted && hypot(dx,dy)<=0.001 { return }
                let factor=naturalScroll ? -1.5:1.5
                let sx=(scrollStarted ? dx:dxTotal)*factor,sy=(scrollStarted ? dy:dyTotal)*factor
                emit([PadEvent(type:"scroll",x:sx,y:sy,phase:scrollStarted ? "changed":"began",momentum:"none")])
                if hypot(dx,dy)>0.001 {
                    let alpha=1-exp(-dt/0.035)
                    velocityX += (dx*factor/dt-velocityX)*alpha
                    velocityY += (dy*factor/dt-velocityY)*alpha
                    lastScrollTime=now
                }
                scrollStarted=true
            } else if mode == .pinch {
                if spacing>1 && initialGap>1 {
                    let delta=(spacing-previousGap)/initialGap
                    if abs(delta)>0.00001 {
                        let parts=max(1,Int(ceil(abs(delta))))
                        emit(Array(repeating:PadEvent(type:"magnify",x:delta/Double(parts),phase:"changed"),count:parts))
                    }
                }
            }
            previousGap=spacing
        } else if incoming.count>=3 {
            if incoming.count==4 && mode == .pending {
                currentSpan=span(incoming)
                let contraction=initialSpan-currentSpan
                if initialSpan>=24 && contraction>14 && currentSpan/initialSpan<0.85 && contraction>hypot(dxTotal,dyTotal)*0.8 {
                    mode = .system;systemAction="apps";lastTap=nil;return
                }
            }
            let ax=abs(dxTotal),ay=abs(dyTotal)
            if dockAxis==0 {
                if ay>12 && ay>ax*1.25 {dockAxis=2}
                else if ax>12 && ax>ay*1.25 {dockAxis=1}
                else{return}
                mode = .swipe;swipeFired=true;lastTap=nil;dockProgress=0;dockVelocity=0
                dockEvent("began",at:now)
            }
            let progress=min(2,max(-2,dockAxis==1 ? -dxTotal/230:-dyTotal/180))
            let delta=progress-dockProgress
            if abs(delta)>0.00001 {
                dockVelocity=min(10,max(-10,delta/dt));dockProgress=progress;dockLastMotion=now
                dockEvent("changed",at:now)
            }
        }
    }
    func tick(at now:Double) {
        if !points.isEmpty {
            // Press timers must not overwrite the timestamp of the last real motion.
            let sampleTime=last;update(points,at:now);last=sampleTime
        }
        guard var value=inertia,points.isEmpty else { return }
        let dt=max(0.001,min(0.032,now-value.last)),decay=exp(-dt/0.36)
        value.x*=decay;value.y*=decay;value.last=now
        if hypot(value.x,value.y)<15 { stopInertia();return }
        emit([PadEvent(type:"scroll",x:value.x*dt,y:value.y*dt,phase:"ended",momentum:value.began ? "changed":"began")])
        value.began=true;inertia=value
    }
    func cancel() {
        systemAction=nil;edgeCandidate=false
        finishDock(cancelled:true,at:last)
        if mode == .pinch { emit([PadEvent(type:"magnify",x:0,phase:"cancelled")]) }
        if scrollStarted { emit([PadEvent(type:"scroll",x:0,y:0,phase:"cancelled",momentum:"none")]) }
        stopInertia();up();points=[:];scrollStarted=false;mode = .pending;lastTap=nil;secondTapCandidate=false
    }
}


struct PadTouchSample {
    var id:Int
    var time:Double
    var point:PadPoint
}
struct PadTouchFrame {
    var time:Double
    var points:[Int:PadPoint]
}
struct PadTouchFrameAssembler {
    private var points=[Int:PadPoint]()
    private var lastTime = -Double.infinity
    mutating func reset(_ points:[Int:PadPoint],at time:Double){self.points=points;lastTime=time}
    mutating func consume(_ samples:[PadTouchSample])->[PadTouchFrame]{
        let ordered=samples.filter{$0.time.isFinite && $0.time>lastTime && points[$0.id] != nil}.sorted{$0.time<$1.time}
        var frames=[PadTouchFrame](),index=0
        while index<ordered.count {
            let time=ordered[index].time
            repeat {let sample=ordered[index];points[sample.id]=sample.point;index+=1}while index<ordered.count && ordered[index].time==time
            frames.append(PadTouchFrame(time:time,points:points));lastTime=time
        }
        return frames
    }
}
