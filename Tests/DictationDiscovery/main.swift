import Foundation
@MainActor func run(){
 let text=DictationShortcutDiscovery.parseDisplayed
 assert(text("⌃⌥⌘H")==GPTDictationBinding.Shortcut.parse("Control+Option+Command+H"))
 assert(text("Control + Option + Command + H")==GPTDictationBinding.Shortcut.parse("Control+Option+Command+H"))
 assert(text("Not assigned")==nil && text("Caps Lock")==nil)
 assert(text("Voice chat settings")==nil && text("API key")==nil)
 assert(text("Option + Space")?.key==49)
 assert(text("Command + F12")?.key==111)
 assert(text("Control + Return")?.key==36)
 let fixture=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
 defer{try? FileManager.default.removeItem(at:fixture)}
 try! Data(#"{"globalDictationHotkey":"Ctrl+Command+Alt+H","ignored":{"globalDictationHotkey":"Command+X"}}"#.utf8).write(to:fixture)
 assert(CodexDictationPreference.read(at:fixture)?.key==4)
 try! Data(#"{"globalDictationHotkey":"Control+Option+Command+J"}"#.utf8).write(to:fixture)
 assert(CodexDictationPreference.read(at:fixture)?.key==38,"Changed target preference must replace the previous key")
 try! Data(#"{"globalDictationHotkey":null}"#.utf8).write(to:fixture)
 assert(CodexDictationPreference.read(at:fixture)==nil,"Disabled shortcut must never return the cached key")
 try! Data(#"{"globalDictationHotkey":false}"#.utf8).write(to:fixture)
 assert(CodexDictationPreference.read(at:fixture)==nil)
 print("PASS live Codex preference replacement, disabled setting, invalid type, and unrelated fields ignored")
 print("PASS glyph and text shortcut import; unassigned, Caps Lock and unrelated values rejected")
 exit(0)
}
Task{@MainActor in run()}
RunLoop.main.run()
