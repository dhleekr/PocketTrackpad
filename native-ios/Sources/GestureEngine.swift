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
    enum Mode { case pending, scroll, pinch, rotate, drag, swipe, scale, edge, system }
    var emit: ([PadEvent])->Void = { _ in }
    var haptic: (PadHapticKind)->Void = { _ in }
    var continuousScaleEnabled=false
    var surfaceWidth=0.0
    var surfaceHeight=0.0
    var rightEdgeInset=0.0
    var gestures=PadGesturePreferences()
    private var initialAngle=0.0,previousAngle=0.0
    private var pendingSecondary:(time:Double,point:PadPoint)?
    private var scrollName:String?{gestures.enabled(.pageSwipe) ? nil:"contentOnly"}
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
    private var notificationOpen=false,notificationClosing=false
    private enum VerticalOverlay {case none,mission,expose}
    private var verticalOverlay=VerticalOverlay.none
    private var overlayFingers=0
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
        guard gestures.enabled(.notifications),surfaceWidth>0,values.count==2 else{return false}
        let edge=surfaceWidth-max(0,rightEdgeInset),xs=values.values.map(\.x)
        // One finger leads at the edge; the other may sit a normal finger-width inside.
        return xs.max()!>=edge-min(88,max(48,surfaceWidth*0.15)) && xs.min()!>=edge-min(210,max(120,surfaceWidth*0.48))
    }
    private func angle(_ values:[Int:PadPoint])->Double {
        let keys=values.keys.sorted();guard keys.count==2 else{return 0}
        let a=values[keys[0]]!,b=values[keys[1]]!;return atan2(b.y-a.y,b.x-a.x)
    }
    private func angleDifference(_ a:Double,_ b:Double)->Double{atan2(sin(a-b),cos(a-b))}
    private func flushSecondary(){
        if pendingSecondary != nil,gestures.secondaryClick == .twoFingers{emit([PadEvent(type:"right")]);haptic(.tap)}
        pendingSecondary=nil
    }
    private func finishTap(at now:Double){
        if peakCount==2 {
            if gestures.enabled(.smartZoom){
                if let pending=pendingSecondary,now-pending.time<=doubleTapInterval,hypot(previous.x-pending.point.x,previous.y-pending.point.y)<44 {
                    pendingSecondary=nil;emit([PadEvent(type:"smartZoom")]);haptic(.gesture)
                }else{flushSecondary();pendingSecondary=(now,previous)}
            }else if gestures.secondaryClick == .twoFingers{emit([PadEvent(type:"right")]);haptic(.tap)}
            lastTap=nil
        }else if peakCount==3 {
            flushSecondary();if gestures.enabled(.lookup){emit([PadEvent(type:"shortcut",name:"lookup")]);haptic(.gesture)}
        }else if peakCount==1 {
            flushSecondary()
            let corner=surfaceHeight>0 && previous.y>=surfaceHeight-72 && ((gestures.secondaryClick == .bottomRight && previous.x>=surfaceWidth-72) || (gestures.secondaryClick == .bottomLeft && previous.x<=72))
            if corner{emit([PadEvent(type:"right")]);haptic(.tap);lastTap=nil}
            else if gestures.enabled(.tapToClick){let double=secondTapCandidate;emit([PadEvent(type:"click",count:double ? 2:1)]);haptic(.tap);lastTap=double ? nil:(now,previous)}
        }
    }
    private func span(_ values:[Int:PadPoint])->Double {
        let center=centroid(values)
        return values.values.reduce(0){$0+hypot($1.x-center.x,$1.y-center.y)}/Double(values.count)
    }
    private func finishSystem() {
        let commit=systemAction=="notifications" ? dxTotal < -40 : systemAction=="showDesktop" ? (initialSpan>0 && currentSpan-initialSpan>=max(8,initialSpan*0.14)):(initialSpan>0 && initialSpan-currentSpan>=max(8,initialSpan*0.14))
        if commit,let action=systemAction {emit([PadEvent(type:"shortcut",name:action)]);haptic(.gesture)}
        systemAction=nil;edgeCandidate=false
    }
    private func stopInertia() {
        if inertia != nil { emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"ended",name:scrollName)]) }
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
        emit([PadEvent(type:"dockSwipe",x:dockProgress,y:velocity,phase:phase,name:dockAxis==1 ? "horizontal":dockAxis==3 ? "scale":dockAxis==9 ? "notification":"vertical")])
    }
    private func finishDock(cancelled:Bool,at now:Double) {
        guard dockAxis != 0 else{return}
        let velocity=now-dockLastMotion>0.12 ? 0:dockVelocity
        let unfinishedScale=dockAxis==3 && abs(dockProgress)<0.5 && !(abs(dockProgress)>0.2 && dockProgress*velocity>0 && abs(velocity)>4)
        let unfinishedEdge=dockAxis==9 && abs(dockProgress)<0.22
        let cancel=cancelled || abs(dockProgress)<0.05 || unfinishedScale || unfinishedEdge || dockProgress*velocity < -0.001
        if dockAxis==9,!cancel{notificationOpen = !notificationClosing}
        if dockAxis==2,!cancel,abs(dockProgress)>0.1 {
            if dockProgress>0{verticalOverlay = verticalOverlay == .expose ? .none:.mission}
            else{verticalOverlay = verticalOverlay == .mission ? .none:.expose}
            overlayFingers=verticalOverlay == .none ? 0:peakCount
        }
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
            else if mode == .swipe || mode == .scale || mode == .edge { finishDock(cancelled:false,at:now) }
            else if mode == .pinch { emit([PadEvent(type:"magnify",x:0,phase:"ended")]) }
            else if mode == .rotate {emit([PadEvent(type:"rotate",x:0,phase:"ended")])}
            else if scrollStarted {
                emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"none",name:scrollName)])
                if now-lastScrollTime<0.09 && hypot(velocityX,velocityY)>60 {
                    inertia=(velocityX,velocityY,now,false)
                }
            } else if mode == .pending && travel<6 && now-start<0.32 {
                finishTap(at:now)
            }
            points=[:];scrollStarted=false;mode = .pending;return
        }
        let c=centroid(incoming)
        if points.isEmpty {
            doubleTapDragging=false
            secondTapCandidate=gestures.enabled(.tapToClick) && incoming.count==1 && (lastTap.map{now-$0.time<doubleTapInterval && hypot(c.x-$0.point.x,c.y-$0.point.y)<44} ?? false)
            if incoming.count != 1 {lastTap=nil}
            stopInertia();points=incoming;previous=c;start=now;last=now;peakCount=incoming.count
            travel=0;dxTotal=0;dyTotal=0;gainSpeed=0;scrollStarted=false;velocityX=0;velocityY=0
            edgeCandidate=nearRightEdge(incoming);systemAction=nil;initialSpan=span(incoming);currentSpan=initialSpan
            initialAngle=angle(incoming);previousAngle=initialAngle
            initialGap=gap(incoming);previousGap=initialGap;swipeFired=false;dockAxis=0;dockProgress=0;dockVelocity=0;mode = .pending
            return
        }
        if Set(points.keys) != Set(incoming.keys) {
            // Fingers land separately. Do not lock a four-finger spread into the
            // provisional three-finger swipe that preceded the final contact.
            if mode == .swipe,incoming.count==4,points.count<4,now-start<0.18 {
                finishDock(cancelled:true,at:now);mode = .pending;swipeFired=false
            }
            if mode == .system,systemAction==nil,incoming.count>peakCount {mode = .pending}

            if mode == .system {points=incoming;previous=c;last=now;return}
            if mode == .swipe || mode == .scale || mode == .edge {points=incoming;previous=c;last=now;return}
            if (mode == .pinch || mode == .rotate),incoming.count==1,points.count==2 {
                points=incoming;previous=c;last=now;return
            }
            // Real fingers lift at different times. Keep the scroll alive until the final lift.
            if scrollStarted && incoming.count==1 && peakCount==2 {
                points=incoming;previous=c;last=now;return
            }
            if scrollStarted {
                emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"none",name:scrollName)]);scrollStarted=false
            }
            if mode == .pinch { emit([PadEvent(type:"magnify",x:0,phase:"cancelled")]) }
            if mode == .rotate {emit([PadEvent(type:"rotate",x:0,phase:"cancelled")])}
            peakCount=max(peakCount,incoming.count)
            // Additional fingers release a dwell click before scrolling or system gestures.
            if incoming.count>=2 && held { up() }
            // Preserve swipe consumption until every finger is lifted.
            if !held { mode = swipeFired ? .swipe:.pending;dxTotal=0;dyTotal=0;initialGap=gap(incoming);previousGap=initialGap }
            edgeCandidate=nearRightEdge(incoming);initialSpan=span(incoming);currentSpan=initialSpan;initialAngle=angle(incoming);previousAngle=initialAngle
            points=incoming;previous=c;last=now;return
        }
        if (mode == .system || mode == .scale || mode == .edge) && incoming.count<peakCount {points=incoming;previous=c;last=now;return}
        let dx=c.x-previous.x,dy=c.y-previous.y,dt=max(0.001,now-last)
        points=incoming;previous=c;last=now;travel+=hypot(dx,dy);dxTotal+=dx;dyTotal+=dy
        if mode == .scale {updateScale(incoming,at:now,dt:dt);return}
        if mode == .edge {updateEdge(at:now,dt:dt);return}
        if mode == .system {
            if ["apps","showDesktop"].contains(systemAction ?? ""),incoming.count==4{currentSpan=span(incoming)}
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
            if (edgeCandidate || (notificationOpen && continuousScaleEnabled && gestures.enabled(.notifications))) && mode == .pending {
                let closing=notificationOpen && dxTotal>7
                if ((edgeCandidate && dxTotal < -7) || closing) && abs(dxTotal)>abs(dyTotal)*1.2 && translation>abs(pinch) {
                    if continuousScaleEnabled {
                        mode = .edge;notificationClosing=closing;dockAxis=9;dockProgress=closing ? -0.01:0.01;dockVelocity=0;dockLastMotion=now
                        dockEvent("began",at:now);updateEdge(at:now,dt:dt)
                    }else{mode = .system;systemAction="notifications"}
                    lastTap=nil;return
                }
                if translation<9 && abs(pinch)<9{return}
                edgeCandidate=false
            }
            let currentAngle=angle(incoming),rotation=angleDifference(currentAngle,initialAngle),arc=abs(rotation)*initialGap*0.5
            if mode == .pending,abs(rotation)>0.12,arc>translation*1.3,arc>abs(pinch) {
                if gestures.enabled(.rotate){mode = .rotate;previousAngle=initialAngle;emit([PadEvent(type:"rotate",x:0,phase:"began")])}
                else{mode = .system;systemAction=nil;return}
            }
            if (mode == .pending || mode == .scroll),abs(pinch)>12 && abs(pinch)>translation*1.5 {
                if scrollStarted {emit([PadEvent(type:"scroll",x:0,y:0,phase:"ended",momentum:"none",name:scrollName)]);scrollStarted=false}
                guard gestures.enabled(.pinchZoom) else{mode = .system;systemAction=nil;return}
                mode = .pinch;previousGap=initialGap;emit([PadEvent(type:"magnify",x:0,phase:"began")])
            } else if mode == .pending,translation>3 && translation>abs(pinch)*0.7 {mode = .scroll}
            if mode == .rotate {
                let delta=angleDifference(currentAngle,previousAngle)*180/Double.pi
                if abs(delta)>0.001{emit([PadEvent(type:"rotate",x:delta,phase:"changed")])}
                previousAngle=currentAngle
            }else if mode == .scroll {
                if scrollStarted && hypot(dx,dy)<=0.001 { return }
                let factor=naturalScroll ? -1.5:1.5
                let sx=(scrollStarted ? dx:dxTotal)*factor,sy=(scrollStarted ? dy:dyTotal)*factor
                emit([PadEvent(type:"scroll",x:sx,y:sy,phase:scrollStarted ? "changed":"began",momentum:"none",name:scrollName)])
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
                let onset=continuousScaleEnabled ? max(2,initialSpan*0.025):max(5,initialSpan*0.07)
                if initialSpan>=18 && abs(contraction)>onset && abs(contraction)>hypot(dxTotal,dyTotal)*0.65 {
                    if continuousScaleEnabled {
                        let allowed=gestures.enabled(contraction<0 ? .showDesktop:.apps)
                        guard allowed else{mode = .system;systemAction=nil;return}
                        mode = .scale;dockAxis=3;swipeFired=true;lastTap=nil
                        dockProgress=contraction<0 ? 0.01:-0.01;dockVelocity=0;dockLastMotion=now
                        dockEvent("began",at:now);updateScale(incoming,at:now,dt:dt);return
                    }
                    if currentSpan/initialSpan<0.93 {mode = .system;systemAction=gestures.enabled(.apps) ? "apps":nil;lastTap=nil;return}
                    if currentSpan/initialSpan>1.07 {mode = .system;systemAction=gestures.enabled(.showDesktop) ? "showDesktop":nil;lastTap=nil;return}
                }
            }
            let ax=abs(dxTotal),ay=abs(dyTotal)
            if dockAxis==0 {
                if ay>12 && ay>ax*1.25 {
                    let closing=dyTotal<0 ? verticalOverlay == .expose:verticalOverlay == .mission
                    let fingers=closing ? overlayFingers:(dyTotal<0 ? gestures.missionFingers:gestures.exposeFingers)
                    guard incoming.count==fingers else{mode = .system;systemAction=nil;return};dockAxis=2
                }else if ax>12 && ax>ay*1.25 {
                    guard incoming.count==gestures.spacesFingers else{mode = .system;systemAction=nil;return};dockAxis=1
                }
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
    private func updateEdge(at now:Double,dt:Double){
        let scale=max(70,min(120,surfaceWidth*0.2))
        let progress=notificationClosing ? -max(0.00001,min(2,max(0,dxTotal/scale))):min(2,max(0,-dxTotal/scale))
        let delta=progress-dockProgress
        if abs(delta)>0.00001{dockVelocity=min(10,max(-10,delta/max(0.001,dt)));dockProgress=progress;dockLastMotion=now;dockEvent("changed",at:now)}
    }
    private func updateScale(_ incoming:[Int:PadPoint],at now:Double,dt:Double){
        guard incoming.count==4,initialSpan>0 else{return}
        currentSpan=span(incoming)
        let progress=min(2,max(-2,4*(currentSpan-initialSpan)/initialSpan))
        let delta=progress-dockProgress
        if abs(delta)>0.00001 {
            dockVelocity=min(10,max(-10,delta/max(0.001,dt)));dockProgress=progress;dockLastMotion=now
            dockEvent("changed",at:now)
        }
    }
    func tick(at now:Double) {
        if let pending=pendingSecondary,now-pending.time>doubleTapInterval{flushSecondary()}
        if !points.isEmpty {
            // Press timers must not overwrite the timestamp of the last real motion.
            let sampleTime=last;update(points,at:now);last=sampleTime
        }
        guard var value=inertia,points.isEmpty else { return }
        let dt=max(0.001,min(0.032,now-value.last)),decay=exp(-dt/0.36)
        value.x*=decay;value.y*=decay;value.last=now
        if hypot(value.x,value.y)<15 { stopInertia();return }
        emit([PadEvent(type:"scroll",x:value.x*dt,y:value.y*dt,phase:"ended",momentum:value.began ? "changed":"began",name:scrollName)])
        value.began=true;inertia=value
    }
    func cancel() {
        systemAction=nil;edgeCandidate=false;pendingSecondary=nil
        if mode == .rotate{emit([PadEvent(type:"rotate",x:0,phase:"cancelled")])}
        finishDock(cancelled:true,at:last)
        if mode == .pinch { emit([PadEvent(type:"magnify",x:0,phase:"cancelled")]) }
        if scrollStarted { emit([PadEvent(type:"scroll",x:0,y:0,phase:"cancelled",momentum:"none",name:scrollName)]) }
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
