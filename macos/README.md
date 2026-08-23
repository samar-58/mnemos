# macOS app

The first prototype milestone is a native SwiftUI menu-bar application with a dashboard window.

Generate and open the Xcode project from the repository root:

```sh
xcodegen generate
open macos/Mnemos.xcodeproj
```

The application currently changes UI state only. It does not request Accessibility permission or record any activity yet.
