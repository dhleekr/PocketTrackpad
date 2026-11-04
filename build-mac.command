#!/bin/zsh
set -eu
cd "${0:A:h}"
TASK_OUTPUT="${POCKET_MAC_OUTPUT:-$PWD/build/mac}"
TASK_APP="$TASK_OUTPUT/PocketTrackpad.app"
TASK_BUILD="$TASK_OUTPUT/intermediates"
TASK_DRIVER="$TASK_APP/Contents/Resources/Microphone/PocketTrackpadMicrophone.driver"
mkdir -p "$TASK_DRIVER/Contents/MacOS" "$TASK_DRIVER/Contents/Resources"
TASK_TEST_FLAGS=()
if [[ "${POCKET_LOCAL_TEST:-0}" == "1" ]]; then TASK_TEST_FLAGS=(-DPOCKET_LOCAL_TEST); fi
mkdir -p "$TASK_APP/Contents/MacOS" "$TASK_APP/Contents/Resources" "$TASK_BUILD/AppIcon.iconset"
for TASK_ARCH in arm64 x86_64; do
  TASK_CAPTURE_OBJECT=()
  if [[ "${POCKET_LOCAL_TEST:-0}" == "1" ]]; then
    clang -O2 -arch "$TASK_ARCH" -mmacosx-version-min=13.0 -c Tests/DockSwipe/Capture.c -o "$TASK_BUILD/Capture-$TASK_ARCH.o"
    TASK_CAPTURE_OBJECT=("$TASK_BUILD/Capture-$TASK_ARCH.o")
  fi
  clang -bundle -O2 -arch "$TASK_ARCH" -mmacosx-version-min=13.0 virtual-microphone/vendor/PocketAudio.c virtual-microphone/Loopback.c -framework CoreAudio -framework CoreFoundation -o "$TASK_BUILD/Microphone-$TASK_ARCH"
  clang -O2 -arch "$TASK_ARCH" -mmacosx-version-min=13.0 -fobjc-arc -c NativeMagnify.m -o "$TASK_BUILD/Magnify-$TASK_ARCH.o"
  clang -O2 -arch "$TASK_ARCH" -mmacosx-version-min=13.0 -c vendor/TouchSynthesis/TouchEvents.c -o "$TASK_BUILD/TouchEvents-$TASK_ARCH.o"
  clang -O2 -arch "$TASK_ARCH" -mmacosx-version-min=13.0 -c NativeDockSwipe.c -o "$TASK_BUILD/DockSwipe-$TASK_ARCH.o"
  swiftc -O "${TASK_TEST_FLAGS[@]}" "${TASK_CAPTURE_OBJECT[@]}" -target "$TASK_ARCH-apple-macosx13.0" -module-cache-path "${TMPDIR:-/tmp}/pocket-trackpad-module-cache" Host.swift MacNotice.swift DictationSetup.swift DictationShortcutDiscovery.swift DictationShortcutMonitor.swift MicrophoneInterfaces.swift MacVirtualMicrophone.swift GPTDictationShortcut.swift GPTMicrophoneControl.swift MacMicrophoneHost.swift KeyRepeat.swift MacQuickKeys.swift MacSystemActions.swift ConnectionState.swift CursorBounds.swift native-ios/Sources/PadDiagnostics.swift NativeScroll.swift MotionPlayback.swift BLEHost.swift NativeWiFiHost.swift MacSupport.swift shared/BLEWire.swift shared/SecureLink.swift shared/MicrophoneWire.swift "$TASK_BUILD/Magnify-$TASK_ARCH.o" "$TASK_BUILD/TouchEvents-$TASK_ARCH.o" "$TASK_BUILD/DockSwipe-$TASK_ARCH.o" -o "$TASK_BUILD/PocketTrackpad-$TASK_ARCH" -framework CoreAudio -framework AudioToolbox -framework Cocoa -framework CoreVideo -framework ApplicationServices -framework CoreImage -framework CoreBluetooth -framework Network -framework Security
done
lipo -create "$TASK_BUILD/Microphone-arm64" "$TASK_BUILD/Microphone-x86_64" -output "$TASK_DRIVER/Contents/MacOS/PocketTrackpadMicrophone"
cp virtual-microphone/Info.plist "$TASK_DRIVER/Contents/Info.plist"
cp virtual-microphone/vendor/LICENSE.txt virtual-microphone/vendor/SOURCE.txt "$TASK_DRIVER/Contents/Resources/"
lipo -create "$TASK_BUILD/PocketTrackpad-arm64" "$TASK_BUILD/PocketTrackpad-x86_64" -output "$TASK_APP/Contents/MacOS/PocketTrackpad"
mkdir -p "$TASK_APP/Contents/Resources/ThirdPartyNotices"
cp vendor/TouchSynthesis/LICENSE vendor/TouchSynthesis/SOURCE.txt "$TASK_APP/Contents/Resources/ThirdPartyNotices/"
mkdir -p "$TASK_APP/Contents/Resources/ThirdPartyNotices/DockSwipePayload"
cp vendor/DockSwipePayload/LICENSE vendor/DockSwipePayload/SOURCE.txt "$TASK_APP/Contents/Resources/ThirdPartyNotices/DockSwipePayload/"
cp mac-resources/Info.plist "$TASK_APP/Contents/Info.plist"
cp -R mac-resources/en.lproj mac-resources/ko.lproj "$TASK_APP/Contents/Resources/"
TASK_ICON="$PWD/mac-resources/AppIcon.png"
for TASK_SIZE in 16 32 128 256 512; do
  sips -z "$TASK_SIZE" "$TASK_SIZE" "$TASK_ICON" --out "$TASK_BUILD/AppIcon.iconset/icon_${TASK_SIZE}x${TASK_SIZE}.png" >/dev/null
  TASK_DOUBLE=$(( TASK_SIZE * 2 ))
  sips -z "$TASK_DOUBLE" "$TASK_DOUBLE" "$TASK_ICON" --out "$TASK_BUILD/AppIcon.iconset/icon_${TASK_SIZE}x${TASK_SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$TASK_BUILD/AppIcon.iconset" -o "$TASK_APP/Contents/Resources/AppIcon.icns"
if [[ -n "${POCKET_MAC_SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$POCKET_MAC_SIGN_IDENTITY" "$TASK_DRIVER"
  virtual-microphone/build-installer.command "$TASK_DRIVER" "$TASK_APP/Contents/Resources/Microphone/PocketTrackpadMicrophone.pkg" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
  codesign --force --options runtime --timestamp --sign "$POCKET_MAC_SIGN_IDENTITY" "$TASK_APP"
else
  codesign --force --sign - "$TASK_DRIVER"
  virtual-microphone/build-installer.command "$TASK_DRIVER" "$TASK_APP/Contents/Resources/Microphone/PocketTrackpadMicrophone.pkg" "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_APP/Contents/Info.plist")"
  codesign --force --sign - "$TASK_APP"
  print 'LOCAL CANDIDATE ONLY: Developer ID signing and Apple notarization are still required.'
fi
codesign --verify --deep --strict "$TASK_APP"
print "$TASK_APP"
