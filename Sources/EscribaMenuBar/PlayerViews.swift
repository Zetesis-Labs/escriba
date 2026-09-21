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

            Text(clockStamp(player.currentTime))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0, thenPlay: player.isPlaying) }),
                in: 0...max(player.duration, 0.01))

            Text(clockStamp(player.duration))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

}

struct KaraokeView: View {
    let transcript: Transcript
    let position: PlaybackPosition?
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            if transcript.isSegmented {
                ForEach(Array(transcript.segments.enumerated()), id: \.offset) { index, segment in
                    turn(segment, at: index)
                }
            } else {
                Text(transcript.text)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func turn(_ segment: TranscriptSegment, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let speaker = segment.speaker, transcript.startsNewSpeaker(at: index) {
                Text(speaker)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
            }

            if segment.words.isEmpty || position?.segment != index {
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
                                position?.word == wordIndex
                                    ? Color.accentColor.opacity(0.35) : .clear,
                                in: RoundedRectangle(cornerRadius: 3))
                            .onTapGesture { onSeek(word.start) }
                    }
                }
            }
        }
    }

}

struct FlowLayout: Layout {
    struct Cache {
        var width: CGFloat = .nan
        var sizes: [CGSize] = []
        var frames: [CGRect] = []
        var total: CGSize = .zero
    }

    var spacing: CGFloat = 6

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = Cache()
    }

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity, cache: &cache)
        return cache.total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        arrange(subviews, width: bounds.width, cache: &cache)
        for (frame, subview) in zip(cache.frames, subviews) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat, cache: inout Cache) {
        guard cache.width != width || cache.frames.count != subviews.count else { return }
        if cache.sizes.count != subviews.count {
            cache.sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        }

        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for size in cache.sizes {
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }

        cache.width = width
        cache.frames = frames
        cache.total = CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }
}
