import AppKit
import UniformTypeIdentifiers
import PiOSCore

/// Drag-and-drop onto the Whisper bar, the reader or the menu-bar icon (selection.md §6). Accepts file
/// URLs (references: name, UTI and size from metadata, the content never read; an image file becomes a
/// shelf PNG like dropped image data), image data (written as shelf PNGs), promised files (received into `shelf-inbox/`; images become shelf PNGs, other files
/// stay host-owned references), dragged URLs (as text, never fetched) and text (plain, RTF, HTML).
/// A drop never activates pi-os or makes a panel key, so the user's app stays frontmost.
///
/// Wiring: a view registers through `register(_:)` and forwards the dragging calls (`ShelfDropView` does
/// both), or a window is attached with `attach(to:)` and forwards them to its delegate.
@MainActor
public final class ShelfDropTarget: NSObject, NSDraggingDestination, NSWindowDelegate {
    enum Plan: Equatable { case files, images, promises, text, none }

    public nonisolated static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + PasteboardPayload.imageTypes + promiseTypes.map { NSPasteboard.PasteboardType($0) } + PasteboardPayload.textTypes
    }
    nonisolated static var promiseTypes: [String] { NSFilePromiseReceiver.readableDraggedTypes }

    /// Called on the main thread with what a drop produced; promised files arrive later, one call each.
    /// The captures' `ownedFile`s belong to the caller from here on (shelf them or dispose of them).
    public var onCaptures: ([ShelfCapture]) -> Void
    /// Drag-over state, for the accent outline.
    public var onTargeted: ((Bool) -> Void)?
    /// Promises whose reader has not fired by then are abandoned; files arriving later are deleted.
    public var promiseTimeout: TimeInterval = 10
    private let files: ShelfFiles

    public init(files: ShelfFiles, onCaptures: @escaping ([ShelfCapture]) -> Void) {
        self.files = files; self.onCaptures = onCaptures
    }

    public func register(_ view: NSView) { view.registerForDraggedTypes(Self.acceptedTypes) }

    /// Registers a window (for example the status-item button's) and becomes its delegate, which AppKit
    /// forwards window-level dragging calls to. A window that already has a delegate is left alone
    /// (returns false). The window holds its delegate weakly: the caller keeps this target alive.
    @discardableResult
    public func attach(to window: NSWindow) -> Bool {
        guard window.delegate == nil || window.delegate === self else { return false }
        window.registerForDraggedTypes(Self.acceptedTypes)
        window.delegate = self
        return true
    }

    // MARK: NSDraggingDestination

    public func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = Self.operation(for: sender.draggingPasteboard)
        onTargeted?(operation != [])
        return operation
    }

    public func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { Self.operation(for: sender.draggingPasteboard) }

    public func draggingExited(_ sender: NSDraggingInfo?) { onTargeted?(false) }

    public func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { Self.operation(for: sender.draggingPasteboard) != [] }

    /// Promises must be received here (macOS 27 asserts outside prepare/perform/conclude).
    public func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted?(false)
        return accept(sender.draggingPasteboard)
    }

    public func concludeDragOperation(_ sender: NSDraggingInfo?) { onTargeted?(false) }

    // MARK: Conversion

    /// `.copy` for anything the shelf can take; types only, nothing is read while hovering.
    public nonisolated static func operation(for pasteboard: NSPasteboard) -> NSDragOperation {
        plan(Set(pasteboard.shelfTypes)) == .none ? [] : .copy
    }

    /// Files win (Finder also offers names and icons), then image data (a browser image drag also has its
    /// URL), then promises (reading a Mail drag's URL can hang), then text. Concealed content is refused.
    nonisolated static func plan(_ types: Set<String>) -> Plan {
        func has(_ list: [NSPasteboard.PasteboardType]) -> Bool { list.contains { types.contains($0.rawValue) } }
        if PasteboardPolicy.refusal(types: Array(types)) == .concealed { return .none }
        if has([.fileURL]) { return .files }
        if has(PasteboardPayload.imageTypes) { return .images }
        if promiseTypes.contains(where: types.contains) { return .promises }
        if has(PasteboardPayload.textTypes) { return .text }
        return .none
    }

    /// Converts a drop. False when nothing usable was found.
    func accept(_ pasteboard: NSPasteboard) -> Bool {
        switch Self.plan(Set(pasteboard.shelfTypes)) {
        case .none:
            return false
        case .promises:
            guard let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
                  !receivers.isEmpty else { return false }
            return receive(receivers)
        case .files, .images, .text:
            let captures = PasteboardPayload.read(pasteboard, preferImages: true).captures(files: files, origin: .drop, source: nil)
            guard !captures.isEmpty else { return false }
            onCaptures(captures)
            return true
        }
    }

    private final class Batch {
        var open = true
    }

    private func receive(_ receivers: [NSFilePromiseReceiver]) -> Bool {
        guard let directory = try? files.makeInboxBatch() else { return false }
        let batch = Batch()
        let files = self.files
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { [weak self] url, error in
                Task { @MainActor in
                    // Late (after the timeout), failed or orphaned deliveries are deleted, never shelved.
                    // While the drop is open its batch directory stays for the other promised files.
                    guard let self, error == nil, batch.open, let capture = self.receivedCapture(url) else {
                        files.dispose(url.standardizedFileURL.path, keepBatch: batch.open)
                        return
                    }
                    self.onCaptures([capture])
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + promiseTimeout) {
            batch.open = false
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        return true
    }

    /// A received promised file: an image becomes a shelf PNG (the received copy is deleted), anything
    /// else a host-owned file reference deleted with its chip.
    func receivedCapture(_ url: URL) -> ShelfCapture? {
        let file = url.standardizedFileURL
        guard files.isInInbox(file.path) else { return nil }
        let values = try? file.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        if values?.contentType?.conforms(to: .image) == true, values?.isRegularFile == true,
           let size = values?.fileSize, size <= ShelfFiles.maxSourceBytes, ShelfFiles.isRegularFile(file.path),
           let data = try? Data(contentsOf: file), let image = try? files.writeImage(data: data, origin: .drop) {
            // Only the received copy goes: the batch may still be receiving the drop's other files (the
            // timeout or the launch sweep removes it).
            files.dispose(file.path, keepBatch: true)
            return image
        }
        return files.fileCapture(file, origin: .drop, owned: true)
    }
}

/// A container view that takes shelf drops for its area and forwards them to `target`. Put the drop
/// area's content inside it; a subview registered for the same types (a text view) still takes its own.
public final class ShelfDropView: NSView {
    public let target: ShelfDropTarget

    public init(target: ShelfDropTarget, frame: NSRect = .zero) {
        self.target = target
        super.init(frame: frame)
        target.register(self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { target.draggingEntered(sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { target.draggingUpdated(sender) }
    public override func draggingExited(_ sender: NSDraggingInfo?) { target.draggingExited(sender) }
    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { target.prepareForDragOperation(sender) }
    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { target.performDragOperation(sender) }
    public override func concludeDragOperation(_ sender: NSDraggingInfo?) { target.concludeDragOperation(sender) }
}
