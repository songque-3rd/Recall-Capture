#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
build_dir="${project_dir}/.build/app-bundle"
module_dir="${build_dir}/modules"
verification_dir="${project_dir}/.build/verification"
temporary_root="$(mktemp -d)"
trap 'rm -rf "${temporary_root}"' EXIT

source "${script_dir}/toolchain.sh"

"${script_dir}/build-app.sh"
mkdir -p "${verification_dir}"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/permission-module-cache" xcrun swiftc \
    -parse-as-library \
    -module-cache-path "${verification_dir}/permission-module-cache" \
    -sdk "${sdk_path}" -target arm64-apple-macos15.0 \
    "${project_dir}/Sources/RecallCapture/CapturePermissions.swift" \
    "${project_dir}/Verification/CapturePermissionCheck.swift" \
    -o "${verification_dir}/capture-permission-check"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/core-module-cache" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${verification_dir}/core-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Verification/SmokeCheck.swift" \
    "${module_dir}/CaptureCore.o" \
    -o "${verification_dir}/core-smoke"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/audio-module-cache" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${verification_dir}/audio-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Verification/AudioChunkSmokeCheck.swift" \
    "${project_dir}/Sources/RecallCapture/AudioChunkWriter.swift" \
    "${project_dir}/Sources/RecallCapture/AudioInputMeter.swift" \
    "${module_dir}/CaptureCore.o" \
    -o "${verification_dir}/audio-chunk-smoke"

# Compile the real speech-recognition path without executing it here. Runtime
# execution is intentionally left to the signed app because macOS grants Speech
# Recognition permission per app identity.
env CLANG_MODULE_CACHE_PATH="${verification_dir}/speech-module-cache" xcrun swiftc \
    -parse-as-library \
    -I "${module_dir}" \
    -module-cache-path "${verification_dir}/speech-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Sources/RecallCapture/SpeechRecognitionEngine.swift" \
    "${project_dir}/Verification/SpeechRecognitionSmokeCheck.swift" \
    "${module_dir}/CaptureCore.o" \
    -o "${verification_dir}/speech-recognition-smoke"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/core-module-cache" xcrun swiftc \
    -parse-as-library -I "${module_dir}" \
    -module-cache-path "${verification_dir}/core-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Verification/OutputQualityCheck.swift" \
    "${module_dir}/CaptureCore.o" -o "${verification_dir}/output-quality-check"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/core-module-cache" xcrun swiftc \
    -parse-as-library -I "${module_dir}" \
    -module-cache-path "${verification_dir}/core-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Verification/TranscriptAssemblyCheck.swift" \
    "${module_dir}/CaptureCore.o" -o "${verification_dir}/transcript-assembly-check"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/speech-module-cache" xcrun swiftc \
    -parse-as-library -I "${module_dir}" \
    -module-cache-path "${verification_dir}/speech-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Sources/RecallCapture/SpeechRecognitionEngine.swift" \
    "${project_dir}/Sources/RecallCapture/SpeakerDiarizationEngine.swift" \
    "${project_dir}/Sources/RecallCapture/PostProcessingCoordinator.swift" \
    "${project_dir}/Verification/PostProcessingRecoveryCheck.swift" \
    "${module_dir}/CaptureCore.o" -o "${verification_dir}/postprocessing-recovery-check"

env CLANG_MODULE_CACHE_PATH="${verification_dir}/audio-module-cache" xcrun swiftc \
    -parse-as-library -I "${module_dir}" \
    -module-cache-path "${verification_dir}/audio-module-cache" \
    -sdk "${sdk_path}" \
    -target arm64-apple-macos15.0 \
    "${project_dir}/Sources/RecallCapture/SpeakerDiarizationEngine.swift" \
    "${project_dir}/Verification/SpeakerDiarizationEngineCheck.swift" \
    "${module_dir}/CaptureCore.o" -o "${verification_dir}/speaker-diarization-engine-check"

mkdir -p "${temporary_root}/core" "${temporary_root}/audio" "${temporary_root}/archive"
"${verification_dir}/capture-permission-check"
"${verification_dir}/core-smoke" "${temporary_root}/core"
"${verification_dir}/output-quality-check" "${temporary_root}/quality"
"${verification_dir}/transcript-assembly-check"
"${verification_dir}/postprocessing-recovery-check" "${temporary_root}/recovery"
"${verification_dir}/audio-chunk-smoke" "${temporary_root}/audio"
"${verification_dir}/speaker-diarization-engine-check" "${temporary_root}/diarization"

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
packaged_diarization="${packaged_app}/Contents/Resources/NemotronDiarization"
packaged_nemo_speech="${packaged_diarization}/runtime/bin/nemo-speech"
packaged_model="${packaged_diarization}/models/Nemotron-3-Diarization.q8_0.gguf"
packaged_source_version="${packaged_diarization}/SOURCE_VERSION.txt"
codesign --verify --deep --strict "${packaged_app}"
if [[ ! -s "${packaged_app}/Contents/Resources/UsageGuide.md" ]]; then
    print -u2 "Packaged app is missing the user guide."
    exit 1
fi
license_files=(
    "${packaged_app}/Contents/Resources/Licenses/RecallCapture-MIT.txt"
    "${packaged_app}/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
    "${packaged_diarization}/licenses/OpenMDW-1.1.txt"
    "${packaged_diarization}/NOTICE.txt"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/LICENSE"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/NOTICE"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/THIRD_PARTY_NOTICES.md"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/third_party/ggml/LICENSE"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/third_party/sentencepiece/LICENSE"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/third_party/sentencepiece/absl-LICENSE"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/third_party/sentencepiece/darts-clone-LICENSE"
    "${packaged_diarization}/runtime/share/licenses/nemo-speech/third_party/sentencepiece/protobuf-lite-LICENSE"
)
for license_file in "${license_files[@]}"; do
    [[ -s "${license_file}" ]] || { print -u2 "Packaged license is missing: ${license_file}"; exit 1; }
