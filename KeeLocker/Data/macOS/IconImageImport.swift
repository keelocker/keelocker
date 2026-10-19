import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 20 * 1024 * 1024 else { throw Failure.invalidImage }
        let data = try Data(contentsOf: url)
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
