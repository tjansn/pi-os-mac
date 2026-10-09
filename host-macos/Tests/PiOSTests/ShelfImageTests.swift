import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import PiOSCore
@testable import PiOSMac

/// Synthetic images only (no screen capture, no user content).
enum ShelfTestImages {
    static func cgImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 0.5, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 3))
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, orientation: Int? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, image, properties)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func png(width: Int, height: Int) -> Data { encode(cgImage(width: width, height: height), type: .png) }
}

final class ShelfImageTests: XCTestCase {
    private func files() throws -> ShelfFiles {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pi-os-shelf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return ShelfFiles(capturesDir: directory)
    }

    private func decodedSize(_ path: String) -> [Int] {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        return [image.width, image.height]
    }

    func testLargeImagesAreDownscaledIntoPrivateShelfPNGs() throws {
        let shelf = try files()
        let capture = try shelf.writeImage(data: ShelfTestImages.png(width: 4_000, height: 3_000), origin: .clipboard)
        guard case .image(let image) = capture.attachment else { return XCTFail("image expected") }
        let expected = CaptureSizing.pixels(for: Rect(x: 0, y: 0, width: 4_000, height: 3_000))
        XCTAssertEqual([image.width, image.height], [expected.width, expected.height])
        XCTAssertLessThanOrEqual(max(image.width, image.height), AttachmentLimits.maxImageEdge)
        XCTAssertLessThanOrEqual(image.width * image.height, AttachmentLimits.maxImagePixels)
        XCTAssertEqual(decodedSize(image.path), [image.width, image.height], "the file holds exactly the announced pixels")
        XCTAssertTrue(AttachmentValidation.isShelfImageName((image.path as NSString).lastPathComponent))
        XCTAssertEqual(AttachmentValidation.issues([capture.attachment], capturesDir: shelf.capturesDir.path), [])
        let attributes = try FileManager.default.attributesOfItem(atPath: image.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: image.path)).prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
        XCTAssertEqual(capture.ownedFile, image.path)
        XCTAssertNotNil(capture.contentKey)

