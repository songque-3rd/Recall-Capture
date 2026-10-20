#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
artifacts_root="${project_dir}/.artifacts"
target_dir="${artifacts_root}/NemotronDiarization"
source_revision="0f706e43cf1fbc031bad1423e05460d3acaeaa1c"
source_url="https://github.com/NVIDIA/NeMo-Speech.cpp.git"
sentencepiece_revision="17d7580d6407802f85855d2cc9190634e2c95624"
model_revision="f667ed73aee57d40cc39428eb768b4fd87a0a29e"
model_name="Nemotron-3-Diarization.q8_0.gguf"
model_url="https://huggingface.co/nvidia/Nemotron-3-Diarization/resolve/${model_revision}/${model_name}"
model_sha256="08456d9e22cd9a323c0364d98375f3746d6e68507ebb705cd46438c534c7a3a1"
model_size="107012128"
temporary_root="$(mktemp -d)"

mkdir -p "${artifacts_root}"
staging_dir="$(mktemp -d "${artifacts_root}/.NemotronDiarization.XXXXXX")"
trap 'rm -rf "${temporary_root}" "${staging_dir}"' EXIT

if [[ "$(uname -m)" != "arm64" ]]; then
    print -u2 "Nemotron diarization setup requires an Apple Silicon Mac."
    exit 1
fi

for tool in git cmake ninja curl shasum otool lipo xcrun; do
    if ! command -v "${tool}" >/dev/null; then
        print -u2 "Missing build dependency: ${tool}"
        print -u2 "Install CMake and Ninja with: brew install cmake ninja"
        exit 1
    fi
done
sdk_path="${SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
cmake_platform_args=(-DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT="${sdk_path}")

source_dir="${temporary_root}/NeMo-Speech.cpp"
print "Fetching NeMo-Speech.cpp at ${source_revision}..."
git init -q "${source_dir}"
git -C "${source_dir}" remote add origin "${source_url}"
git -C "${source_dir}" fetch --depth 1 origin "${source_revision}"
git -C "${source_dir}" checkout -q --detach FETCH_HEAD
if [[ "$(git -C "${source_dir}" rev-parse HEAD)" != "${source_revision}" ]]; then
    print -u2 "NeMo-Speech.cpp source revision verification failed."
    exit 1
fi
git -C "${source_dir}" submodule update --init --depth 1 ggml

dependency_root="${source_dir}/.deps"
sentencepiece_prefix="${dependency_root}/sentencepiece"
sentencepiece_source="${dependency_root}/sentencepiece-build/source"
sentencepiece_build="${dependency_root}/sentencepiece-build/build"
print "Building SentencePiece at ${sentencepiece_revision} as a static dependency..."
git clone --filter=blob:none --no-checkout \
    https://github.com/google/sentencepiece.git \
    "${sentencepiece_source}"
git -C "${sentencepiece_source}" fetch --depth 1 origin "${sentencepiece_revision}"
git -C "${sentencepiece_source}" checkout -q --detach FETCH_HEAD
if [[ "$(git -C "${sentencepiece_source}" rev-parse HEAD)" != "${sentencepiece_revision}" ]]; then
    print -u2 "SentencePiece source revision verification failed."
    exit 1
fi
cmake -G Ninja -S "${sentencepiece_source}" -B "${sentencepiece_build}" \
    "${cmake_platform_args[@]}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DSPM_BUILD_TEST=OFF \
    -DSPM_ENABLE_SHARED=OFF \
    -DSPM_ENABLE_TCMALLOC=OFF
