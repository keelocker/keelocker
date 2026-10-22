import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers

enum BoundedFileRead {
    enum Failure: Error, Equatable { case unsupportedFile, tooLarge }

    static func load(_ url: URL, limit: Int) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        // Open without waiting on special files, then validate the descriptor
        // that will actually be read, rather than a separate pathname lookup.
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { throw Failure.unsupportedFile }
        guard limit >= 0, metadata.st_size >= 0, metadata.st_size <= limit else { throw Failure.tooLarge }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = limit - data.count
            let chunk = try handle.read(upToCount: remaining > 0 ? min(64 * 1024, remaining) : 1) ?? Data()
            guard !chunk.isEmpty else { return data }
            // A file may grow after fstat. Never retain more than the limit.
            guard chunk.count <= remaining else { throw Failure.tooLarge }
            data.append(chunk)
        }
    }
}

@MainActor
final class IconImportSession {
    typealias Loader = @Sendable (URL) async throws -> VaultCustomIcon
    private var generation = UUID()
    private let loader: Loader
    private let websiteLoader: Loader

    init(websiteLoader: @escaping Loader = { try await FaviconDownloader().download($0) },
         loader: @escaping Loader = { url in
        try await Task.detached { try IconImageImport.load(url) }.value
    }) {
        self.loader = loader
        self.websiteLoader = websiteLoader
    }

    func begin() -> UUID {
        invalidate()
        return generation
    }

    func invalidate() { generation = UUID() }
    func isCurrent(_ request: UUID) -> Bool { generation == request }

    func load(_ url: URL, request: UUID) async throws -> VaultCustomIcon? {
        try await load(url, request: request, using: loader)
    }

    func loadWebsite(_ url: URL, request: UUID) async throws -> VaultCustomIcon? {
        try await load(url, request: request, using: websiteLoader)
    }

    private func load(_ url: URL, request: UUID, using loader: Loader) async throws -> VaultCustomIcon? {
        guard isCurrent(request), !Task.isCancelled else { return nil }
        do {
            let icon = try await loader(url)
            guard isCurrent(request), !Task.isCancelled else { return nil }
            return icon
        } catch {
            guard isCurrent(request), !Task.isCancelled else { return nil }
            throw error
        }
    }
}

enum IconImageImport {
    enum Failure: Error { case invalidImage }

    static func load(_ url: URL) throws -> VaultCustomIcon {
        let data: Data
        do { data = try BoundedFileRead.load(url, limit: 20 * 1024 * 1024) }
        catch is BoundedFileRead.Failure { throw Failure.invalidImage }
        let name = String(url.deletingPathExtension().lastPathComponent.prefix(200))
        return try normalized(data, name: name)
    }

    static func normalized(_ data: Data, name: String) throws -> VaultCustomIcon {
        guard data.count <= 20 * 1024 * 1024,
              let image = preview(data), let png = png(image), png.count <= 1024 * 1024 else {
            throw Failure.invalidImage
        }
        return VaultCustomIcon(id: UUID(), name: String(name.prefix(200)), data: png)
    }

    static func preview(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        // ICO files often put their 16 px variant first. Pick the largest valid
        // representation; animated images still use their first frame.
        let isICO = (CGImageSourceGetType(source) as String?) == UTType(filenameExtension: "ico")?.identifier
        let count = isICO ? min(CGImageSourceGetCount(source), 64) : 1
        var selected: Int?
        var largestArea = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.intValue > 0, height.intValue > 0,
                  width.intValue <= 16_384, height.intValue <= 16_384,
                  width.intValue * height.intValue <= 40_000_000 else { continue }
            let area = width.intValue * height.intValue
            if area > largestArea { selected = index; largestArea = area }
        }
        guard let selected else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, selected, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
