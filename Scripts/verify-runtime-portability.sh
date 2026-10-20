#!/bin/zsh
set -euo pipefail

# A newer SDK must not silently raise the minimum supported runtime OS or
# capture dependencies from the build machine's package manager.
autoload -Uz is-at-least
if (( $# == 0 )); then
    print -u2 "Pass the runtime executable and its bundled dynamic libraries."
    exit 1
fi
for runtime_file in "$@"; do
    if [[ "$(lipo -archs "${runtime_file}")" != "arm64" ]]; then
        print -u2 "Runtime must target Apple Silicon: ${runtime_file}"
        exit 1
    fi
    minimum_os="$(xcrun vtool -show-build "${runtime_file}" | awk '$1 == "minos" { print $2; exit }')"
    if [[ -z "${minimum_os}" ]] || ! is-at-least "${minimum_os}" 15.0; then
        print -u2 "Runtime requires macOS ${minimum_os:-unknown}; expected 15.0 or earlier: ${runtime_file}"
        exit 1
    fi
    if otool -L "${runtime_file}" | tail -n +2 | grep -Eq '/opt/homebrew|/usr/local|/private/tmp|/var/folders'; then
        print -u2 "Runtime has a non-portable dependency: ${runtime_file}"
        otool -L "${runtime_file}" >&2
        exit 1
    fi
done
