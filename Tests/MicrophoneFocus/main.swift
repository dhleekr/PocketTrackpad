import Foundation
final class Route:MicrophoneAudioRouting {
 var frames=0,stops=0,restores=0
 func start()throws{}
 func append(_ data:Data)throws{frames+=data.count/2}
 func stop(restore:Bool){stops+=1;if restore{restores+=1}}
 func restoreInput(){restores+=1}
}
@MainActor final class Target:MicrophoneAppControlling {
 var focusMoved=false,stops=0
 func prepare()async throws{}
 func start()async throws{}
 func hasFinished()->Bool{focusMoved}
 func stop()async->Bool{stops+=1;return true}
}
@MainActor func run()async throws {
 let target=Target(),route=Route(),peer=UUID(),session=UUID().uuidString
 var replies=[[String:String]]()
 let host=try MacMicrophoneHost(token:String(repeating:"k",count:48),port:19785,makeControls:{target},makeRoute:{route},deviceAvailable:{true},report:{_ in})
 let sink:(Data)->Void={replies.append((try? JSONSerialization.jsonObject(with:$0)) as? [String:String] ?? [:])}
 func command(_ op:String)async throws{await host.receiveBluetooth(try JSONSerialization.data(withJSONObject:["op":op,"session":session]),peer:peer,send:sink)}
 try await command("start")
 target.focusMoved=true
 // This represents transient capture metadata loss when focus moves. Audio
 // continues arriving from the authenticated phone until its explicit stop.
 for i in 1...8 {
  try await Task.sleep(for:.milliseconds(100))
  await host.receiveBluetooth(Data([1,0,0,0,UInt8(i),0,0]),peer:peer,send:sink)
 }
 let alive=route.stops==0 && route.frames==8 && !replies.contains{$0["status"]=="ended"}
 guard alive else{print("FAIL focus/capture metadata change ended an explicitly active phone microphone");await host.shutdown();exit(1)}
 try await command("stop")
 guard target.stops==1,route.stops==1,route.restores==1,replies.last?["status"]=="stopped" else{print("FAIL explicit stop did not finish the original session exactly once");exit(1)}
 await host.shutdown()
 print("PASS focus change keeps audio alive; explicit stop finishes the original session exactly once")
 exit(0)
}
Task{@MainActor in do{try await run()}catch{print("FAIL",error);exit(1)}}
RunLoop.main.run()
