# KeeLocker

KeeLocker is a native macOS password manager interface prototype built with Swift and SwiftUI. This first version uses in-memory sample data and intentionally contains no KDBX, encryption, sync, cloud, file-system or browser-extension integration.

## Requirements

- macOS 14 or newer
- Xcode 16 or newer

## Run

Open `KeeLocker.xcodeproj` in Xcode and run the `KeeLocker` scheme, or build from Terminal:

```sh
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS' build
```

The app follows the system appearance by default. Light, dark and system modes are available from KeeLocker Settings.

## Tests

Run the macOS unit and UI tests from Terminal:

```sh
xcodebuild -project KeeLocker.xcodeproj -scheme KeeLocker -destination 'platform=macOS' test
```
