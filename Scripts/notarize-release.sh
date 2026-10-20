#!/bin/zsh
set -euo pipefail

# Explicit invocation uploads the app to Apple. This script never publishes it.
if (( $# != 1 )) || [[ -z "$1" ]]; then
    print -u2 "Usage: ./Scripts/notarize-release.sh KEYCHAIN_PROFILE"
    exit 1
fi
notary_profile="$1"
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
input_archive="${project_dir}/.build/RecallCapture.zip"
release_dir="${project_dir}/.build/release"
staging_dir="$(mktemp -d)"
trap 'rm -rf "${staging_dir}"' EXIT
[[ -s "${input_archive}" ]] || { print -u2 "Build and verify a Developer ID distribution first."; exit 1; }
# Verify and upload the same immutable snapshot even if another build starts.
cp "${input_archive}" "${staging_dir}/submission.zip"
ditto -x -k "${staging_dir}/submission.zip" "${staging_dir}"
app="${staging_dir}/RecallCapture.app"
plist="${app}/Contents/Info.plist"
if [[ "$(plutil -extract RecallCaptureDistribution raw "${plist}")" != "true" || \
      "$(plutil -extract RecallCaptureSigningMode raw "${plist}")" != "certificate" ]]; then
    print -u2 "Notarization requires a Developer ID distribution build. See RELEASING.md."
    exit 1
fi
codesign --verify --deep --strict "${app}"
details="$(codesign -d --verbose=4 "${app}" 2>&1)"
if [[ "${details}" != *'Authority=Developer ID Application: '* || \
      "${details}" != *'runtime)'* || "${details}" != *'Timestamp='* ]]; then
    print -u2 "Expected a timestamped Developer ID signature with hardened runtime."
    exit 1
fi
codesign -d --entitlements :- "${app}" > "${staging_dir}/entitlements.plist" 2>/dev/null
python3 - "${staging_dir}/entitlements.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as source:
    entitlements = plistlib.load(source)
if entitlements != {'com.apple.security.device.audio-input': True}:
    raise SystemExit('Unexpected release entitlements; refusing upload.')
PY
version="$(plutil -extract CFBundleShortVersionString raw "${plist}")"
if [[ ! "${version}" =~ '^[0-9]+(\.[0-9]+)*$' ]]; then
    print -u2 "Release version must contain only digits and dots."
    exit 1
fi
release_name="RecallCapture-${version}-macos-arm64.zip"
mkdir -p "${release_dir}"
if [[ -e "${release_dir}/${release_name}" || -e "${release_dir}/${release_name}.sha256" ]]; then
    print -u2 "Release output already exists; use a new version or archive the existing output."
    exit 1
fi

print "Submitting ${version} to Apple notarization."
receipt="${release_dir}/notary-${version}-$(date -u +%Y%m%dT%H%M%SZ).json"
xcrun notarytool submit "${staging_dir}/submission.zip" --keychain-profile "${notary_profile}" \
    --wait --output-format json > "${receipt}"
if [[ "$(plutil -extract status raw "${receipt}")" != "Accepted" ]]; then
    print -u2 "Notarization was not accepted. Inspect ${receipt}; no release ZIP was created."
    exit 1
fi
xcrun stapler staple "${app}"
xcrun stapler validate "${app}"
codesign --verify --deep --strict "${app}"
spctl --assess --type execute --verbose=2 "${app}"
ditto -c -k --keepParent "${app}" "${staging_dir}/${release_name}"
# Hash the final stapled archive, not the submitted pre-notarization input.
(cd "${staging_dir}" && shasum -a 256 "${release_name}" > "${release_name}.sha256")
cp "${staging_dir}/${release_name}" "${release_dir}/${release_name}"
cp "${staging_dir}/${release_name}.sha256" "${release_dir}/${release_name}.sha256"
print "Release: ${release_dir}/${release_name}"
print "SHA-256: ${release_dir}/${release_name}.sha256"
