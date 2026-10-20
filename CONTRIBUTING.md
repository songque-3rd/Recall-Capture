# Contributing

Changes and bug reports are welcome. Explain the expected behavior, actual behavior, macOS version and app version. Use synthetic examples; do not attach meeting recordings, transcripts, personal paths, signing certificates, API keys or other private data.

## Development

Use an Apple Silicon Mac with macOS 15+, Swift 6.2+ and the macOS 26+ SDK (Xcode 26+ or matching Command Line Tools). `xcode-select` / `DEVELOPER_DIR` selects the toolchain. Setup also needs Git, CMake and Ninja. No account, API key or Homebrew dependency is required by the installed application.

```sh
./Scripts/setup-nemotron-diarization.sh
RECALL_CAPTURE_SIGN_IDENTITY=- RECALL_CAPTURE_ALLOW_AD_HOC=1 ./Scripts/verify.sh
./Scripts/verify-ui.sh
```

The ad-hoc build is for disposable tests. For repeated recording on your own Mac, see the optional local certificate instructions in README. Public artifacts must follow [RELEASING.md](RELEASING.md).

Verification uses generated audio and injected authorization results. It does not request microphone, screen or speech access. Speech recognition is compiled but not executed by the automatic checks. UI checks render fixtures without starting recording. Real recognition and recording require a separately authorized manual check in the signed application.

Keep CaptureCore independent of AppKit and recording devices. Changes to authorization must preserve explicit user actions, truthful unknown states, and denial handling without repeated prompts. Keep offline recognition mandatory; do not add a silent cloud fallback. Add focused checks for substantive behavior changes. Describe validation and any remaining platform limitations in the pull request.

Dependencies, model versions and license changes require updating the pinned metadata, checksums and notices together. Do not commit `.build`, `.artifacts`, signing materials or real recordings. See [SECURITY.md](SECURITY.md) for reporting vulnerabilities.
