#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_dir="${project_dir}/.build/app-bundle"
module_dir="${build_dir}/modules"
verification_dir="${project_dir}/.build/verification"
temporary_root="$(mktemp -d)"
trap 'rm -rf "${temporary_root}"' EXIT

if [[ -n "${SDKROOT:-}" ]]; then
    sdk_path="${SDKROOT}"
else
    swift_version="$(xcrun swiftc --version | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
    default_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    sdk_candidates=("${default_sdk}" /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk)
    sdk_path=""

    for candidate in "${sdk_candidates[@]}"; do
        interface="${candidate}/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
        [[ -f "${interface}" ]] || continue
        sdk_swift_version="$(sed -nE 's@// swift-compiler-version: Apple Swift version ([0-9]+\.[0-9]+).*@\1@p' "${interface}" | head -n 1)"
        if [[ "${sdk_swift_version}" == "${swift_version}" ]]; then
            sdk_path="${candidate}"
            break
        fi
    done

    if [[ -z "${sdk_path}" ]]; then
        print -u2 "No macOS SDK compatible with Swift ${swift_version} was found."
        exit 1
    fi
fi

sdk_interface="${sdk_path}/usr/lib/swift/Swift.swiftmodule/arm64e-apple-macos.swiftinterface"
sdk_swift_version="$(sed -nE 's@// swift-compiler-version: Apple Swift version ([0-9]+\.[0-9]+\.[0-9]+).*@\1@p' "${sdk_interface}" | head -n 1)"
compiler_interface_args=()
if [[ -n "${sdk_swift_version}" ]]; then
    compiler_interface_args=(-interface-compiler-version "${sdk_swift_version}")
fi

"${script_dir}/build-app.sh"
mkdir -p "${verification_dir}"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/core-module-cache" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${verification_dir}/core-module-cache" \
    -sdk "${sdk_path}" \
    "${compiler_interface_args[@]}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Verification/SmokeCheck.swift" \
    "${module_dir}/CaptureCore.o" \
    -o "${verification_dir}/core-smoke"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/audio-module-cache" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${verification_dir}/audio-module-cache" \
    -sdk "${sdk_path}" \
    "${compiler_interface_args[@]}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Verification/AudioChunkSmokeCheck.swift" \
    "${project_dir}/Sources/RecallCapture/AudioChunkWriter.swift" \
    "${module_dir}/CaptureCore.o" \
    -o "${verification_dir}/audio-chunk-smoke"

# Compile the real speech-recognition path without executing it here. Runtime
# execution is intentionally left to the signed app because macOS grants Speech
# Recognition permission per app identity.
env CLANG_MODULE_CACHE_PATH="${verification_dir}/speech-module-cache" xcrun swiftc \
    -parse-as-library \
    -module-cache-path "${verification_dir}/speech-module-cache" \
    -sdk "${sdk_path}" \
    "${compiler_interface_args[@]}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Sources/RecallCapture/SpeechRecognitionEngine.swift" \
    "${project_dir}/Verification/SpeechRecognitionSmokeCheck.swift" \
    -o "${verification_dir}/speech-recognition-smoke"

mkdir -p "${temporary_root}/core" "${temporary_root}/audio" "${temporary_root}/archive"
"${verification_dir}/core-smoke" "${temporary_root}/core"
"${verification_dir}/audio-chunk-smoke" "${temporary_root}/audio"

audio_file="$(find "${temporary_root}/audio" -type f -name '*.caf' -print -quit)"
if [[ -z "${audio_file}" ]]; then
    print -u2 "Audio verification did not produce a CAF chunk."
    exit 1
fi
if ! /usr/bin/afinfo "${audio_file}" | /usr/bin/grep -Eq '1 ch,[[:space:]]+16000 Hz, Int16'; then
    print -u2 "Audio verification produced an unexpected storage format."
    exit 1
fi

ditto -x -k "${project_dir}/.build/RecallCapture.zip" "${temporary_root}/archive"
packaged_app="${temporary_root}/archive/RecallCapture.app"
packaged_plist="${packaged_app}/Contents/Info.plist"
codesign --verify --deep --strict "${packaged_app}"
if [[ "$(/usr/bin/plutil -extract RecallCaptureSigningMode raw "${packaged_plist}")" != "certificate" ]]; then
    print -u2 "Release verification requires certificate signing."
    exit 1
fi
signing_identity="$(/usr/bin/plutil -extract RecallCaptureSigningIdentity raw "${packaged_plist}")"
designated_requirement="$(codesign -d -r- "${packaged_app}" 2>&1 | sed -n 's/^designated => //p')"
if [[ -z "${designated_requirement}" || "${designated_requirement}" == *cdhash* ]]; then
    print -u2 "Packaged app does not have a stable designated requirement."
    exit 1
fi
if codesign -d --verbose=4 "${packaged_app}" 2>&1 | grep -Eq 'flags=.*adhoc'; then
    print -u2 "Packaged app must not use ad-hoc signing."
    exit 1
fi

# Prove that a differently hashed update signed by the same identity still
# satisfies the original build's designated requirement. This is the identity
# continuity used by macOS privacy controls across app updates.
update_app="${temporary_root}/update/RecallCapture.app"
mkdir -p "${temporary_root}/update"
ditto "${packaged_app}" "${update_app}"
original_build="$(/usr/bin/plutil -extract CFBundleVersion raw "${update_app}/Contents/Info.plist")"
/usr/bin/plutil -replace CFBundleVersion -string "$((original_build + 1))" "${update_app}/Contents/Info.plist"
codesign --force --deep --sign "${signing_identity}" "${update_app}"
codesign --verify --deep --strict -R "=${designated_requirement}" "${update_app}"
original_cdhash="$(codesign -d --verbose=4 "${packaged_app}" 2>&1 | sed -n 's/^CDHash=//p')"
update_cdhash="$(codesign -d --verbose=4 "${update_app}" 2>&1 | sed -n 's/^CDHash=//p')"
if [[ -z "${original_cdhash}" || -z "${update_cdhash}" || "${original_cdhash}" == "${update_cdhash}" ]]; then
    print -u2 "Update identity verification did not exercise a different code hash."
    exit 1
fi

if [[ "$(/usr/bin/plutil -extract LSUIElement raw "${packaged_plist}")" != "false" ]]; then
    print -u2 "Packaged app must show a Dock icon."
    exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw "${packaged_plist}")" != "RecallCapture.icns" ]]; then
    print -u2 "Packaged app does not declare the Recall Capture icon."
    exit 1
fi
icon_path="${temporary_root}/archive/RecallCapture.app/Contents/Resources/RecallCapture.icns"
if [[ ! -s "${icon_path}" ]]; then
    print -u2 "Packaged app does not contain a non-empty Recall Capture icon."
    exit 1
fi
/usr/bin/iconutil -c iconset "${icon_path}" -o "${temporary_root}/verified.iconset"
if [[ ! -s "${temporary_root}/verified.iconset/icon_512x512@2x.png" ]]; then
    print -u2 "Packaged icon does not contain the 1024px representation."
    exit 1
fi

print "verification: passed"
print "signing continuity: ${designated_requirement}"
