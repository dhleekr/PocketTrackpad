# iPhone controller

Open `PocketTrackpad.xcodeproj` in Xcode. Select your own team and a unique bundle identifier before installing on a device. The deployment target is iOS 17.

The controller uses UIKit for touch sampling, SwiftUI for settings, CoreBluetooth for Bluetooth, and Network.framework for Wi-Fi. English and Korean strings are bundled in `Sources/en.lproj` and `Sources/ko.lproj`.

`GestureEngine.swift` owns gesture state. `NativePadView.swift` forwards multitouch samples and hosts the native lock, rotate, and Settings buttons. `TrackpadClient.swift` coordinates transport and saved preferences. The Wi-Fi and Bluetooth clients preserve control boundaries while coalescing continuous movement.

Run `./check.command` for gesture/wire tests and an unsigned device build. See the [root README](../README.md) for setup, requirements, architecture, and release limitations.

DEBUG-only routes support simulator UI verification. They are excluded from the Release configuration. Public Settings do not expose timing recording or measurement controls.
