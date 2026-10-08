import AppKit
import EscribaModel
import Observation
import SwiftUI

final class RecordingPanel {
    private let recorder: RecorderModel
    private let recipeName: (String) -> String
    private var panel: NSPanel?
    private var watch: Task<Void, Never>?

    init(recorder: RecorderModel, recipeName: @escaping (String) -> String) {
        self.recorder = recorder
        self.recipeName = recipeName
        watch = Task { [weak self, recorder] in
            for await recording in Observations({ recorder.isRecording }) {
                self?.show(recording)
            }
        }
    }

    private func show(_ recording: Bool) {
        guard recording else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        guard panel == nil else { return }
        let panel = makePanel(RecordingHUD(recorder: recorder, recipeName: recorder.recipe.map(recipeName)))
        placeAtTop(panel)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func makePanel(_ hud: RecordingHUD) -> NSPanel {
        let panel = FloatingPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let host = NSHostingView(rootView: hud)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        return panel
    }

    private func placeAtTop(_ panel: NSPanel) {
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: screen.midX - panel.frame.width / 2, y: screen.maxY - panel.frame.height - 12))
    }
}

private final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct RecordingHUD: View {
    @Bindable var recorder: RecorderModel
    let recipeName: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "record.circle.fill")
                .font(.title2)
                .foregroundStyle(.red)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 1) {
                Text(recorder.clock)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(recipeName.map { "con «\($0)»" } ?? "Grabando")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 150, alignment: .leading)
            }
            Waveform(levels: recorder.levels, slots: RecorderModel.levelHistory)
                .frame(width: 144, height: 30)
            Button(role: .destructive) {
                recorder.cancel()
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.medium))
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Descartar la grabación")
            Button {
                recorder.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.red, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Detener y transcribir")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .contentShape(.capsule)
        .gesture(WindowDragGesture())
        .glassEffect(.regular, in: .capsule)
        .padding(12)
    }
}

private struct Waveform: View {
    let levels: [Double]
    let slots: Int

    var body: some View {
        Canvas { context, size in
            let step = size.width / CGFloat(slots)
            let bar = max(step * 0.55, 1.5)
            let padded = Array(repeating: 0, count: max(slots - levels.count, 0)) + levels.suffix(slots)
            for (index, level) in padded.enumerated() {
                let height = max(size.height * CGFloat(level), 2)
                let rect = CGRect(
                    x: CGFloat(index) * step + (step - bar) / 2, y: (size.height - height) / 2,
                    width: bar, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(.primary.opacity(0.75)))
            }
        }
    }
}
