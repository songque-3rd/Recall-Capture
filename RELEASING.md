# macOS release procedure

This procedure prepares a macOS 15+ Apple Silicon ZIP. Publishing source, uploading a release or changing repository visibility is a separate maintainer decision. A local test archive is not a public release.

## Prerequisites

- Xcode 26+ / Swift 6.2+ and macOS 26+ SDK, Git, CMake and Ninja
- A valid **Developer ID Application** certificate and private key in the signing Mac's keychain
- Apple Developer notarization credentials saved in a `notarytool` keychain profile
- Current MIT source license and complete third-party license notices

Create the Developer ID certificate through Apple Developer / Xcode. Save notarization credentials using `xcrun notarytool store-credentials` interactively or your secret-management workflow. Never put passwords, `.p12` files or private keys in Git, shell history examples, CI logs or the archive. Consumers do not need these credentials or a self-signed certificate.

## Build and verify

Run from the repository root, replacing the identity with the actual certificate name:

```sh
./Scripts/setup-nemotron-diarization.sh
export RECALL_CAPTURE_DISTRIBUTION=1
export RECALL_CAPTURE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
./Scripts/verify.sh
./Scripts/verify-ui.sh
```

Distribution mode rejects local/ad-hoc identities. The app and nested runtime use hardened runtime, and the main executable receives only the audio-input entitlement. The model hash and bundled notices are checked. Verification also checks a differently hashed update against the original designated requirement. Maintain the bundle identifier and Developer ID team across updates; macOS ultimately decides whether permission reapproval is required.

Inspect the UI renders and manually verify an explicitly authorized recording on a clean Mac: installation through Gatekeeper, microphone, screen and speech prompts, refusal/recovery, offline transcription after installing language assets, system/microphone tracks, and transcript output. Automatic checks do not prove real meeting accuracy or all macOS versions.

## Notarize and package

The following command **uploads the built app to Apple** using the existing profile. Run only after confirming the intended build and upload authorization:

```sh
./Scripts/notarize-release.sh 'recall-capture-notary'
```

The script requires Developer ID distribution metadata, hardened runtime and the audio-input entitlement; submits with `notarytool --wait`; requires `Accepted`; staples and validates the ticket; then runs Gatekeeper assessment. It produces `.build/release/RecallCapture-VERSION-macos-arm64.zip` and a `.sha256` file from the stapled app. A failed notarization cannot produce a new release archive. The notary result is retained locally for diagnosis. Do not publish `.build/RecallCapture.zip`, which is the pre-notarization input.

Verify the final ZIP on another Mac before publishing it with the source version, checksum, installation instructions and third-party notices. Give each release a unique app version/build number and matching source tag. The CI workflow verifies source changes with ad-hoc test signing; it has no signing secrets and never publishes binaries.

References: [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution), [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [audio-input entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input).
