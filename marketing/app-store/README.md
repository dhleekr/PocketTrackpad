# PocketTrackpad App Store artwork

Four screenshots per language, English (`en`) and Korean (`ko`), at 1320 × 2868 pixels. The `medium/` folders contain 1206 × 2622 exports for the current Dynamic Island medium display slot. The sequence introduces the trackpad, gesture settings, customizable keys, and connection setup. Each frame uses an unaltered screenshot captured from the current 1.4.23 source in the iPhone 17 Pro Max simulator. The outer device frame and surrounding copy are presentation artwork.

The images show existing functionality. They do not claim physical Force Click support, guaranteed input rates, or universal compatibility with third-party dictation apps. Both the iPhone app and the free Mac companion are required.

Regenerate on macOS from the repository root:

```sh
swift marketing/app-store/render.swift
```

`source/` contains the captured screens. `overview.jpg` is a proof sheet, not an App Store upload. The renderer also creates the website social sharing image.

Apple screenshot specification: https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
