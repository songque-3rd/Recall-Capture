import CaptureCore
import SwiftUI

struct AudioInputMeterView: View {
    let track: AudioTrack
    let snapshot: AudioInputSnapshot

    var body: some View {
        let fresh = snapshot.isFresh(at: .now)
        let level = fresh ? snapshot.level : AudioSignalLevel(rms: 0, peak: 0)
        HStack(spacing: 10) {
            Text(track == .system ? "PC音声" : track == .microphone ? "マイク" : "音声")
                .frame(width: 55, alignment: .leading)
            ProgressView(value: level.meterValue)
                .tint(level.isClipping ? .orange : .green)
                .frame(maxWidth: .infinity)
            Text(!fresh ? "入力待ち" : level.isClipping ? "音割れ注意" : level.hasSound ? "入力あり" : "静音")
                .foregroundStyle(level.isClipping ? Color.orange : .secondary)
                .frame(width: 78, alignment: .trailing)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
    }
}
