#!/bin/zsh
set -euo pipefail
umask 077

identity_name="Recall Capture Local Signing"
keychain_path="$(security default-keychain -d user | sed -E 's/^[[:space:]]*"(.*)"[[:space:]]*$/\1/')"
temporary_dir="$(mktemp -d)"
certificate_path="${temporary_dir}/RecallCaptureLocalSigning.cer"
private_key_path="${temporary_dir}/RecallCaptureLocalSigning.key"
archive_path="${temporary_dir}/RecallCaptureLocalSigning.p12"
archive_password="$(uuidgen)$(uuidgen)"
trap 'rm -rf "${temporary_dir}"' EXIT

has_valid_identity() {
    security find-identity -v -p codesigning "${keychain_path}" 2>/dev/null \
        | grep -Fq "\"${identity_name}\""
}

if has_valid_identity; then
    print "Signing identity already available: ${identity_name}"
    exit 0
fi

# A previous interrupted setup may have imported the identity before adding
# trust. Reuse that certificate rather than creating another one with the same
# name. If its private key is missing, the final identity check fails closed.
if security find-certificate -c "${identity_name}" -p "${keychain_path}" > "${certificate_path}" 2>/dev/null; then
    print "Found an existing certificate; adding user trust."
else
    /usr/bin/openssl req \
        -x509 \
        -newkey rsa:3072 \
        -sha256 \
        -nodes \
        -days 3650 \
        -subj "/C=JP/O=Recall Capture/CN=${identity_name}" \
        -addext "basicConstraints=critical,CA:FALSE" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" \
        -keyout "${private_key_path}" \
        -out "${certificate_path}"

    /usr/bin/openssl pkcs12 \
        -export \
        -inkey "${private_key_path}" \
        -in "${certificate_path}" \
        -name "${identity_name}" \
        -passout "pass:${archive_password}" \
        -out "${archive_path}"

    security import "${archive_path}" \
        -k "${keychain_path}" \
        -P "${archive_password}" \
        -T /usr/bin/codesign
fi

print "macOS may ask for authentication to trust the local signing certificate."
security add-trusted-cert -r trustRoot -p codeSign -k "${keychain_path}" "${certificate_path}"

if ! has_valid_identity; then
    print -u2 "The certificate is present but is not a usable code-signing identity."
    print -u2 "Remove the incomplete '${identity_name}' certificate from Keychain Access, then run this script again."
    exit 1
fi

print "Created signing identity: ${identity_name}"
print "On the first build, choose 'Always Allow' if macOS asks whether codesign may use its private key."
