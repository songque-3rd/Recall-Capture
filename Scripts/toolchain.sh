#!/bin/zsh
# Shared by the build and verification entry points; uses the selected Xcode/CLT.
if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "Recall Capture requires an Apple Silicon Mac."
    exit 1
fi
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
swift_version="$(xcrun swiftc --version | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
swift_parts=("${(@s:.:)swift_version}")
sdk_version="$(plutil -extract Version raw "${sdk_path}/SDKSettings.plist")"
sdk_parts=("${(@s:.:)sdk_version}")
if [[ -z "${swift_version}" ]] || (( swift_parts[1] < 6 || (swift_parts[1] == 6 && swift_parts[2] < 2) || sdk_parts[1] < 26 )); then
    print -u2 "Use Swift 6.2+ and the macOS 26+ SDK (Xcode 26+ or matching Command Line Tools)."
    print -u2 "Selected Swift: ${swift_version}; SDK: ${sdk_version}. Check xcode-select or DEVELOPER_DIR."
    exit 1
fi
