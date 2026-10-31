import Foundation
import Network

final class DelayedAckHost:@unchecked Sendable {
    let queue=DispatchQueue(label:"test.delayed.ack")
    private var listener:NWListener!
    private var decoder=PadFrameDecoder()
    private let lock=NSLock()
    private var frames=0,movement=0.0,released=false,lateMove=false
    var result:(Int,Double,Bool,Bool){lock.lock();defer{lock.unlock()};return(frames,movement,released,lateMove)}
    init()throws {
        listener=try NWListener(using:PadSecureLink.parameters(token:String(repeating:"a",count:32)),on:18767)
        listener.newConnectionHandler={[weak self] c in
            guard let self else{return}
            c.stateUpdateHandler={state in if case .ready=state{self.send(["status":"ok"],on:c);self.receive(c)}}
            c.start(queue:self.queue)
        };listener.start(queue:queue)
    }
    private func send(_ object:[String:Any],on c:NWConnection){if let d=try? JSONSerialization.data(withJSONObject:object),let f=try? PadSecureLink.frame(d){c.send(content:f,completion:.contentProcessed{_ in})}}
    private func receive(_ c:NWConnection){c.receive(minimumIncompleteLength:1,maximumLength:20000){[weak self] data,_,_,error in
        guard let self,error==nil,let data else{return}
        if let decoded=try? self.decoder.append(data){for frame in decoded{
            guard let o=try? JSONSerialization.jsonObject(with:frame) as? [String:Any],let id=o["id"] as? Int,let events=o["events"] as? [[String:Any]] else{continue}
            self.lock.lock();self.frames+=1
            for e in events{if e["type"] as? String=="move"{self.lateMove = self.lateMove || self.released;self.movement += e["x"] as? Double ?? 0};if e["type"] as? String=="up"{self.released=true}}
            self.lock.unlock()
            self.queue.asyncAfter(deadline:.now()+0.15){self.send(["status":"ok","id":id],on:c)}
        }};self.receive(c)
    }}
}
@main struct RateTest {
    @MainActor static func main()async {
        do {
            let host=try DelayedAckHost();try await Task.sleep(nanoseconds:200_000_000)
            let client=WiFiClient();let trace=PadDiagnostics();trace.start(bluetooth:false);client.diagnostics=trace;client.pair("pockettrackpad://localhost:18767/#"+String(repeating:"a",count:32),persist:false)
            for _ in 0..<200{if client.ready{break};try await Task.sleep(nanoseconds:10_000_000)}
            guard client.ready else{print("FAIL local TLS fixture");exit(1)}
            for _ in 0..<120{client.send([PadEvent(type:"move",x:1,y:0)]);try await Task.sleep(nanoseconds:8_333_333)}
            client.send([PadEvent(type:"up")]);try await Task.sleep(nanoseconds:350_000_000)
            let(frames,distance,released,lateMove)=host.result
            print("120 Hz input / 150 ms delayed ACK: \(frames) transmitted frames, distance \(distance), peak telemetry \(client.peakInFlight)")
            let cadence=frames>=90,total=distance==120 && released && !lateMove,bounded=client.pendingFrameCount<=64 && client.pendingEventCount<=128
            print("\(cadence ? "PASS":"FAIL") delayed ACK does not cap control cadence")
            print("\(total ? "PASS":"FAIL") movement and release order preserved")
            print("\(bounded ? "PASS":"FAIL") bounded transport state")
            let report=trace.finish()
            let sends=Set(report.samples.filter{$0.stage == .sendStart}.compactMap{$0.sequence})
            let completions=Set(report.samples.filter{$0.stage == .sendComplete}.compactMap{$0.sequence})
            let acks=Set(report.samples.filter{$0.stage == .ack}.compactMap{$0.sequence})
            let captured=sends.count>=90 && sends.isSubset(of:completions) && sends.isSubset(of:acks)
            print("\(captured ? "PASS":"FAIL") actual client trace correlates send, completion, and delayed ACK without losing input")
            client.disconnect();exit(cadence && total && bounded && captured ? 0:1)
        }catch{print("FAIL fixture: \(error)");exit(1)}
    }
}
