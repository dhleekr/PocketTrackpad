import Foundation

final class FakeRoute:MicrophoneAudioRouting {
 var frames=0,stops=0,restores=0
 func start()throws{}
 func append(_ data:Data)throws{frames+=data.count/2}
 func stop(restore:Bool){stops+=1;if restore{restores+=1}}
 func restoreInput(){restores+=1}
}
@MainActor final class FakeGPT:MicrophoneAppControlling {
 var starts=0,stops=0,confirmed=true,failPrepare=false,stopDelay=0
 func prepare()throws{if failPrepare{throw GPTMicrophoneControl.Failure.buttonUnavailable}}
 func start()async throws{starts+=1}
 func stop()async->Bool{stops+=1;if stopDelay>0{try? await Task.sleep(for:.milliseconds(stopDelay))};return confirmed}
}
@MainActor func run()async throws {
 assert(MicrophoneControlIdentity.matches("Dictate (⌥ Space)",labels:["dictate"]),"Dictate tooltip with shortcut must be recognized")
 assert(!MicrophoneControlIdentity.matches("Dictate settings",labels:["dictate"]),"settings must not be treated as a recording button")
 let children:[Int:[Int]]=[0:Array(1...2000),2000:[3000],3000:[3001]]
 let broad=MicrophoneButtonSearch.matches(roots:[0],children:{children[$0] ?? []},isMatch:{$0==3001})
 assert(broad == [3001],"composer after a large conversation must be searched before stale history")
 let focused=MicrophoneButtonSearch.matches(roots:[3000,0],children:{children[$0] ?? []},isMatch:{$0==3001})
 assert(focused == [3001],"focused composer must be searched before a large conversation")
 let repeated=MicrophoneButtonSearch.matches(roots:[0],identity:{AnyHashable($0)},children:{$0==0 ? [1,1]:[]},isMatch:{$0==1})
 assert(repeated == [1],"the same accessibility control must not become an ambiguous duplicate")
 let ambiguous=MicrophoneButtonSearch.matches(roots:[0],children:{$0==0 ? [1,2]:[]},isMatch:{$0>0})
 assert(ambiguous.count==2,"ambiguous controls must not be pressed")
 print("PASS focused composer search in a large conversation and ambiguous button rejection")
 let key=String(repeating:"test-only-not-a-real-pairing-key-",count:2),gpt=FakeGPT(),route=FakeRoute()
 let host=try MacMicrophoneHost(token:key,port:19767,makeControls:{gpt},makeRoute:{route},deviceAvailable:{true},report:{_ in})
 let connection=PadSecureConnection(host:"127.0.0.1",port:19767,token:key),session=UUID().uuidString
 try await connection.connect()
 func command(_ op:String)async throws{try await connection.send(JSONSerialization.data(withJSONObject:["op":op,"session":session]))}
 func response()async throws->[String:String]{try JSONSerialization.jsonObject(with:await connection.receive()) as! [String:String]}
 try await command("capabilities");let capabilities=try await response()
 assert(capabilities["shortcutSetup"]=="explicit" && gpt.starts==0 && route.frames==0,"capability discovery must not start or configure a target app")
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
 assert(route2.restores==1,"explicit receiver quit must restore the prior input even after an unconfirmed stop")
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
 let gpt5=FakeGPT(),route5=FakeRoute(),peer=UUID();var bluetoothReplies=[[String:String]]()
 let host5=try MacMicrophoneHost(token:key,port:19771,makeControls:{gpt5},makeRoute:{route5},deviceAvailable:{true},report:{_ in})
 let bluetoothSession=UUID().uuidString
 func bluetoothCommand(_ op:String)async throws{
     let packet=try JSONSerialization.data(withJSONObject:["op":op,"session":bluetoothSession])
     await host5.receiveBluetooth(packet,peer:peer,send:{data in bluetoothReplies.append((try? JSONSerialization.jsonObject(with:data)) as? [String:String] ?? [:])})
 }
 try await bluetoothCommand("capabilities");assert(bluetoothReplies.last?["shortcutSetup"]=="explicit")
 try await bluetoothCommand("start");assert(bluetoothReplies.last?["status"]=="ready" && gpt5.starts==1)
 let compressed=try MicrophoneADPCM.encode(Data(repeating:0,count:1280))
 await host5.receiveBluetooth(Data([2,0,0,0,1])+compressed,peer:peer,send:{_ in})
 assert(route5.frames==1920 && bluetoothReplies.last?["ack"]=="1","BLE audio must decode to the same 48 kHz virtual input as Wi-Fi")
 try await bluetoothCommand("stop");assert(bluetoothReplies.last?["status"]=="stopped" && gpt5.stops==1 && route5.restores==1)
 await host5.closeBluetooth(peer:peer);assert(gpt5.stops==1,"Bluetooth close must never toggle a stopped recording back on")
 await host5.shutdown()
 let gpt6=FakeGPT(),route6=FakeRoute(),peer6=UUID(),session6=UUID().uuidString;gpt6.stopDelay=100
 var replies6=[[String:String]]()
 let host6=try MacMicrophoneHost(token:key,port:19772,makeControls:{gpt6},makeRoute:{route6},deviceAvailable:{true},report:{_ in})
 func packet6(_ op:String)throws->Data{try JSONSerialization.data(withJSONObject:["op":op,"session":session6])}
 let sink6:(Data)->Void={replies6.append((try? JSONSerialization.jsonObject(with:$0)) as? [String:String] ?? [:])}
 await host6.receiveBluetooth(try packet6("start"),peer:peer6,send:sink6)
 let stopping6=Task{@MainActor in await host6.receiveBluetooth(try! packet6("stop"),peer:peer6,send:sink6)}
 try await Task.sleep(for:.milliseconds(15))
 await host6.receiveBluetooth(Data([1,0,0,0,1,0,0]),peer:peer6,send:sink6)
 await stopping6.value
 guard replies6.last?["status"]=="stopped",gpt6.stops==1 else{print("FAIL a late audio packet removes the stop acknowledgement while dictation is finishing");exit(1)}
 await host6.shutdown()
 print("PASS late audio during asynchronous stop cannot remove the acknowledgement or restart recording")
 let gpt7=FakeGPT(),route7=FakeRoute(),peer7=UUID(),oldSession=UUID().uuidString,newSession=UUID().uuidString
 let host7=try MacMicrophoneHost(token:key,port:19773,makeControls:{gpt7},makeRoute:{route7},deviceAvailable:{true},report:{_ in})
 func request7(_ op:String,_ session:String)async throws{
     await host7.receiveBluetooth(try JSONSerialization.data(withJSONObject:["op":op,"session":session]),peer:peer7,send:{_ in})
 }
 try await request7("start",oldSession);try await request7("stop",oldSession);try await request7("start",newSession)
 try await request7("cancel",oldSession)
 assert(gpt7.starts==2 && gpt7.stops==1,"a delayed close from an old recording must not stop the new one")
 try await request7("capabilities",newSession);assert(gpt7.stops==1,"capability checks must not interrupt an active recording")
 try await request7("cancel",newSession);assert(gpt7.stops==2 && route7.restores==2)
 await host7.shutdown()
 print("PASS old-session cancellation and capability probes cannot interfere with a new recording")
 print("PASS Bluetooth start, compressed audio delivery, stop acknowledgement, and original input restoration without a Wi-Fi audio connection")
 print("PASS authenticated audio packets, acknowledgments, one start/stop, no duplicate stop, and silent fail-closed routing")
}
Task{@MainActor in do{try await run();exit(0)}catch{print("FAIL",error);exit(1)}}
RunLoop.main.run()
