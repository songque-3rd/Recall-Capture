# Security and privacy

## Authorization boundary

Recall Capture relies on macOS privacy controls (TCC) and code signing. It has no server, login, API token or administrator helper. It never modifies the TCC database or grants itself access.

| Permission | Purpose | Required when |
| --- | --- | --- |
| Microphone | Record the selected input device | Both recording modes |
| Screen / system audio capture | List meeting windows and capture online-meeting PC audio with ScreenCaptureKit; no video is saved | Online recording or explicitly loading meeting windows |
| Speech recognition | Convert recordings into text using Apple's on-device recognizer | Before starting either recording mode, or when resuming recognition |
| Notifications | Stop-time warnings and extension actions | Optional; refusal does not block recording |

Opening settings and reading status do not request permission. Recording actions and explicitly loading meeting windows request unrequested access. A denied or restricted microphone/speech permission sends the user to macOS settings instead of prompting again. Screen preflight returning false cannot distinguish unrequested from denied access, and the UI states that access is unconfirmed. macOS may require restarting the app after changes. Permissions and model/language availability are separate checks.

Speech recognition always requires on-device support; no cloud-recognition fallback is allowed. Apple may need a network connection to install language assets. The diarization model runs locally. The app has no external AI API, analytics or account authentication. Audio, transcript and recovery files remain in the selected folder. A cloud-synced folder can upload those files under the sync provider's settings; local processing does not disable that sync. Stored recordings are not additionally encrypted by the app and are not deleted automatically.

## Signing and distribution

Public builds require an explicitly selected **Developer ID Application** identity, hardened runtime, secure timestamps and Apple's notarization. Only the audio-input entitlement is enabled: no JIT, unsigned executable memory, debugger entitlement or disabled library validation. Nested executable code is signed before the app is sealed. Gatekeeper verification occurs after notarization and stapling; see [RELEASING.md](RELEASING.md).

Local test builds keep hardened runtime on the app, but not on the bundled diarization helper: local/ad-hoc signatures lack the Apple Team ID required by hardened library validation. This exception is limited to non-distribution builds and adds no library-validation entitlement. Public builds harden both executables.

The signed distribution flag disables the developer environment variables that replace the diarization executable or model. Distribution assets come from the sealed app bundle. Model downloads use a pinned revision, expected size and SHA-256, and runtime source revisions and license texts are recorded. These checks protect against accidental substitutions; maintainers must still review pinned upstream code.

Self-signed local certificates are an optional developer convenience for stable app identity on one Mac. They are not public-distribution trust. The setup script creates a code-signing leaf certificate and trusts it only for code signing in that user's login keychain; run it only if that local trust is desired. Ad-hoc builds require explicit opt-in and may lose privacy permission continuity after rebuilding. The build never silently falls back to ad-hoc signing. Existing TCC permissions are still controlled by macOS and may need reapproval after switching signing identities.

## Reporting

Use the repository's private vulnerability reporting / security advisory channel when available. Do not post recordings, exploit details involving private data, certificates or credentials in a public issue. If private reporting is unavailable, open a minimal issue requesting a private reporting route, without sensitive details. At present only the current source tree is maintained; no security support is promised for older binaries.
