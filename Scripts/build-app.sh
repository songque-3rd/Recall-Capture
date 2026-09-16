#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_dir="${project_dir}/.build/app-bundle"
module_dir="${build_dir}/modules"
module_cache="${build_dir}/module-cache"
app_dir="${project_dir}/.build/RecallCapture.app"
archive_path="${project_dir}/.build/RecallCapture.zip"
staging_dir="$(mktemp -d)"
staged_app_dir="${staging_dir}/RecallCapture.app"
staged_archive="${staging_dir}/RecallCapture.zip"
icon_generator="${staging_dir}/generate-app-icon"
local_signing_identity="Recall Capture Local Signing"
signing_identity="${RECALL_CAPTURE_SIGN_IDENTITY:-}"
allow_ad_hoc="${RECALL_CAPTURE_ALLOW_AD_HOC:-0}"
trap 'rm -rf "${staging_dir}"' EXIT

if [[ -z "${signing_identity}" ]]; then
    if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${local_signing_identity}\""; then
        signing_identity="${local_signing_identity}"
    elif [[ "${allow_ad_hoc}" == "1" ]]; then
        signing_identity="-"
    else
        print -u2 "No stable code-signing identity is available."
        print -u2 "Run ./Scripts/setup-local-signing-identity.sh once, then rebuild."
        print -u2 "For disposable test builds only, set RECALL_CAPTURE_ALLOW_AD_HOC=1."
        exit 1
    fi
fi

if [[ "${signing_identity}" == "-" && "${allow_ad_hoc}" != "1" ]]; then
    print -u2 "Ad-hoc signing must be explicitly enabled with RECALL_CAPTURE_ALLOW_AD_HOC=1."
    exit 1
fi

if [[ "${signing_identity}" != "-" ]] \
    && ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"${signing_identity}\""; then
    print -u2 "Code-signing identity is not available: ${signing_identity}"
    exit 1
fi

if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "Recall Capture v1 requires an Apple Silicon Mac."
    exit 1
fi

if [[ -n "${SDKROOT:-}" ]]; then
    sdk_path="${SDKROOT}"
else
    swift_version="$(xcrun swiftc --version | sed -nE 's/.*Apple Swift version ([0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
    default_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    sdk_candidates=("${default_sdk}" /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk)
    sdk_path=""

    # A partially updated Command Line Tools installation can expose an SDK
    # built by a different Swift version. Pick a matching SDK when available.
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

mkdir -p "${module_dir}" "${module_cache}"
core_sources=("${project_dir}"/Sources/CaptureCore/*.swift)
app_sources=("${project_dir}"/Sources/RecallCapture/*.swift)

env CLANG_MODULE_CACHE_PATH="${module_cache}" xcrun swiftc \
    -parse-as-library \
    -whole-module-optimization \
    -emit-module \
    -emit-object \
    -module-name CaptureCore \
    -emit-module-path "${module_dir}/CaptureCore.swiftmodule" \
    -module-cache-path "${module_cache}" \
    -sdk "${sdk_path}" \
    "${compiler_interface_args[@]}" \
    -target arm64-apple-macos15.0 \
    "${core_sources[@]}" \
    -o "${module_dir}/CaptureCore.o"

mkdir -p "${staged_app_dir}/Contents/MacOS" "${staged_app_dir}/Contents/Resources"
env CLANG_MODULE_CACHE_PATH="${module_cache}" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${module_cache}" \
    -sdk "${sdk_path}" \
    "${compiler_interface_args[@]}" \
    -target arm64-apple-macos15.0 \
    "${app_sources[@]}" \
    "${module_dir}/CaptureCore.o" \
    -o "${staged_app_dir}/Contents/MacOS/RecallCapture"

env CLANG_MODULE_CACHE_PATH="${module_cache}" xcrun swiftc \
    -sdk "${sdk_path}" \
    "${compiler_interface_args[@]}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Scripts/generate-app-icon.swift" \
    -o "${icon_generator}"
"${icon_generator}" "${staged_app_dir}/Contents/Resources/RecallCapture.icns"

cp "${project_dir}/Resources/RecallCapture-Info.plist" "${staged_app_dir}/Contents/Info.plist"
if [[ "${signing_identity}" == "-" ]]; then
    plutil -insert RecallCaptureSigningMode -string "ad-hoc" "${staged_app_dir}/Contents/Info.plist"
else
    plutil -insert RecallCaptureSigningMode -string "certificate" "${staged_app_dir}/Contents/Info.plist"
fi
plutil -insert RecallCaptureSigningIdentity -string "${signing_identity}" "${staged_app_dir}/Contents/Info.plist"
plutil -lint "${staged_app_dir}/Contents/Info.plist"
codesign --force --deep --sign "${signing_identity}" "${staged_app_dir}"
codesign --verify --deep --strict "${staged_app_dir}"
if [[ "${signing_identity}" == "-" ]]; then
    print -u2 "Warning: ad-hoc signing is for local testing; macOS may require permissions again after rebuilding."
else
    designated_requirement="$(codesign -d -r- "${staged_app_dir}" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -z "${designated_requirement}" || "${designated_requirement}" == *cdhash* ]]; then
        print -u2 "Certificate signing did not produce a stable designated requirement."
        exit 1
    fi
fi
ditto -c -k --keepParent "${staged_app_dir}" "${staged_archive}"

# Documents may be File Provider-backed and attach package attributes that block
# signing. Sign in a clean temporary directory, then copy the sealed bundle and
# its portable archive back. RecallCapture.zip is the distributable artifact.
rm -rf "${app_dir}"
ditto --noextattr --norsrc "${staged_app_dir}" "${app_dir}"
# File Provider may add Finder metadata to the copied bundle. It is not
# application data, but codesign treats any such metadata as disallowed.
/usr/bin/xattr -cr "${app_dir}"
codesign --verify --deep --strict "${app_dir}"
cp "${staged_archive}" "${archive_path}"

print "Built: ${app_dir}"
print "Archive: ${archive_path}"
print "Signing identity: ${signing_identity}"
