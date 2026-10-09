import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PiOSCore

/// Host-owned shelf files in the captures directory (protocol.md "Screenshot transfer"): normalized
/// `shelf-<uuid>.png` images (≤ 1280 px long edge, ≤ 1 MP, sRGB, EXIF orientation baked in, 0600) and
/// the `shelf-inbox/` directory that receives promised files. It deletes only these files; a user's own
/// file is never touched. Nothing here logs a path or a name.
public struct ShelfFiles: Equatable {
    public let capturesDir: URL
    public var inbox: URL { capturesDir.appendingPathComponent("shelf-inbox", isDirectory: true) }
    /// Largest encoded source image that is decoded (pasteboard, drop or region raw file).
    public static let maxSourceBytes = PasteboardPolicy.maxReadBytes
    /// Largest decoded source image, in pixels (an 8K × 8K image).
    public static let maxSourcePixels = 64 * 1024 * 1024
    public static let maxPNGBytes = 8 * 1024 * 1024

    public init(capturesDir: URL) { self.capturesDir = capturesDir.standardizedFileURL }

    /// A fresh `shelf-<uuid>.png` path directly inside the captures directory.
    public func newImageURL() -> URL { capturesDir.appendingPathComponent("shelf-\(UUID().uuidString).png") }

    /// Decodes, orients, downscales and writes a new shelf PNG. `contentKey` is the PNG's SHA-256.
    public func writeImage(data: Data, origin: AttachmentOrigin, source: AttachmentSource? = nil) throws -> ShelfCapture {
        guard data.count <= Self.maxSourceBytes,
              let imageSource = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DomainError("image_failed", "The image is too large or unreadable")
        }
        return try write(Self.normalized(imageSource), to: newImageURL(), origin: origin, source: source)
    }

    /// Re-encodes a raw image that is already a shelf file (a region grab) in place.
    public func normalizeImage(at url: URL, origin: AttachmentOrigin, source: AttachmentSource? = nil) throws -> ShelfCapture {
        guard isOwnedImage(url.path), Self.isRegularFile(url.path),
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size <= Self.maxSourceBytes,
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw DomainError("image_failed", "The captured image is too large or unreadable")
        }
        return try write(Self.normalized(imageSource), to: url, origin: origin, source: source)
    }

    /// A user's image file the user explicitly dropped or copied (Finder ⌘C, ⌃⌥⌘C in Finder) becomes a
    /// shelf PNG like a dropped image: a regular file (not a symlink) whose type conforms to public.image,
    /// ≤ `maxSourceBytes`, read once and re-encoded. The user's file is untouched. nil (use a reference)
    /// for anything else or when decoding fails. This is the one case a user's file content is read.
    public func imageFileCapture(_ url: URL, origin: AttachmentOrigin, source: AttachmentSource? = nil) -> ShelfCapture? {
        guard url.isFileURL else { return nil }
        let file = url.standardizedFileURL
        let values = try? file.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard values?.contentType?.conforms(to: .image) == true, values?.isRegularFile == true,
              let size = values?.fileSize, size <= Self.maxSourceBytes, Self.isRegularFile(file.path),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.count <= Self.maxSourceBytes else { return nil }
        return try? writeImage(data: data, origin: origin, source: source)
    }

    /// A reference to a user's file: name, UTI and size from file-system metadata only. The content is
    /// never read, and the file is never owned (never deleted with the chip). The agent can open or
    /// reveal it through a launcher token the host mints when the request is sent (never its content).
    public func fileCapture(_ url: URL, origin: AttachmentOrigin, owned: Bool = false) -> ShelfCapture? {
        guard url.isFileURL else { return nil }
        let file = url.standardizedFileURL
        let values = try? file.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        let attachment = FileAttachment(name: file.lastPathComponent, uti: values?.contentType?.identifier, path: file.path,
                                        byteSize: values?.isRegularFile == true ? values?.fileSize : nil, origin: origin)
        return ShelfCapture(.file(attachment), ownedFile: owned ? file.path : nil)
    }

    /// A per-drop directory `shelf-inbox/<uuid>/` (0700) for promised files.
    public func makeInboxBatch() throws -> URL {
        let batch = inbox.appendingPathComponent(UUID().uuidString, isDirectory: true)
        for directory in [inbox, batch] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return batch
    }

    /// A shelf PNG directly inside the captures directory (lexical; symlinks are rejected at deletion).
    public func isOwnedImage(_ path: String) -> Bool {
        AttachmentValidation.isInsideCapturesDir(path, capturesDir.path)
            && AttachmentValidation.isShelfImageName((path as NSString).lastPathComponent)
    }

    /// Something received into `shelf-inbox/<batch>/`.
    public func isInInbox(_ path: String) -> Bool {
        guard AttachmentValidation.isAbsoluteHostPath(path) else { return false }
        let root = inbox.path + "/"
        return path.hasPrefix(root) && path.dropFirst(root.count).split(separator: "/").count >= 2
    }

    public func isOwned(_ path: String) -> Bool { isOwnedImage(path) || isInInbox(path) }

    /// Deletes a host-owned shelf file (and its emptied inbox batch, unless `keepBatch`: other promised
    /// files of the same drop may still be on their way into it). Anything else is left alone.
    @discardableResult
    public func dispose(_ path: String?, keepBatch: Bool = false) -> Bool {
        guard let path, isOwned(path) else { return false }
        let fm = FileManager.default
        if isOwnedImage(path) {
            guard Self.isRegularFile(path) else { return false }
            return (try? fm.removeItem(atPath: path)) != nil
        }
        // An inbox entry may be a received folder; remove the whole batch entry, then the empty batch.
        let relative = path.dropFirst(inbox.path.count + 1).split(separator: "/")
        let batch = inbox.appendingPathComponent(String(relative[0]), isDirectory: true)
        let entry = batch.appendingPathComponent(String(relative[1]))
        let removed = (try? fm.removeItem(at: entry)) != nil
        if !keepBatch, (try? fm.contentsOfDirectory(atPath: batch.path))?.isEmpty == true { try? fm.removeItem(at: batch) }
        return removed
    }

    /// Disposes of the `ownedFile`s of items that left the shelf.
    public func dispose(_ items: [ShelfItem]) { items.forEach { dispose($0.ownedFile) } }

    /// Launch sweep: `shelf-*.png` leftovers and the inbox from an earlier run (pi-os's own temp files).
    public func sweep() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: capturesDir.path)) ?? [] where AttachmentValidation.isShelfImageName(name) {
            let path = capturesDir.appendingPathComponent(name).path
            if Self.isRegularFile(path) { try? fm.removeItem(atPath: path) }
        }
        var info = stat()
        if lstat(inbox.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { try? fm.removeItem(at: inbox) }
    }

    // MARK: Encoding

    /// Orientation applied, ≤ 1280 px and ≤ 1 MP (`CaptureSizing`), drawn into sRGB.
    static func normalized(_ source: CGImageSource) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 65_535, height <= 65_535, width * height <= maxSourcePixels else {
            throw DomainError("image_failed", "The image is too large or unreadable")
        }
        let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        let oriented = Rect(x: 0, y: 0, width: Double(rotated ? height : width), height: Double(rotated ? width : height))
        let target = CaptureSizing.pixels(for: oriented)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target.width, target.height),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw DomainError("image_failed", "The image could not be decoded")
        }
        // The thumbnail may round a pixel differently and keeps the source color space: draw exactly the
        // `CaptureSizing` target in sRGB.
        let size = target
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DomainError("image_failed", "The image could not be converted")
        }
        context.interpolationQuality = .high
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        guard let image = context.makeImage() else { throw DomainError("image_failed", "The image could not be converted") }
        return image
    }

    private func write(_ image: CGImage, to url: URL, origin: AttachmentOrigin, source: AttachmentSource?) throws -> ShelfCapture {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DomainError("image_failed", "PNG encoder unavailable")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), data.length <= Self.maxPNGBytes else {
            throw DomainError("image_failed", "The image exceeds the PNG size limit")
        }
        try (data as Data).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let digest = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
        let attachment = ImageAttachment(path: url.path, width: image.width, height: image.height, origin: origin, source: source)
        return ShelfCapture(.image(attachment), ownedFile: url.path, contentKey: digest)
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
    }
}

