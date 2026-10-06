import SwiftUI

struct VolumeHUDView: View {
    let snapshot: VolumeSnapshot

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: glyphName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26)

            SegmentBar(value: snapshot.value, dimmed: snapshot.isMuted)
        }
        .padding(.horizontal, 16)
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
    private let segmentWidth: CGFloat = 7.5
    private let segmentHeight: CGFloat = 22
    private let segmentSpacing: CGFloat = 2
    private let cornerRadius: CGFloat = 1.5

    var body: some View {
        HStack(spacing: segmentSpacing) {
            ForEach(0 ..< segmentCount, id: \.self) { index in
                segment(at: index)
            }
        }
        .frame(height: segmentHeight)
    }

    private func segment(at index: Int) -> some View {
        let fill = fillFraction(at: index)
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(.white.opacity(0.15))
                .frame(width: segmentWidth, height: segmentHeight)

            if fill > 0 {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(dimmed ? .white.opacity(0.45) : .white)
                    .frame(width: segmentWidth * fill, height: segmentHeight)
            }
        }
        .frame(width: segmentWidth, height: segmentHeight)
    }

    private func fillFraction(at index: Int) -> CGFloat {
        guard !dimmed else { return 0 }
        let barStart = Float(index) / Float(segmentCount)
        let barEnd = Float(index + 1) / Float(segmentCount)
        if value >= barEnd {
            return 1
        }
        if value <= barStart {
            return 0
        }
        let positionInBar = (value - barStart) / (barEnd - barStart)
        return CGFloat((positionInBar * 4).rounded() / 4)
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
