import EscribaModel
import EscribaCore
import SwiftUI

struct PlayerBar: View {
    let player: PlayerModel

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { player.toggle() }) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)

            Text(timestamp(player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0, thenPlay: player.isPlaying) }),
                in: 0...max(player.duration, 0.01))

            Text(timestamp(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func timestamp(_ time: TimeInterval) -> String {
        let whole = Int(time.rounded(.down))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

struct KaraokeView: View {
    let transcript: Transcript
    let position: PlaybackPosition?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                turn(segment, at: index)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func turn(_ segment: TranscriptSegment, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker = segment.speaker, speaker != speakerBefore(index) {
                Text(speaker)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            if segment.words.isEmpty {
                Text(segment.text)
                    .padding(.horizontal, 2)
                    .background(
                        position?.segment == index ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 3))
                    .onTapGesture { onSeek(segment.start) }
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(Array(segment.words.enumerated()), id: \.offset) { wordIndex, word in
                        Text(word.text.trimmingCharacters(in: .whitespaces))
                            .padding(.horizontal, 2)
                            .background(
                                isCurrent(index, wordIndex)
                                    ? Color.accentColor.opacity(0.35) : .clear,
                                in: RoundedRectangle(cornerRadius: 3))
                            .onTapGesture { onSeek(word.start) }
                    }
                }
            }
        }
    }

    private func speakerBefore(_ index: Int) -> String? {
        index > 0 ? transcript.segments[index - 1].speaker : nil
    }

    private func isCurrent(_ segment: Int, _ word: Int) -> Bool {
        position == PlaybackPosition(segment: segment, word: word)
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        for (frame, subview) in zip(arrange(subviews, width: bounds.width).frames, subviews) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(
        _ subviews: Subviews, width: CGFloat
    ) -> (frames: [CGRect], size: CGSize) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        let usedWidth = width.isFinite ? width : x
        return (frames, CGSize(width: usedWidth, height: y + rowHeight))
    }
}
