#!/bin/zsh
set -euo pipefail
script_dir="${0:A:h}"
project_dir="${script_dir:h}"
verification_dir="${project_dir}/.build/ui-verification"
module_dir="${project_dir}/.build/app-bundle/modules"
source "${script_dir}/toolchain.sh"
[[ -f "${module_dir}/CaptureCore.o" ]] || { print -u2 "Run build-app.sh first."; exit 1; }
mkdir -p "${verification_dir}"
python3 - "${project_dir}" "${verification_dir}" <<'PY'
from pathlib import Path
import sys
project, output = map(Path, sys.argv[1:])
source = (project / 'Sources/RecallCapture/RecallCaptureApp.swift').read_text()
assert source.count('@main\nstruct RecallCaptureApp') == 1
source = source.replace('@main\nstruct RecallCaptureApp', 'struct RecallCaptureApp')
source = source.replace('UserDefaults.standard', 'UserDefaults(suiteName: "jp.recallcapture.ui-verification")!')
for name in ['RecordingDestinationStore', 'RecentRecordingStore']:
    source = source.replace(name + '()', name + '(defaults: UserDefaults(suiteName: "jp.recallcapture.ui-verification")!)')
block = '        refreshPermissions()\n        refreshMicrophones()\n        refreshRecoveryCandidates()\n'
assert source.count(block) == 1
source = source.replace(block, '')
source = source.replace('model.refreshPermissions()', '_ = model.permissionSnapshot')
source += '\n' + (project / 'Verification/UIRenderingCheck.swift').read_text()
(output / 'AppUIFixture.swift').write_text(source)
PY
app_sources=("${project_dir}"/Sources/RecallCapture/*.swift)
app_sources=(${app_sources:#*/RecallCaptureApp.swift})
env CLANG_MODULE_CACHE_PATH="${verification_dir}/module-cache" xcrun swiftc \
    -parse-as-library -I "${module_dir}" -module-cache-path "${verification_dir}/module-cache" \
    -sdk "${sdk_path}" -target arm64-apple-macos15.0 \
    "${app_sources[@]}" "${verification_dir}/AppUIFixture.swift" "${module_dir}/CaptureCore.o" \
    -o "${verification_dir}/ui-rendering-check"
"${verification_dir}/ui-rendering-check" "${verification_dir}/renders"
