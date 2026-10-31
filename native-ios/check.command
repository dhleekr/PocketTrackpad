#!/bin/zsh
set -eu
cd "${0:A:h}"
TASK_CACHE="${TMPDIR:-/tmp}/pocket-trackpad-module-cache"
swiftc -module-cache-path "$TASK_CACHE" Sources/GestureEngine.swift Tests/main.swift -o "${TMPDIR:-/tmp}/pocket-trackpad-native-gesture-tests"
"${TMPDIR:-/tmp}/pocket-trackpad-native-gesture-tests"
swiftc -module-cache-path "$TASK_CACHE" ../shared/BLEWire.swift Tests/BLE/main.swift -o "${TMPDIR:-/tmp}/pocket-trackpad-ble-tests"
"${TMPDIR:-/tmp}/pocket-trackpad-ble-tests"
xcodebuild -project PocketTrackpad.xcodeproj -scheme PocketTrackpad -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath "${POCKET_IOS_BUILD_DIR:-build}" CODE_SIGNING_ALLOWED=NO build
