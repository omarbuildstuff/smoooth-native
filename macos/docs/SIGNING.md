# Code Signing & Notarization

The app builds **unsigned / ad-hoc** by default (runs locally on the build machine). To
distribute it to other Macs without Gatekeeper warnings, sign with a **Developer ID
Application** certificate and notarize. This is the single remaining pre-distribution step;
everything else is in place (entitlements file + Info.plist usage strings).

## Prerequisites

- Apple Developer Program membership.
- A **Developer ID Application** certificate in your login keychain
  (`security find-identity -v -p codesigning` to list).
- An app-specific password (or `notarytool` keychain profile) for your Apple ID.

## 1. Enable signing in the project

In `macos/Smoooth/project.yml`, under `targets.Smoooth.settings.base`, replace the ad-hoc
settings with:

```yaml
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "Developer ID Application"
    DEVELOPMENT_TEAM: "YOURTEAMID"
    ENABLE_HARDENED_RUNTIME: YES
    CODE_SIGN_ENTITLEMENTS: Supporting/Smoooth.entitlements
```

Then `xcodegen generate`.

## 2. Build a signed Release

```bash
cd macos/Smoooth
xcodebuild -project Smoooth.xcodeproj -scheme Smoooth -configuration Release \
  -destination 'platform=macOS' clean build
```

The product is at
`~/Library/Developer/Xcode/DerivedData/Smoooth-*/Build/Products/Release/Smoooth.app`.

## 3. Notarize

```bash
APP=path/to/Smoooth.app
ditto -c -k --keepParent "$APP" Smoooth.zip
xcrun notarytool submit Smoooth.zip \
  --apple-id "you@example.com" --team-id "YOURTEAMID" \
  --password "app-specific-password" --wait
xcrun stapler staple "$APP"
spctl -a -vvv "$APP"   # should report: accepted, source=Notarized Developer ID
```

## 4. (Optional) DMG

```bash
hdiutil create -volname Smoooth -srcfolder "$APP" -ov -format UDZO Smoooth.dmg
# sign + notarize the .dmg the same way if distributing the disk image
```

## Notes

- **App Sandbox is intentionally disabled.** Click capture uses a `CGEventTap`, which the
  sandbox forbids. The hardened runtime (required for notarization) is compatible.
- Screen Recording is granted by the user via TCC at first run (driven by the
  `NSScreenCaptureUsageDescription` string already in `Info.plist`), not by an entitlement.
- The camera/microphone/audio-input entitlements in `Smoooth.entitlements` are only enforced
  under the hardened runtime; they pair with the Info.plist usage strings.
