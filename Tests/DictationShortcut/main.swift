import Foundation

@MainActor func run()async throws {
 func data(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value)}
 let existing:[[String:Any]]=[["command":"unrelated","key":"Ctrl+Command+Alt+H","custom":true]]
 let plan=try GPTDictationBinding.plan(data(existing))
 let merged=try JSONSerialization.jsonObject(with:plan.replacement!) as! [[String:Any]]
 assert(merged.count==2 && merged[0]["custom"] as? Bool==true && merged[1]["key"] as? String=="Ctrl+Command+Alt+F18")
 let repeatedPlan=try GPTDictationBinding.plan(plan.replacement);assert(repeatedPlan.replacement==nil)
 let custom=try data([["command":"globalDictationHold","key":"Control+Option+Command+D"]])
 let customPlan=try GPTDictationBinding.plan(custom);assert(customPlan.shortcut.key==2)
 for input in [Data("{broken".utf8),try data(["not-an-array":true])]{do{_ = try GPTDictationBinding.plan(input);assertionFailure()}catch{}}
 for entry:[String:Any] in [["command":"globalDictationHold","key":NSNull()],["command":"-globalDictationHold","key":"Ctrl+H"],["command":"globalDictationHold","key":"Ctrl+H","when":"composerFocus"]] {
  do{_ = try GPTDictationBinding.plan(data([entry]));assertionFailure()}catch{}
 }
 let folder=FileManager.default.temporaryDirectory.appendingPathComponent("PocketTrackpadBindingTest-"+UUID().uuidString)
 try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
 defer{try? FileManager.default.removeItem(at:folder)}
 let suite="PocketTrackpadBindingTest-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
 defer{defaults.removePersistentDomain(forName:suite)}
 let url=folder.appendingPathComponent("keybindings.json"),original=try data(existing)
 try original.write(to:url)
 do{_ = try GPTDictationBinding.register(at:url,processIdentity:"old",defaults:defaults);assertionFailure()}catch GPTDictationBinding.Failure.restartRequired{}
 let backups=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).filter{$0.pathExtension=="backup"}
 assert(backups.count==1);let backupData=try Data(contentsOf:backups[0]);assert(backupData==original)
 do{_ = try GPTDictationBinding.register(at:url,processIdentity:"old",defaults:defaults);assertionFailure()}catch GPTDictationBinding.Failure.restartRequired{}
 _ = try GPTDictationBinding.register(at:url,processIdentity:"new",defaults:defaults)
 let fileCount=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil).count;assert(fileCount==2)
 let alias=folder.appendingPathComponent("alias.json");try FileManager.default.createSymbolicLink(at:alias,withDestinationURL:url)
 do{_ = try GPTDictationBinding.register(at:alias,processIdentity:"new",defaults:defaults);assertionFailure()}catch GPTDictationBinding.Failure.unsafePath{}
 print("PASS preserve custom shortcuts, avoid collisions, reject malformed/disabled/conditional bindings, exact backup, idempotence, restart gate, and symlink refusal")
 let shortcut=GPTDictationBinding.Shortcut.parse("Ctrl+Command+Alt+H")!
 var active:Bool?=false,events=[Bool]()
 let recording=GPTShortcutRecording(shortcut:shortcut,post:{down in events.append(down);active=down},capture:{active})
 try await recording.start();assert(events == [true] && recording.held)
 let stopped=await recording.stop();assert(stopped);assert(events == [true,false] && !recording.held)
 let stoppedAgain=await recording.stop();assert(stoppedAgain);assert(events == [true,false],"repeat stop must not toggle recording back on")
 active=true
 let busy=GPTShortcutRecording(shortcut:shortcut,post:{events.append($0)},capture:{active})
 do{try await busy.start();assertionFailure()}catch{}
 assert(events == [true,false],"an existing recording must not receive a start or stop key")
 active=nil
 do{try await busy.start();assertionFailure()}catch{}
 assert(events == [true,false],"unknown capture state must not send keys")
 active=false;var cancelledEvents=[Bool]()
 let cancelled=GPTShortcutRecording(shortcut:shortcut,post:{cancelledEvents.append($0)},capture:{false})
 let attempt=Task{@MainActor in try await cancelled.start()}
 try await Task.sleep(for:.milliseconds(150));attempt.cancel()
 do{try await attempt.value;assertionFailure()}catch{}
 assert(cancelledEvents == [true,false] && !cancelled.held,"cancelling startup must release the key")
 let unconfirmed=GPTShortcutRecording(shortcut:shortcut,post:{cancelledEvents.append($0)},capture:{false},startTimeout:0.15)
 do{try await unconfirmed.start();assertionFailure()}catch{}
 assert(cancelledEvents == [true,false,true,false] && !unconfirmed.held,"startup timeout must release the key")
 var uncertain:Bool?=false
 let uncertainStop=GPTShortcutRecording(shortcut:shortcut,post:{down in uncertain=down ? true:nil},capture:{uncertain},stopTimeout:0.15)
 try await uncertainStop.start();let stoppedUncertain=await uncertainStop.stop()
 assert(!stoppedUncertain,"unknown stop state must not report success or restore room microphone")
 print("PASS capture-confirmed start, one key release, idempotent stop, existing-recording protection, and unknown-state refusal")
}
Task{@MainActor in do{try await run();exit(0)}catch{print("FAIL",error);exit(1)}}
RunLoop.main.run()
