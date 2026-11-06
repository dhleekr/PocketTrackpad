import Foundation
import CoreGraphics

@MainActor func run()async throws {
 func data(_ value:Any)throws->Data{try JSONSerialization.data(withJSONObject:value)}
 let custom=try data([["command":"globalDictationHold","key":"Control+Option+Command+D"]])
 assert(GPTDictationBinding.existing(in:custom)?.key==2)
 for input in [nil,Data("{broken".utf8),try data(["not-an-array":true]),try data([["command":"unrelated","key":"Ctrl+H"]])]{assert(GPTDictationBinding.existing(in:input)==nil)}
 for entry:[String:Any] in [["command":"globalDictationHold","key":NSNull()],["command":"-globalDictationHold","key":"Ctrl+H"],["command":"globalDictationHold","key":"Ctrl+H","when":"composerFocus"]]{let input=try data([entry]);assert(GPTDictationBinding.existing(in:input)==nil)}
 print("PASS read-only fallback; missing, malformed, disabled and conditional mappings never require registration")
 let suite="PocketTrackpadProfileTest-"+UUID().uuidString,defaults=UserDefaults(suiteName:suite)!
 defer{defaults.removePersistentDomain(forName:suite)}
 let profile=DictationProfiles.Profile(key:4,flags:CGEventFlags.maskControl.rawValue|CGEventFlags.maskCommand.rawValue,mode:.toggle)
 DictationProfiles.save(profile,bundle:"test.app",defaults:defaults)
 assert(DictationProfiles.load(bundle:"test.app",defaults:defaults)==profile)
 assert(DictationProfiles.load(bundle:"another.app",defaults:defaults)==nil)
 DictationProfiles.save(nil,bundle:"test.app",defaults:defaults)
 assert(DictationProfiles.load(bundle:"test.app",defaults:defaults)==nil)
 print("PASS per-app user-owned shortcut profiles persist and remove without touching target settings")
 let codexProfile=CodexDictationPreference.profile(data:try data(["globalDictationHotkey":"Control+Option+Command+H"]))
 guard codexProfile?.mode.rawValue=="doubleTap" else{print("FAIL Codex starts with a held shortcut that other input can cancel");exit(1)}
 let toggledProfile=CodexDictationPreference.profile(data:try data(["globalDictationHotkey":"Control+H","globalDictationToggleHotkey":"Command+J"]))
 assert(toggledProfile?.mode == .toggle && toggledProfile?.key==38,"prefer the target's assigned hands-free shortcut")
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
 var toggleActive:Bool?=false,toggleEvents=[Bool]()
 let toggle=GPTShortcutRecording(shortcut:shortcut,post:{down in toggleEvents.append(down);if down{toggleActive = !(toggleActive ?? false)}},capture:{toggleActive},mode:.toggle)
 try await toggle.start();assert(toggleEvents == [true,false])
 let toggleStopped=await toggle.stop();assert(toggleStopped && toggleEvents == [true,false,true,false])
 _ = await toggle.stop();assert(toggleEvents == [true,false,true,false],"a second stop must never restart toggle dictation")
 var wrongDeviceActive:Bool?=false,wrongDeviceEvents=[Bool]()
 let wrongDevice=GPTShortcutRecording(shortcut:shortcut,post:{down in wrongDeviceEvents.append(down);if down{wrongDeviceActive = !(wrongDeviceActive ?? false)}},capture:{false},mode:.toggle,activity:{wrongDeviceActive},startTimeout:0.1)
 do{try await wrongDevice.start();assertionFailure()}catch{}
 let cleaned=await wrongDevice.stop();assert(cleaned && wrongDeviceEvents == [true,false,true,false],"a target using another microphone must still be stopped after route confirmation fails")
 print("PASS balanced toggle start/stop and no duplicate toggle on repeated stop")
 var originalFocused=true,focusActive:Bool?=false,stopFocusCalls=0
 let focusChanged=GPTShortcutRecording(shortcut:shortcut,post:{down in
     if down && !originalFocused{throw GPTMicrophoneControl.Failure.openGPT}
     if down{focusActive = !(focusActive ?? false)}
 },capture:{focusActive},mode:.toggle,prepareStop:{originalFocused=true;stopFocusCalls+=1},stopTimeout:0.8)
 try await focusChanged.start();originalFocused=false
 let focusStopped=await focusChanged.stop()
 guard focusStopped && stopFocusCalls==1 else{print("FAIL switching foreground apps prevents the original recording from stopping");exit(1)}
 print("PASS stop returns to the original target after foreground focus changes")
 var handsFree:Bool?=false,handsFreeEvents=[Bool](),handsFreeTimes=[Double](),pressCount=0,focus=true
 let latched=GPTShortcutRecording(shortcut:shortcut,post:{down in
  if down && !focus{throw GPTMicrophoneControl.Failure.openGPT}
  handsFreeEvents.append(down);handsFreeTimes.append(ProcessInfo.processInfo.systemUptime)
  if down{pressCount+=1;if pressCount==2{handsFree=true}else if pressCount==3{handsFree=false}}
 },capture:{handsFree},mode:.doubleTap,prepareStop:{focus=true},stopTimeout:0.8)
 try await latched.start()
 assert(handsFreeEvents == [true,false,true,false] && !latched.held && handsFree==true,"hands-free start releases every shortcut key")
 guard handsFreeTimes[1]-handsFreeTimes[0]<0.05 else{print("FAIL start pulse consumes too much of Codex pending-start window");exit(1)}
 focus=false;try await Task.sleep(for:.milliseconds(150))
 assert(handsFree==true && !latched.held,"other input cannot release a held recording shortcut")
 let latchStopped=await latched.stop()
 assert(latchStopped && handsFree==false && handsFreeEvents == [true,false,true,false,true,false])
 _ = await latched.stop();assert(handsFreeEvents.count==6,"repeated stop must not start another recording")
 print("PASS Codex hands-free double tap releases all keys and stops the original app after focus moves")
 var appFocused=true,backgroundActive:Bool?=false
 let background=GPTShortcutRecording(shortcut:shortcut,post:{down in if down{backgroundActive = !(backgroundActive ?? false)}},capture:{backgroundActive},mode:.toggle,activity:{appFocused ? backgroundActive:false},prepareStop:{appFocused=true},stopTimeout:0.8)
 try await background.start();appFocused=false
 let backgroundStopped=await background.stop()
 guard backgroundStopped && backgroundActive==false else{print("FAIL background capture metadata skips the original app stop");exit(1)}
 print("PASS stop refreshes the original app before interpreting background capture metadata")
 var polledActive:Bool?=false,keyDown=false,presses=0
 let polled=GPTShortcutRecording(shortcut:shortcut,post:{down in
  keyDown=down
  if down {
   presses+=1
   if presses==1{polledActive=true}
   else {Task{@MainActor in try? await Task.sleep(for:.milliseconds(20));if keyDown{polledActive=false}}}
  }
 },capture:{polledActive},mode:.toggle,stopTimeout:0.8)
 try await polled.start()
 let polledStopped=await polled.stop()
 guard polledStopped && polledActive==false else{print("FAIL zero-duration stop is missed by an asynchronously sampled hotkey");exit(1)}
 print("PASS explicit stop stays pressed long enough for the target hotkey watcher")
 print("PASS capture-confirmed start, one key release, idempotent stop, existing-recording protection, and unknown-state refusal")
}
Task{@MainActor in do{try await run();exit(0)}catch{print("FAIL",error);exit(1)}}
RunLoop.main.run()