cmake --build "${sentencepiece_build}" --target sentencepiece-static -j 4
mkdir -p "${sentencepiece_prefix}/lib" "${sentencepiece_prefix}/include"
cp "${sentencepiece_build}/src/libsentencepiece.a" "${sentencepiece_prefix}/lib/"
cp "${sentencepiece_source}/src/sentencepiece_processor.h" "${sentencepiece_prefix}/include/"
sentencepiece_license_dir="${sentencepiece_prefix}/share/licenses/nemo-speech/third_party/sentencepiece"
mkdir -p "${sentencepiece_license_dir}"
cp "${sentencepiece_source}/LICENSE" "${sentencepiece_license_dir}/LICENSE"
cp "${sentencepiece_source}/third_party/absl/LICENSE" "${sentencepiece_license_dir}/absl-LICENSE"
cp "${sentencepiece_source}/third_party/darts_clone/LICENSE" "${sentencepiece_license_dir}/darts-clone-LICENSE"
cp "${sentencepiece_source}/third_party/protobuf-lite/LICENSE" "${sentencepiece_license_dir}/protobuf-lite-LICENSE"
if [[ ! -f "${sentencepiece_prefix}/lib/libsentencepiece.a" ]]; then
    print -u2 "The SentencePiece build did not produce libsentencepiece.a."
    exit 1
fi

print "Building the pinned CPU diarization runtime..."
(
    cd "${source_dir}"
    ./scripts/configure.sh cpu-diar \
        "${cmake_platform_args[@]}" \
        -DGGML_NATIVE=OFF \
        -DNEMO_SPEECH_DEPENDENCY_PREFIX="${dependency_root}" \
        -DSENTENCEPIECE_LIB="${sentencepiece_prefix}/lib/libsentencepiece.a" \
        -DSENTENCEPIECE_INCLUDE_DIR="${sentencepiece_prefix}/include"
    cmake --build --preset cpu-diar
    cmake --install build/cpu-diar --prefix "${staging_dir}/runtime"
)
mkdir -p "${staging_dir}/runtime/share/licenses/nemo-speech/third_party"
cp -R "${sentencepiece_license_dir}" \
    "${staging_dir}/runtime/share/licenses/nemo-speech/third_party/sentencepiece"

runtime_binary="${staging_dir}/runtime/bin/nemo-speech"
if [[ ! -x "${runtime_binary}" ]]; then
    print -u2 "The NeMo-Speech.cpp build did not produce bin/nemo-speech."
    exit 1
fi

# Reject accidental build-machine dependencies before the runtime is bundled.
runtime_files=("${runtime_binary}" "${staging_dir}"/runtime/lib/*.dylib(N))
"${script_dir}/verify-runtime-portability.sh" "${runtime_files[@]}"

print "Downloading the pinned Nemotron-3-Diarization model..."
mkdir -p "${staging_dir}/models"
downloaded_model="${temporary_root}/${model_name}"
curl --fail --location --retry 3 --output "${downloaded_model}" "${model_url}"
actual_model_size="$(stat -f '%z' "${downloaded_model}")"
actual_model_sha256="$(shasum -a 256 "${downloaded_model}" | awk '{print $1}')"
if [[ "${actual_model_size}" != "${model_size}" || "${actual_model_sha256}" != "${model_sha256}" ]]; then
    print -u2 "Nemotron model size or checksum does not match the pinned artifact."
    exit 1
fi
cp "${downloaded_model}" "${staging_dir}/models/${model_name}"
cp "${project_dir}/Resources/NemotronDiarization-NOTICE.txt" "${staging_dir}/NOTICE.txt"
cp "${project_dir}/Resources/NemotronDiarization-SOURCE_VERSION.txt" "${staging_dir}/SOURCE_VERSION.txt"
mkdir -p "${staging_dir}/licenses"
cp "${project_dir}/Resources/Licenses/OpenMDW-1.1.txt" "${staging_dir}/licenses/"

if [[ -e "${target_dir}" ]]; then
    backup_dir="${artifacts_root}/.NemotronDiarization.backup.$$"
    mv "${target_dir}" "${backup_dir}"
    if mv "${staging_dir}" "${target_dir}"; then
        rm -rf "${backup_dir}"
    else
        mv "${backup_dir}" "${target_dir}"
        exit 1
    fi
else
    mv "${staging_dir}" "${target_dir}"
fi

"${target_dir}/runtime/bin/nemo-speech" --version
print "Prepared: ${target_dir}"
