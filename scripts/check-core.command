#!/bin/zsh
set -eu
cd "${0:A:h:h}"
TASK_CHECK=$(mktemp -d "${TMPDIR:-/tmp}/pocket-core-check.XXXXXX")
trap 'rm -rf "$TASK_CHECK"' EXIT
TASK_CACHE="${TMPDIR:-/tmp}/pocket-trackpad-module-cache"
compile_run() {
  local name="$1"; shift
  swiftc -module-cache-path "$TASK_CACHE" "$@" -o "$TASK_CHECK/$name"
  "$TASK_CHECK/$name"
}
compile_run repeat shared/BLEWire.swift MacQuickKeys.swift KeyRepeat.swift Tests/KeyRepeat/main.swift
compile_run discovery DictationShortcutDiscovery.swift DictationShortcutMonitor.swift MicrophoneInterfaces.swift MacVirtualMicrophone.swift GPTDictationShortcut.swift GPTMicrophoneControl.swift Tests/DictationDiscovery/main.swift
compile_run dictation DictationShortcutDiscovery.swift DictationShortcutMonitor.swift MicrophoneInterfaces.swift MacVirtualMicrophone.swift GPTDictationShortcut.swift GPTMicrophoneControl.swift Tests/DictationShortcut/main.swift
compile_run microphone DictationShortcutDiscovery.swift DictationShortcutMonitor.swift MicrophoneInterfaces.swift MacVirtualMicrophone.swift GPTDictationShortcut.swift GPTMicrophoneControl.swift MacMicrophoneHost.swift shared/SecureLink.swift shared/MicrophoneWire.swift Tests/MicrophoneNetwork/main.swift
compile_run mic-stop shared/SecureLink.swift Tests/MicrophoneStop/main.swift
compile_run ble-audio shared/SecureLink.swift shared/MicrophoneWire.swift Tests/BLEMicrophone/main.swift
compile_run keys shared/BLEWire.swift MacQuickKeys.swift Tests/QuickKeys/main.swift
compile_run displays CursorBounds.swift Tests/CursorBounds/main.swift
compile_run connection ConnectionState.swift Tests/ConnectionState/main.swift
compile_run gestures native-ios/Sources/GesturePreferences.swift native-ios/Sources/GestureEngine.swift native-ios/Tests/main.swift
compile_run wire shared/BLEWire.swift native-ios/Tests/BLE/main.swift
compile_run motion MotionPlayback.swift Tests/Motion/main.swift -framework CoreVideo
compile_run flow shared/BLEWire.swift Tests/BLEFlow/main.swift
clang -O2 -c vendor/TouchSynthesis/TouchEvents.c -o "$TASK_CHECK/touch.o"
clang -O2 -fobjc-arc -c NativeMagnify.m -o "$TASK_CHECK/magnify.o"
clang -O2 -fobjc-arc Tests/NativeGestures/main.m "$TASK_CHECK/magnify.o" "$TASK_CHECK/touch.o" -framework Cocoa -o "$TASK_CHECK/native-gestures"
"$TASK_CHECK/native-gestures"
clang -std=c11 -O2 virtual-microphone/Loopback.c Tests/Microphone/loopback.c -o "$TASK_CHECK/audio-loop"
"$TASK_CHECK/audio-loop"
compile_run scroll NativeScroll.swift Tests/Scroll/main.swift "$TASK_CHECK/magnify.o" "$TASK_CHECK/touch.o" -framework Cocoa
compile_run scroll-response NativeScroll.swift Tests/ScrollResponse/main.swift "$TASK_CHECK/magnify.o" "$TASK_CHECK/touch.o" -framework Cocoa
clang -O2 -c NativeDockSwipe.c -o "$TASK_CHECK/dock.o"
clang -O2 Tests/DockSwipe/main.c "$TASK_CHECK/touch.o" "$TASK_CHECK/dock.o" -framework ApplicationServices -o "$TASK_CHECK/dock"
"$TASK_CHECK/dock"

clang -O2 Tests/Microphone/sources.c virtual-microphone/Loopback.c -framework CoreAudio -framework CoreFoundation -o "$TASK_CHECK/audio-sources"
"$TASK_CHECK/audio-sources"

print 'Core checks passed.'
