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
diarization_artifacts="${project_dir}/.artifacts/NemotronDiarization"
diarization_binary="${diarization_artifacts}/runtime/bin/nemo-speech"
diarization_model="${diarization_artifacts}/models/Nemotron-3-Diarization.q8_0.gguf"
local_signing_identity="Recall Capture Local Signing"
signing_identity="${RECALL_CAPTURE_SIGN_IDENTITY:-}"
allow_ad_hoc="${RECALL_CAPTURE_ALLOW_AD_HOC:-0}"
distribution="${RECALL_CAPTURE_DISTRIBUTION:-0}"
trap 'rm -rf "${staging_dir}"' EXIT

if [[ "${distribution}" != "0" && "${distribution}" != "1" ]]; then
    print -u2 "RECALL_CAPTURE_DISTRIBUTION must be 0 or 1."
    exit 1
fi
if [[ "${distribution}" == "1" && "${signing_identity}" != 'Developer ID Application: '* ]]; then
    print -u2 "Distribution requires an explicit RECALL_CAPTURE_SIGN_IDENTITY (Developer ID Application)."
    print -u2 "Local and ad-hoc identities cannot be used for distribution. See RELEASING.md."
    exit 1
fi

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

source "${script_dir}/toolchain.sh"

# Reject incomplete or substituted model assets before spending time compiling.
if [[ ! -x "${diarization_binary}" || ! -s "${diarization_model}" ]]; then
    print -u2 "Run ./Scripts/setup-nemotron-diarization.sh first (runtime/model missing)."
    exit 1
fi
if [[ "$(stat -f%z "${diarization_model}")" != "107012128" || \
      "$(shasum -a 256 "${diarization_model}" | awk '{print $1}')" != "08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1" ]]; then
    print -u2 "Nemotron model does not match the pinned artifact. Re-run setup."
    exit 1
fi
if ! cmp -s "${diarization_artifacts}/SOURCE_VERSION.txt" "${project_dir}/Resources/NemotronDiarization-SOURCE_VERSION.txt"; then
    print -u2 "Runtime source metadata differs from the pinned versions. Re-run setup."
    exit 1
fi
"${script_dir}/verify-runtime-portability.sh" "${diarization_binary}" "${diarization_artifacts}"/runtime/lib/*.dylib(N)

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
    -target arm64-apple-macos15.0 \
    "${core_sources[@]}" \
    -o "${module_dir}/CaptureCore.o"

mkdir -p "${staged_app_dir}/Contents/MacOS" "${staged_app_dir}/Contents/Resources"
env CLANG_MODULE_CACHE_PATH="${module_cache}" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${module_cache}" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${app_sources[@]}" \
    "${module_dir}/CaptureCore.o" \
    -o "${staged_app_dir}/Contents/MacOS/RecallCapture"

env CLANG_MODULE_CACHE_PATH="${module_cache}" xcrun swiftc \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Scripts/generate-app-icon.swift" \
    -o "${icon_generator}"
"${icon_generator}" "${staged_app_dir}/Contents/Resources/RecallCapture.icns"

cp -R \
    "${diarization_artifacts}" \
    "${staged_app_dir}/Contents/Resources/NemotronDiarization"
# Documents may be File Provider-backed and attach provenance metadata to each
# generated artifact. ditto treats that protected metadata as a copy failure;
# cp can copy the data, after which the staging copy can be sanitized safely.
/usr/bin/xattr -cr "${staged_app_dir}/Contents/Resources/NemotronDiarization"
chmod +x "${staged_app_dir}/Contents/Resources/NemotronDiarization/runtime/bin/nemo-speech"

cp "${project_dir}/Resources/RecallCapture-Info.plist" "${staged_app_dir}/Contents/Info.plist"
cp "${project_dir}/Resources/UsageGuide.md" "${staged_app_dir}/Contents/Resources/UsageGuide.md"
licenses_dir="${staged_app_dir}/Contents/Resources/Licenses"
mkdir -p "${licenses_dir}" "${staged_app_dir}/Contents/Resources/NemotronDiarization/licenses"
cp "${project_dir}/LICENSE" "${licenses_dir}/RecallCapture-MIT.txt"
cp "${project_dir}/THIRD_PARTY_NOTICES.md" "${licenses_dir}/THIRD_PARTY_NOTICES.md"
cp "${project_dir}/Resources/Licenses/OpenMDW-1.1.txt" "${staged_app_dir}/Contents/Resources/NemotronDiarization/licenses/"
cp "${project_dir}/Resources/NemotronDiarization-NOTICE.txt" "${staged_app_dir}/Contents/Resources/NemotronDiarization/NOTICE.txt"
if [[ ! -s "${staged_app_dir}/Contents/Resources/NemotronDiarization/runtime/share/licenses/nemo-speech/LICENSE" ]]; then
    print -u2 "Runtime license notices are missing. Re-run setup."
    exit 1
fi
plutil -insert RecallCaptureDistribution -bool "${distribution}" "${staged_app_dir}/Contents/Info.plist"
if [[ "${signing_identity}" == "-" ]]; then
    plutil -insert RecallCaptureSigningMode -string "ad-hoc" "${staged_app_dir}/Contents/Info.plist"
else
    plutil -insert RecallCaptureSigningMode -string "certificate" "${staged_app_dir}/Contents/Info.plist"
fi
plutil -insert RecallCaptureSigningIdentity -string "${signing_identity}" "${staged_app_dir}/Contents/Info.plist"
plutil -lint "${staged_app_dir}/Contents/Info.plist"
# Sign real nested Mach-O files before sealing the containing bundle. --deep is
# used only for verification, never as a substitute for nested-code signing.
signing_args=(--force --sign "${signing_identity}")
if [[ "${distribution}" == "1" ]]; then
    signing_args+=(--timestamp)
else
    signing_args+=(--timestamp=none)
fi
nested_signing_args=("${signing_args[@]}")
if [[ "${distribution}" == "1" ]]; then
    nested_signing_args+=(--options runtime)
fi
# Local/ad-hoc signatures have no Apple Team ID. Keep hardened library
# validation on the helper limited to distribution, where all code shares a
# Developer ID team. No library-validation exception entitlement is needed.
while IFS= read -r -d $'\0' runtime_file; do
    if /usr/bin/file -b "${runtime_file}" | grep -q 'Mach-O'; then
        codesign "${nested_signing_args[@]}" "${runtime_file}"
    fi
done < <(find "${staged_app_dir}/Contents/Resources/NemotronDiarization/runtime" -type f -print0)
codesign "${signing_args[@]}" --options runtime --entitlements "${project_dir}/Resources/RecallCapture.entitlements" "${staged_app_dir}"
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
# its portable archive back. Public releases require the separate notarization step.
cp "${staged_archive}" "${archive_path}"
rm -rf "${app_dir}"
ditto --noextattr --norsrc "${staged_app_dir}" "${app_dir}"
# File Provider may add Finder metadata to the copied bundle. It is not
# application data, but codesign treats any such metadata as disallowed.
/usr/bin/xattr -cr "${app_dir}"
if codesign --verify --deep --strict "${app_dir}"; then
    print "Built: ${app_dir}"
else
    # Some File Provider implementations immediately add a protected package
    # attribute that cannot be removed in place. Do not leave an artifact that
    # appears usable but no longer passes strict signature verification.
    rm -rf "${app_dir}"
    print -u2 "Warning: File Provider metadata prevented an unpacked app copy."
    print -u2 "Use the signed archive and extract it outside the synced folder."
fi

print "Archive: ${archive_path}"
print "Signing identity: ${signing_identity}"
