import AppKit
import EscribaModel
import Observation

final class RecordingStatusItem: NSObject {
    private let recorder: RecorderModel
    private var item: NSStatusItem?
    private var watch: Task<Void, Never>?

    init(recorder: RecorderModel) {
        self.recorder = recorder
        super.init()
        watch = Task { [weak self, recorder] in
            let changes = Observations { recorder.isRecording ? recorder.clock : nil }
            for await clock in changes {
                self?.show(clock)
            }
        }
    }

    private func show(_ clock: String?) {
        guard let clock else {
            item.map(NSStatusBar.system.removeStatusItem)
            item = nil
            return
        }
        let item = item ?? makeItem()
        item.button?.title = " \(clock)"
        self.item = item
    }

    private func makeItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return item }
        button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Detener la grabación")
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        button.toolTip = "Detener la grabación y transcribirla"
        button.target = self
        button.action = #selector(stop)
        return item
    }

    @objc private func stop() {
        recorder.stop()
    }
}
