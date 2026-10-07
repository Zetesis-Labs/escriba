import Foundation
import Observation
import EscribaCore
import EscribaEngine

@Observable
public final class RecipeProjectModel {
    public enum Phase: Equatable, Sendable {
        case idle
        case preparing
        case building
        case ready
        case failed(String)
    }

    public private(set) var folder: URL?
    public private(set) var report: RecipeBuildReport?
    public private(set) var phase: Phase = .idle

    private let prepare: @Sendable () async throws -> Void
    private let create: @Sendable (URL) async throws -> Void
    private let rebuild: @Sendable (URL) async throws -> RecipeBuildReport
    private let watcher: FolderWatcher
    private let debounce: Duration
    private var watch: FolderWatch?
    private var pendingChange: Task<Void, Never>?
    private var building: Task<Void, Never>?

    public init(
        prepare: @escaping @Sendable () async throws -> Void,
        create: @escaping @Sendable (URL) async throws -> Void,
        rebuild: @escaping @Sendable (URL) async throws -> RecipeBuildReport,
        watcher: @escaping FolderWatcher,
        debounce: Duration = .milliseconds(300)
    ) {
        self.prepare = prepare
        self.create = create
        self.rebuild = rebuild
        self.watcher = watcher
        self.debounce = debounce
    }

    public func open(_ folder: URL) async {
        close()
        self.folder = folder
        phase = .preparing
        do {
            try await prepare()
        } catch {
            phase = .failed("no se pudo preparar el compilador de recetas: \(error.localizedDescription)")
            return
        }
        do {
            try await create(folder)
        } catch {
            phase = .failed("no se pudo crear el proyecto en \(folder.lastPathComponent): \(error.localizedDescription)")
            return
        }
        await build()
        watch = watcher(folder) { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    public func close() {
        watch?.stop()
        watch = nil
        pendingChange?.cancel()
        pendingChange = nil
    }

    public func refresh() async {
        await build()
    }

    private func changed() {
        pendingChange?.cancel()
        pendingChange = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.build()
        }
    }

    private func build() async {
        let previous = building
        let task = Task {
            await previous?.value
            await self.buildNow()
        }
        building = task
        await task.value
    }

    private func buildNow() async {
        guard let folder else { return }
        phase = .building
        do {
            report = try await rebuild(folder)
            phase = .ready
        } catch {
            phase = .failed("no se pudo compilar \(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
