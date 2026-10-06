import SwiftUI

struct VolumeHUDView: View {
    let snapshot: VolumeSnapshot

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: glyphName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30)

            SegmentBar(value: snapshot.value, dimmed: snapshot.isMuted)
        }
        .padding(.horizontal, 22)
        .frame(width: 220, height: 56)
    }

    private var glyphName: String {
        if snapshot.isMuted || snapshot.value <= 0.001 {
            return "speaker.slash.fill"
        }
        switch snapshot.value {
        case ..<0.25: return "speaker.fill"
        case ..<0.5: return "speaker.wave.1.fill"
        case ..<0.75: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

private struct SegmentBar: View {
    let value: Float
    let dimmed: Bool

    private let segmentCount = 16

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< segmentCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color(for: index))
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 22)
    }

    private func color(for index: Int) -> Color {
        let isFilled = Float(index) < value * Float(segmentCount)
        guard isFilled else { return .white.opacity(0.15) }
        return dimmed ? .white.opacity(0.45) : .white
    }
}

#Preview {
    VStack(spacing: 12) {
        VolumeHUDView(snapshot: VolumeSnapshot(value: 0.6, isMuted: false))
        VolumeHUDView(snapshot: VolumeSnapshot(value: 0.6, isMuted: true))
        VolumeHUDView(snapshot: VolumeSnapshot(value: 0, isMuted: false))
        VolumeHUDView(snapshot: VolumeSnapshot(value: 1, isMuted: false))
    }
    .padding()
    .background(.black)
}
