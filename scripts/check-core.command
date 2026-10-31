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
compile_run gestures native-ios/Sources/GestureEngine.swift native-ios/Tests/main.swift
compile_run wire shared/BLEWire.swift native-ios/Tests/BLE/main.swift
compile_run motion MotionPlayback.swift Tests/Motion/main.swift -framework CoreVideo
compile_run flow shared/BLEWire.swift Tests/BLEFlow/main.swift
clang -O2 -c vendor/TouchSynthesis/TouchEvents.c -o "$TASK_CHECK/touch.o"
clang -O2 -fobjc-arc -c NativeMagnify.m -o "$TASK_CHECK/magnify.o"
compile_run scroll NativeScroll.swift Tests/Scroll/main.swift "$TASK_CHECK/magnify.o" "$TASK_CHECK/touch.o" -framework Cocoa
clang -O2 -c NativeDockSwipe.c -o "$TASK_CHECK/dock.o"
clang -O2 Tests/DockSwipe/main.c "$TASK_CHECK/touch.o" "$TASK_CHECK/dock.o" -framework ApplicationServices -o "$TASK_CHECK/dock"
"$TASK_CHECK/dock"
print 'Core checks passed.'
