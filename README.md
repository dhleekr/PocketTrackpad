<p align="left"><img src="docs/assets/icon.png" width="72" alt="PocketTrackpad icon"></p>

# PocketTrackpad

### Your Mac. In your hand.

An iPhone controller and a native Mac receiver. Move, click, scroll, zoom, and switch desktops over Wi-Fi or Bluetooth. A nearly empty touch surface, with the controls you need within reach.

[Website](https://pocket-trackpad.doohyun726675.chatgpt.site/) · [Download for Mac](https://pocket-trackpad.doohyun726675.chatgpt.site/downloads/PocketTrackpad-Mac-1.1.1.zip) · [Setup & support](https://pocket-trackpad.doohyun726675.chatgpt.site/support.html) · [Privacy](https://pocket-trackpad.doohyun726675.chatgpt.site/privacy.html)

![PocketTrackpad identity: Your Mac. In your hand.](docs/assets/cover.png)

## Get started

1. Install the iPhone controller and the separate Mac receiver. The iPhone release is currently awaiting App Store review; it is not publicly available yet.
2. Open the Mac receiver. Allow it in **System Settings → Privacy & Security → Accessibility**.
3. Scan the Mac QR code from the iPhone app. Choose **Wi-Fi** on the same local network, or **Bluetooth** nearby.
4. Keep the iPhone app open and start moving. The Mac window hides after connection; reopening the Mac app shows its connection status and QR again. The iPhone Settings sheet stays open until you dismiss it.

The Mac download is signed with Developer ID and notarized by Apple. The source build uses local ad hoc signing unless you supply your own signing identity.

The first connection screen explains that both apps are required and links directly to the Mac download and setup guide.

## A familiar set of gestures

| Touch | Action |
| :--- | :--- |
| One finger | Move the pointer; tap to click; double-tap to double-click |
| Double-tap, hold the second tap | Drag immediately; lift to release |
| Two fingers | Momentum scrolling; page history and pinch zoom in supporting apps |
| Two-finger tap | Right-click |
| Three-finger swipe | Mission Control, App Exposé, or desktop switching |

Adjust cursor speed, natural scrolling, double-tap timing, press delay, and haptic behavior. Rotate the surface with the rotation button. The lock button defers system edge gestures; hold it to unlock. It cannot completely disable iOS Home or Control Center gestures.

Pinch, page navigation, and system gestures depend on the receiving app and macOS settings. This is a software controller, not a replacement for every Apple trackpad hardware feature. On iPhones without pressure sensing, press-to-click uses hold duration rather than measured force. Haptics and timing are configurable.

[View the controller settings](docs/assets/settings.png).

## Two apps, one local connection

| Component | Requirement | Role |
| :--- | :--- | :--- |
| iPhone controller | iOS 17 or later | Multitouch input, gestures, haptics, connection settings |
| Mac receiver | macOS 13 or later; Apple silicon or Intel | Authenticated transport, pointer and gesture delivery |

Input travels directly between your devices. There is no developer-operated input relay, account system, advertising SDK, or analytics SDK. Treat the pairing QR as a control key and keep it private.

Wi-Fi uses Network.framework with TLS and a QR-derived pre-shared key. Bluetooth uses CoreBluetooth, system link encryption, and a QR-key challenge. The phone is the Bluetooth peripheral; the Mac discovers and connects to it. See [Architecture](docs/architecture.md) for the input pipeline and implementation limits.

## Build from source

You need a Mac with Xcode, its command-line tools, and the required Apple SDKs. The apps do not require Python, Node, or third-party packages at runtime.

### Mac

```sh
./build.command
open build/mac/PocketTrackpad.app
```

The build produces a universal `arm64` / `x86_64` app. Local builds do not overwrite the retained notarized release. To sign your own distribution build:

```sh
POCKET_MAC_SIGN_IDENTITY="Developer ID Application: Your Name (YOURTEAMID)" \
  ./build.command
```

Notarization is a separate Apple distribution step. A locally rebuilt app may need its own Accessibility permission; the downloaded release and a local build are different signatures.

### iPhone

Open `native-ios/PocketTrackpad.xcodeproj` in Xcode. Select your development team and a unique bundle identifier in **Signing & Capabilities**, then run on your device. The public project does not include the maintainer’s signing profile or private keys. Simulator builds do not need signing:

```sh
xcodebuild -project native-ios/PocketTrackpad.xcodeproj \
  -scheme PocketTrackpad -configuration Debug \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build
```

### Checks

```sh
./scripts/check-core.command
./native-ios/check.command
```

The first command exercises gesture recognition, wire validation, motion playback, scroll delivery, and serialization without controlling the desktop. The iPhone check also builds the unsigned device target. These checks do not establish end-to-end radio latency or physical iPhone gesture feel. Manual desktop probes live under `Tests/PageNavigation`, `Tests/PageSwipe`, and `Tests/CursorDelivery`; they are intentionally excluded from the automatic checks.

## Repository map

```text
native-ios/       iPhone app, Xcode project, gesture tests
shared/           Framing, secure connection setup, Bluetooth wire format
Host.swift        Native Mac receiver and input application
ConnectionState.swift
MotionPlayback.swift
NativeScroll.swift
NativeMagnify.m
NativeDockSwipe.c
Tests/            Focused Mac and transport checks
mac-resources/    Mac metadata and English/Korean localization
vendor/           Gesture serialization dependencies and notices
website/          Static product, support, and privacy pages
scripts/          Source-only validation
```

The website directory contains the public page source. Published binary downloads are release artifacts, not source files in Git. Historical prototypes, timing recordings, QR captures, certificates, upload credentials, caches, and distribution archives are excluded.

## Implementation notes

macOS continuous desktop gestures and some pinch/page transitions use undocumented gesture serialization. These adapters can be affected by macOS changes. They are isolated in the native gesture modules; the Mac receiver is distributed directly, not through the Mac App Store. No claim is made that these interfaces are supported by Apple.

The identity combines a touch surface and a pointer in a single mark. Black type, open space, and an acid-green field carry the same visual language across the icon, website, and documentation. Brand files are in [docs/assets](docs/assets).

## Support and contribution

Report reproducible bugs through GitHub Issues. Include your iOS/macOS versions, connection type, expected behavior, and observed behavior. Do not post pairing QR codes, private device logs, Apple credentials, or signing files. For security-sensitive reports, email [dhleekr7@gmail.com](mailto:dhleekr7@gmail.com). See [CONTRIBUTING.md](CONTRIBUTING.md).

## Copyright and third-party notices

Copyright © 2026 Doohyun Lee. All rights reserved for original source and brand assets; this public repository does not grant an additional license to them. Third-party code retains its own license. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
