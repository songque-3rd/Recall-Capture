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
codesign --verify --deep --strict "${temporary_root}/archive/RecallCapture.app"
if [[ "$(/usr/bin/plutil -extract LSUIElement raw "${temporary_root}/archive/RecallCapture.app/Contents/Info.plist")" != "false" ]]; then
    print -u2 "Packaged app must show a Dock icon."
    exit 1
fi
if [[ "$(/usr/bin/plutil -extract CFBundleIconFile raw "${temporary_root}/archive/RecallCapture.app/Contents/Info.plist")" != "RecallCapture.icns" ]]; then
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