done
if [[ ! -x "${packaged_nemo_speech}" || ! -s "${packaged_model}" || ! -s "${packaged_source_version}" ]]; then
    print -u2 "Packaged app is missing the Nemotron diarization runtime or model."
    exit 1
fi
if ! grep -Fxq 'NeMo-Speech.cpp commit 0f706e43cf1fbc031bad1423e05460d3acaeaa1c' "${packaged_source_version}" || \
   ! grep -Fxq 'CMake preset cpu-diar' "${packaged_source_version}" || \
   ! grep -Fxq 'SentencePiece commit 17d7580d6407802f85855d2cc9190634e2c95624 (static)' "${packaged_source_version}" || \
   ! grep -Fxq 'Nemotron-3-Diarization revision f667ed73aee57d40cc39428eb768b4fd87a0a29e' "${packaged_source_version}"; then
    print -u2 "Packaged Nemotron source metadata does not match the pinned revisions."
    exit 1
fi
expected_model_sha256="08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1"
actual_model_sha256="$(shasum -a 256 "${packaged_model}" | awk '{print $1}')"
if [[ "${actual_model_sha256}" != "${expected_model_sha256}" ]]; then
    print -u2 "Packaged Nemotron model checksum does not match the pinned artifact."
    exit 1
fi
"${packaged_nemo_speech}" --version >/dev/null
runtime_files=("${packaged_nemo_speech}" "${packaged_diarization}"/runtime/lib/*.dylib(N))
"${script_dir}/verify-runtime-portability.sh" "${runtime_files[@]}"
signing_mode="$(/usr/bin/plutil -extract RecallCaptureSigningMode raw "${packaged_plist}")"
signing_identity="$(/usr/bin/plutil -extract RecallCaptureSigningIdentity raw "${packaged_plist}")"
signing_details="$(codesign -d --verbose=4 "${packaged_app}" 2>&1)"
distribution="$(/usr/bin/plutil -extract RecallCaptureDistribution raw "${packaged_plist}")"
expected_distribution=false
[[ "${RECALL_CAPTURE_DISTRIBUTION:-0}" == "1" ]] && expected_distribution=true
if [[ "${distribution}" != "${expected_distribution}" || "${signing_details}" != *'runtime)'* ]]; then
    print -u2 "Unexpected distribution metadata or missing hardened runtime."
    exit 1
fi
codesign -d --entitlements :- "${packaged_app}" > "${temporary_root}/entitlements.plist" 2>/dev/null
python3 - "${temporary_root}/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
if entitlements != {'com.apple.security.device.audio-input': True}:
    raise SystemExit('Unexpected app entitlements; expected only audio input.')
PY
if [[ "${distribution}" == "true" && ( "${signing_details}" != *'Authority=Developer ID Application: '* || "${signing_details}" != *'Timestamp='* ) ]]; then
    print -u2 "Distribution requires a timestamped Developer ID signature."
    exit 1
fi
if [[ "${distribution}" == "true" ]]; then
    helper_details="$(codesign -d --verbose=4 "${packaged_nemo_speech}" 2>&1)"
    if [[ "${helper_details}" != *'runtime)'* || "${helper_details}" != *'Timestamp='* ]]; then
        print -u2 "The distribution helper must use timestamped hardened runtime."
        exit 1
    fi
fi
designated_requirement=""
if [[ "${signing_mode}" == "ad-hoc" ]]; then
    if [[ "${RECALL_CAPTURE_ALLOW_AD_HOC:-0}" != "1" || "${signing_identity}" != "-" || "${distribution}" == "true" ]]; then
        print -u2 "Ad-hoc verification requires explicit local-test authorization."
        exit 1
    fi
    if [[ "${signing_details}" != *'flags=0x2(adhoc)'* && "${signing_details}" != *'Signature=adhoc'* ]]; then
        print -u2 "Packaged app does not report the expected ad-hoc signature."
        exit 1
    fi
else
    if [[ "${signing_mode}" != "certificate" ]]; then
        print -u2 "Release verification requires certificate signing."
        exit 1
    fi
    designated_requirement="$(codesign -d -r- "${packaged_app}" 2>&1 | sed -n 's/^designated => //p')"
    if [[ -z "${designated_requirement}" || "${designated_requirement}" == *cdhash* ]]; then
        print -u2 "Packaged app does not have a stable designated requirement."
        exit 1
    fi
    if [[ "${signing_details}" == *'flags=0x2(adhoc)'* || "${signing_details}" == *'Signature=adhoc'* ]]; then
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
    codesign --force --sign "${signing_identity}" --options runtime --timestamp=none \
        --entitlements "${project_dir}/Resources/RecallCapture.entitlements" "${update_app}"
    codesign --verify --deep --strict -R "=${designated_requirement}" "${update_app}"
    original_cdhash="$(codesign -d --verbose=4 "${packaged_app}" 2>&1 | sed -n 's/^CDHash=//p')"
    update_cdhash="$(codesign -d --verbose=4 "${update_app}" 2>&1 | sed -n 's/^CDHash=//p')"
    if [[ -z "${original_cdhash}" || -z "${update_cdhash}" || "${original_cdhash}" == "${update_cdhash}" ]]; then
        print -u2 "Update identity verification did not exercise a different code hash."
        exit 1
    fi
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
if [[ -n "${designated_requirement}" ]]; then
    print "signing continuity: ${designated_requirement}"
else
    print "signing: verified ad-hoc test build"
fi