/// Region grab v0: the system's interactive area capture (`screencapture -i`, the ⇧⌘4 UI; Esc cancels),
/// written into the captures directory as `shelf-<uuid>.png` and then downscaled in place. The tool is
/// started by absolute path and only that child process is ever terminated (on cancellation).
@MainActor
public final class RegionGrab {
    /// Writes the user's chosen area to `output`, or nothing when the user cancels.
    public typealias Runner = (_ output: URL) async throws -> Void
    public nonisolated static let tool = "/usr/sbin/screencapture"

    private let files: ShelfFiles
    private let runner: Runner
    public private(set) var isRunning = false

    public init(files: ShelfFiles, runner: Runner? = nil) {
        self.files = files
        self.runner = runner ?? { try await RegionGrab.runScreencapture($0) }
    }

    /// The normalized region image, or nil when the user pressed Esc (or the task was cancelled).
    /// Throws `busy` while another grab is open. The PNG is the caller's to put on the shelf or dispose of.
    public func grab(source: AttachmentSource? = nil) async throws -> ShelfCapture? {
        guard !isRunning else { throw DomainError("busy", "An area grab is already open") }
        isRunning = true
        defer { isRunning = false }
        let output = files.newImageURL()
        do {
            try await runner(output)
        } catch is CancellationError {
            files.dispose(output.path)
            return nil
        } catch {
            files.dispose(output.path)
            throw error
        }
        guard !Task.isCancelled, ShelfFiles.isRegularFile(output.path) else {
            files.dispose(output.path)
            return nil
        }
        do {
            return try files.normalizeImage(at: output, origin: .region, source: source)
        } catch {
            files.dispose(output.path)
            throw error
        }
    }

    /// `screencapture -i -x -t png <output>`: interactive selection, no sound. A cancelled task
    /// terminates exactly the child it started.
    nonisolated static func runScreencapture(_ output: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["-i", "-x", "-t", "png", output.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = ChildProcess(process)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try Task.checkCancellation()
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            child.terminate()
        }
    }

    private final class ChildProcess: @unchecked Sendable {
        private let process: Process
        init(_ process: Process) { self.process = process }
        func terminate() { if process.isRunning { process.terminate() } }
    }
}
