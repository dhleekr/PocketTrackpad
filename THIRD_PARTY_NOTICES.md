# Third-party notices

## TouchSynthesis

Files under `vendor/TouchSynthesis` are retained from Hammerspoon commit `23e387e2805a9890066366e0ac96c71b27f0cfd5`. TouchSynthesis originated with Nathan Vander Wilt, Calf Trail Software (2010). The retained Hammerspoon material is MIT-licensed. Its original license and provenance are included alongside the source.

## Dock swipe payload helpers

Files under `vendor/DockSwipePayload` adapt serialization helpers from `joshuarli/iss` commit `493b008f2ea8e9215877c39700e8ea3add800e97`. The original ISC license and provenance are included alongside the source. No event interception or space-switching implementation from that project is included.

Distribution builds copy both notices into the Mac application's resources. These licenses apply to their respective third-party files, not automatically to the original PocketTrackpad source or brand assets.

## Virtual microphone driver

The Mac microphone plug-in adapts Apple’s Creating an Audio Server Driver Plug-in sample. The original MIT license and source URL are retained under `virtual-microphone/vendor` and copied into the signed driver bundle. The audio loopback implementation is separate, bounded, and memory-only. The iPhone target does not bundle a speech-recognition SDK or model.
