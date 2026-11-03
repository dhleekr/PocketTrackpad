# GPT microphone integration

Status: shipped in internal test build 1.4.2 (43). The user confirmed Dictate starts with the iPhone microphone button on the local Mac. Complete start/stop behavior across other app versions remains subject to testing.

The iPhone streams raw microphone audio to the Mac virtual input. Recognition remains in GPT; PocketTrackpad does not transcribe or save audio.

For the `com.openai.codex` desktop app on macOS 14.2 or later, a phone microphone request uses the `globalDictationHold` command instead of searching the conversation's accessibility tree. The phone presents a start/stop toggle; internally, the Mac holds and releases one shortcut. A second toggle cannot accidentally restart recording.

## Automatic registration

- Reuse a supported existing binding, including its custom shortcut.
- If none exists, append one unused binding to the standard Codex keybindings file. Preserve unrelated entries and save an exact private backup before writing.
- Reject invalid files, explicit unbindings, conditional mappings, unsupported custom bindings, and collisions instead of replacing user choices.
- On the first registration, ask the user to quit and reopen GPT once. PocketTrackpad never restarts GPT or discards its work. No manual shortcut assignment is required.
- Registration runs only on an authenticated phone microphone request. Build scripts and test commands do not register anything in the real app.

## Recording confirmation

CoreAudio process metadata must show GPT using the PocketTrackpad input before the iPhone receives `ready`. No conversation contents, window labels, screenshots, or audio samples are used for this check. An already-active or unknown capture state refuses startup. Cancellation and timeout release the held key.

On stop or disconnect, release the key and wait for input capture to end. If completion cannot be confirmed, keep the virtual microphone silent and leave it selected, rather than switching an uncertain recording to the room microphone.

## Verification limits

Fixture tests cover preservation, conflicts, backup, restart detection, start confirmation, cancellation, timeout, and repeated stop. The shortcut command is based on a public third-party integration, not a documented OpenAI integration contract. Current-app command availability, helper-process bundle identifiers, audio-device selection, and dictation UI behavior require real-device verification. Do not describe this candidate as universally compatible or release it as a completed fix before that check.

References:

- [Controller command bindings](https://github.com/DEXCERRONE/stream-deck-codex-micro/blob/main/scripts/codex-keybindings.mjs)
- [Controller press/release implementation](https://github.com/DEXCERRONE/stream-deck-codex-micro/blob/main/bridge/src/codex-voice.jxa)
- CoreAudio `AudioHardware.h`: process object list, input activity, and input device list properties.