        let tall = try shelf.writeImage(data: ShelfTestImages.png(width: 300, height: 9_000), origin: .drop)
        guard case .image(let thin) = tall.attachment else { return XCTFail() }
        XCTAssertEqual(thin.height, AttachmentLimits.maxImageEdge)
        XCTAssertEqual(AttachmentValidation.issues([tall.attachment], capturesDir: shelf.capturesDir.path), [])
    }

    func testSmallImagesKeepTheirSizeAndOrientationIsBakedIn() throws {
        let shelf = try files()
        guard case .image(let small) = try shelf.writeImage(data: ShelfTestImages.png(width: 300, height: 200), origin: .clipboard).attachment
        else { return XCTFail() }
        XCTAssertEqual([small.width, small.height], [300, 200])
        let rotated = ShelfTestImages.encode(ShelfTestImages.cgImage(width: 400, height: 200), type: .jpeg, orientation: 6)
        guard case .image(let upright) = try shelf.writeImage(data: rotated, origin: .clipboard).attachment else { return XCTFail() }
        XCTAssertEqual([upright.width, upright.height], [200, 400], "EXIF orientation 6 is applied, not passed on")
        let first = try shelf.writeImage(data: ShelfTestImages.png(width: 50, height: 50), origin: .drop)
        let second = try shelf.writeImage(data: ShelfTestImages.png(width: 50, height: 50), origin: .drop)
        XCTAssertNotEqual(first.ownedFile, second.ownedFile)
        XCTAssertEqual(first.contentKey, second.contentKey, "the same pixels dedupe on the shelf")
    }

    func testUnreadableImagesThrowAndLeaveNoFile() throws {
        let shelf = try files()
        XCTAssertThrowsError(try shelf.writeImage(data: Data("not an image".utf8), origin: .clipboard))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shelf.capturesDir.path), [])
    }

    func testDisposeAndSweepDeleteOnlyShelfOwnedFiles() throws {
        let shelf = try files()
        let fm = FileManager.default
        let user = fm.temporaryDirectory.appendingPathComponent("pi-os-shelf-user-" + UUID().uuidString)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: user) }
        let userFile = user.appendingPathComponent("shelf-mine.png")
        try Data("user".utf8).write(to: userFile)
        let shot = shelf.capturesDir.appendingPathComponent("shot-1.png")
        try Data("window capture".utf8).write(to: shot)
        let link = shelf.capturesDir.appendingPathComponent("shelf-link.png")
        try fm.createSymbolicLink(at: link, withDestinationURL: userFile)
        let nested = shelf.capturesDir.appendingPathComponent("sub", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nested.appendingPathComponent("shelf-deep.png"))

        XCTAssertFalse(shelf.dispose(userFile.path), "a user's file is never deleted, whatever its name")
        XCTAssertFalse(shelf.dispose(shot.path), "window captures belong to DesktopService")
        XCTAssertFalse(shelf.dispose(link.path), "a symlink is not a shelf PNG")
        XCTAssertFalse(shelf.dispose(nested.appendingPathComponent("shelf-deep.png").path))
        XCTAssertFalse(shelf.dispose(shelf.capturesDir.path + "/../" + user.lastPathComponent + "/shelf-mine.png"))
        XCTAssertFalse(shelf.dispose(nil))
        let image = try shelf.writeImage(data: ShelfTestImages.png(width: 10, height: 10), origin: .region)
        XCTAssertTrue(shelf.dispose(image.ownedFile))
        XCTAssertFalse(fm.fileExists(atPath: image.ownedFile!))

        let batch = try shelf.makeInboxBatch()
        let received = batch.appendingPathComponent("Message.eml")
        try Data("dummy".utf8).write(to: received)
        XCTAssertTrue(shelf.isInInbox(received.path))
        XCTAssertTrue(shelf.dispose(received.path))
        XCTAssertFalse(fm.fileExists(atPath: batch.path), "an emptied inbox batch is removed")

        let leftover = try shelf.writeImage(data: ShelfTestImages.png(width: 10, height: 10), origin: .region)
        let stale = try shelf.makeInboxBatch().appendingPathComponent("old.pdf")
        try Data("dummy".utf8).write(to: stale)
        shelf.sweep()
        XCTAssertFalse(fm.fileExists(atPath: leftover.ownedFile!))
        XCTAssertFalse(fm.fileExists(atPath: shelf.inbox.path))
        XCTAssertTrue(fm.fileExists(atPath: userFile.path))
        XCTAssertTrue(fm.fileExists(atPath: shot.path))
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path), "the sweep never follows or removes links")
        XCTAssertTrue(fm.fileExists(atPath: nested.appendingPathComponent("shelf-deep.png").path))
    }

    // MARK: Region grab (fake runner; the real tool is never started in tests)

    @MainActor
    func testRegionGrabNormalizesTheChosenAreaInPlace() async throws {
        let shelf = try files()
        var outputs: [URL] = []
        let grab = RegionGrab(files: shelf) { output in
            outputs.append(output)
            try ShelfTestImages.png(width: 3_000, height: 3_000).write(to: output)
        }
        let capture = try await grab.grab(source: AttachmentSource(app: "Preview", title: "Q3.pdf"))
        guard case .image(let image)? = capture?.attachment else { return XCTFail("image expected") }
        XCTAssertEqual(image.path, outputs.first?.path, "written to captures/shelf-<uuid>.png and downscaled in place")
        XCTAssertEqual([image.width, image.height], [1_000, 1_000])
        XCTAssertEqual(image.origin, .region)
        XCTAssertEqual(image.source, AttachmentSource(app: "Preview", title: "Q3.pdf"))
        XCTAssertEqual(decodedSize(image.path), [1_000, 1_000])
        XCTAssertEqual(AttachmentValidation.issues([.image(image)], capturesDir: shelf.capturesDir.path), [])
        XCTAssertFalse(grab.isRunning)
        XCTAssertEqual(RegionGrab.tool, "/usr/sbin/screencapture")
    }

    @MainActor
    func testRegionGrabEscapeCancelAndFailureLeaveNothingBehind() async throws {
        let shelf = try files()
        let escaped = try await RegionGrab(files: shelf) { _ in }.grab()
        XCTAssertNil(escaped, "Esc writes no file")
        let cancelled = try await RegionGrab(files: shelf) { output in
            try Data("partial".utf8).write(to: output)
            throw CancellationError()
        }.grab()
        XCTAssertNil(cancelled)
        struct Failed: Error {}
        do {
            _ = try await RegionGrab(files: shelf) { output in
                try Data("partial".utf8).write(to: output)
                throw Failed()
            }.grab()
            XCTFail("expected an error")
        } catch is Failed {}
        do {
            _ = try await RegionGrab(files: shelf) { output in try Data("not a png".utf8).write(to: output) }.grab()
            XCTFail("expected an error")
        } catch let error as DomainError {
            XCTAssertEqual(error.code, "image_failed")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: shelf.capturesDir.path), [])
    }

    @MainActor
    func testRegionGrabIsSingleFlight() async throws {
        let shelf = try files()
        let grab = RegionGrab(files: shelf) { _ in try await Task.sleep(nanoseconds: 200_000_000) }
        let first = Task { try await grab.grab() }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertTrue(grab.isRunning)
        do {
            _ = try await grab.grab()
            XCTFail("a second grab must not start")
        } catch let error as DomainError {
            XCTAssertEqual(error.code, "busy")
        }
        let result = try await first.value
        XCTAssertNil(result)
        XCTAssertFalse(grab.isRunning)
    }
}
