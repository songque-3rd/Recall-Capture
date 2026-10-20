# Third-party components

Recall Capture's original source code is licensed under [MIT](LICENSE). This does not relicense the following components or Apple's operating-system frameworks.

| Component | Version / source | License |
| --- | --- | --- |
| NeMo-Speech.cpp CPU runtime | commit `0f706e43cf1fbc031bad1423e05460d3acaeaa1c`, [upstream](https://github.com/NVIDIA/NeMo-Speech.cpp) | Apache-2.0; upstream NOTICE and third-party notices retained |
| Nemotron 3 Diarization model, Q8_0 GGUF | revision `f667ed73aee57d40cc39428eb768b4fd87a0a29e`, [model card](https://huggingface.co/nvidia/Nemotron-3-Diarization/tree/f667ed73aee57d40cc39428eb768b4fd87a0a29e) | [OpenMDW-1.1](Resources/Licenses/OpenMDW-1.1.txt) |
| SentencePiece, linked statically | commit `17d7580d6407802f85855d2cc9190634e2c95624`, [upstream](https://github.com/google/sentencepiece) | Apache-2.0; bundled dependency licenses retained |
| ggml and runtime dependencies | pinned by the runtime's Git submodules | See the bundled upstream third-party notices and individual license texts |

The setup script downloads these components separately; generated models and binaries are not stored in Git. The model is an independently licensed work, not MIT source code. Review its license when redistributing the model or a modified version.

The app bundle includes:

- `Contents/Resources/Licenses/RecallCapture-MIT.txt` and `THIRD_PARTY_NOTICES.md`
- `Contents/Resources/NemotronDiarization/NOTICE.txt`, `SOURCE_VERSION.txt`, and `licenses/OpenMDW-1.1.txt`
- `Contents/Resources/NemotronDiarization/runtime/share/licenses/nemo-speech/`, including the runtime LICENSE, NOTICE, THIRD_PARTY_NOTICES and the full ggml, SentencePiece, Abseil, darts-clone and protobuf-lite license texts

Apple Speech, ScreenCaptureKit, AVFoundation and other Apple frameworks are supplied by macOS. Apple manages the speech assets; this repository does not redistribute them. Apple Intelligence is not required. The app icon is generated from this repository's drawing code.
