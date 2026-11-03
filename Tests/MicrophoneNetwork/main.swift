import Foundation

final class FakeRoute:MicrophoneAudioRouting {
 var frames=0,stops=0,restores=0
 func start()throws{}
 func append(_ data:Data)throws{frames+=data.count/2}
 func stop(restore:Bool){stops+=1;if restore{restores+=1}}
 func restoreInput(){restores+=1}
}
@MainActor final class FakeGPT:MicrophoneAppControlling {
 var starts=0,stops=0,confirmed=true,failPrepare=false
 func prepare()throws{if failPrepare{throw GPTMicrophoneControl.Failure.buttonUnavailable}}
 func start()async throws{starts+=1}
 func stop()async->Bool{stops+=1;return confirmed}
}
@MainActor func run()async throws {
 let children:[Int:[Int]]=[0:Array(1...2000),2000:[3000],3000:[3001]]
 let broad=MicrophoneButtonSearch.matches(roots:[0],children:{children[$0] ?? []},isMatch:{$0==3001})
 assert(broad.isEmpty,"the old whole-window search exhausts its budget before the composer")
 let focused=MicrophoneButtonSearch.matches(roots:[3000,0],children:{children[$0] ?? []},isMatch:{$0==3001})
 assert(focused == [3001],"focused composer must be searched before a large conversation")
 let ambiguous=MicrophoneButtonSearch.matches(roots:[0],children:{$0==0 ? [1,2]:[]},isMatch:{$0>0})
 assert(ambiguous.count==2,"ambiguous controls must not be pressed")
 print("PASS focused composer search in a large conversation and ambiguous button rejection")
 let key=String(repeating:"test-only-not-a-real-pairing-key-",count:2),gpt=FakeGPT(),route=FakeRoute()
 let host=try MacMicrophoneHost(token:key,port:19767,makeControls:{gpt},makeRoute:{route},deviceAvailable:{true},report:{_ in})
 let connection=PadSecureConnection(host:"127.0.0.1",port:19767,token:key),session=UUID().uuidString
 try await connection.connect()
 func command(_ op:String)async throws{try await connection.send(JSONSerialization.data(withJSONObject:["op":op,"session":session]))}
 func response()async throws->[String:String]{try JSONSerialization.jsonObject(with:await connection.receive()) as! [String:String]}
 try await command("start");let started=try await response();assert(started["status"]=="ready" && gpt.starts==1)
 for i in 1...6 {try await connection.send(Data([1,0,0,0,UInt8(i)])+Data(repeating:0,count:1920));let ack=try await response();assert(ack["ack"]==String(i))}
 try await command("stop");let stopped=try await response();assert(stopped["status"]=="stopped" && gpt.stops==1 && route.restores==1 && route.frames==5760)
 connection.cancel();try await Task.sleep(for:.milliseconds(200))
 assert(gpt.stops==1,"normal close must not press the stop button a second time")
 let gpt2=FakeGPT(),route2=FakeRoute();gpt2.confirmed=false
 await host.shutdown()
 let host2=try MacMicrophoneHost(token:key,port:19768,makeControls:{gpt2},makeRoute:{route2},deviceAvailable:{true},report:{_ in})
 let c2=PadSecureConnection(host:"127.0.0.1",port:19768,token:key),s2=UUID().uuidString
 try await c2.connect();try await c2.send(JSONSerialization.data(withJSONObject:["op":"start","session":s2]));_ = try await c2.receive()
 try await c2.send(JSONSerialization.data(withJSONObject:["op":"stop","session":s2]));let failed=try JSONSerialization.jsonObject(with:await c2.receive()) as! [String:String]
 assert(failed["status"]=="checkGPT" && route2.restores==0 && route2.stops==1,"uncertain stop must stay silent and must not switch to the room microphone")
 c2.cancel();await host2.shutdown()
 let gpt3=FakeGPT();gpt3.failPrepare=true
 let host3=try MacMicrophoneHost(token:key,port:19769,makeControls:{gpt3},makeRoute:{FakeRoute()},deviceAvailable:{true},report:{_ in})
 let c3=PadSecureConnection(host:"127.0.0.1",port:19769,token:key),s3=UUID().uuidString
 try await c3.connect();try await c3.send(JSONSerialization.data(withJSONObject:["op":"start","session":s3]))
 let rejection=try JSONSerialization.jsonObject(with:await c3.receive()) as! [String:String]
 assert(rejection["status"]=="dictateUnavailable" && gpt3.starts==0,"missing GPT button must return an explicit rejection before recording starts")
 c3.cancel();await host3.shutdown()
 let gpt4=FakeGPT(),route4=FakeRoute()
 let host4=try MacMicrophoneHost(token:key,port:19770,makeControls:{gpt4},makeRoute:{route4},deviceAvailable:{true},report:{_ in})
 let c4=PadSecureConnection(host:"127.0.0.1",port:19770,token:key),s4=UUID().uuidString
 try await c4.connect();try await c4.send(JSONSerialization.data(withJSONObject:["op":"start","session":s4]));_ = try await c4.receive()
 await host4.shutdown()
 assert(gpt4.starts==1 && gpt4.stops==1 && route4.stops==1 && route4.restores==1,"receiver shutdown must finish active dictation before exiting")
 c4.cancel()
 print("PASS authenticated audio packets, acknowledgments, one start/stop, no duplicate stop, and silent fail-closed routing")
}
Task{@MainActor in do{try await run();exit(0)}catch{print("FAIL",error);exit(1)}}
RunLoop.main.run()
