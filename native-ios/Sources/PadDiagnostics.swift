import Foundation

enum PadTraceStage:String,Codable {
    case display,touchBegin,touchMove,touchSample,touchEnd,touchCancel,gesture,enqueue,sendStart,sendComplete,ack
    case receive,output,bleState,bleAdvertise,bleSubscribe,bleAuth,disconnected
}

// Explicitly started, bounded, in-memory timing trace. No coordinates, text,
// addresses, device/account identifiers, pairing secrets, or screen content are accepted here.
final class PadDiagnostics {
    struct Sample:Codable {
        var stage:PadTraceStage
        var ms:Double
        var sourceMS:Double?
        var event:String?
        var phase:String?
        var momentum:String?
        var count:Int?
        var pending:Int?
        var sequence:Int?
        var value:Double?
    }
    struct Report:Codable {
        var format=1
        var transport:String
        var durationSeconds:Double
        var droppedSamples:Int
        var samples:[Sample]
    }
    private var began:Double?
    private var duration=15.0
    private var transport="Wi-Fi"
    private var remoteClock=false
    private var sourceOrigin:Double?
    private var samples=[Sample]()
    private var dropped=0
    let limit:Int
    init(limit:Int=20000){self.limit=max(1,min(20000,limit))}
    func start(bluetooth:Bool,at time:Double=ProcessInfo.processInfo.systemUptime,duration:Double=15,remoteClock:Bool=false){
        began=time;self.duration=min(15,max(0.1,duration));transport=bluetooth ? "Bluetooth":"Wi-Fi"
        samples=[];samples.reserveCapacity(limit);dropped=0;self.remoteClock=remoteClock;sourceOrigin=nil
    }
    func record(_ stage:PadTraceStage,at now:Double=ProcessInfo.processInfo.systemUptime,source:Double?=nil,event:String?=nil,phase:String?=nil,momentum:String?=nil,count:Int?=nil,pending:Int?=nil,sequence:Int?=nil,value:Double?=nil){
        guard let began,now.isFinite,now>=began,now-began<=duration else{return}
        guard samples.count<limit else{dropped+=1;return}
        let validEvent=event.flatMap{["move","scroll","magnify","dockSwipe","click","double","right","down","up","shortcut","status"].contains($0) ? $0:nil}
        let validPhase=phase.flatMap{["began","changed","ended","cancelled","none"].contains($0) ? $0:nil}
        if remoteClock,sourceOrigin==nil,let source,source.isFinite {sourceOrigin=source}
        let origin=remoteClock ? (sourceOrigin ?? began):began
        let validMomentum=momentum.flatMap{["none","began","changed","ended"].contains($0) ? $0:nil}
        let sourceMS=source.flatMap{$0.isFinite && abs($0-origin)<60 ? ($0-origin)*1000:nil}
        samples.append(Sample(stage:stage,ms:(now-began)*1000,sourceMS:sourceMS,event:validEvent,phase:validPhase,momentum:validMomentum,count:count,pending:pending,sequence:sequence,value:value.flatMap{$0.isFinite ? $0:nil}))
    }
    func finish()->Report {
        began=nil
        let result=Report(transport:transport,durationSeconds:duration,droppedSamples:dropped,samples:samples)
        samples=[];return result
    }
}
