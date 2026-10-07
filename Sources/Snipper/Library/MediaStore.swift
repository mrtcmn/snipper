import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Image files that belong to snips, stored in the app's Media folder.
/// All methods are safe to call from any thread.
struct MediaStore: Sendable {
    let folder: URL

    func url(for fileName: String) -> URL {
        folder.appendingPathComponent(fileName)
    }

    func exists(_ fileName: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fileName).path)
    }

    /// Writes `data` under a new unique name and returns that name.
    func save(_ data: Data, fileExtension: String) throws -> String {
        let name = "\(UUID().uuidString.lowercased()).\(fileExtension)"
        try data.write(to: url(for: name), options: .atomic)
        return name
    }

    func savePNG(_ image: CGImage) throws -> String {
        guard let data = ImageCoding.png(image) else { throw CocoaError(.fileWriteUnknown) }
        return try save(data, fileExtension: "png")
    }

    func delete(_ fileNames: [String]) {
        for name in fileNames where !name.isEmpty {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    func cgImage(_ fileName: String) -> CGImage? {
        ImageCoding.cgImage(at: url(for: fileName))
    }

    /// Pixel size without decoding the image.
    func pixelSize(_ fileName: String) -> CGSize? {
        ImageCoding.pixelSize(at: url(for: fileName))
    }
}

enum ImageCoding {
    static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, quality: nil)
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.88) -> Data? {
        encode(image, type: .jpeg, quality: quality)
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        var options: [CFString: Any] = [:]
        if let quality { options[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    static func cgImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    static func cgImage(data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    static func pixelSize(at url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: w, height: h)
    }

    /// A downscaled, orientation-corrected copy whose longest side is at most `maxPixels`.
    static func thumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source: source, maxPixels: maxPixels)
    }

    static func thumbnail(data: Data, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return thumbnail(source: source, maxPixels: maxPixels)
    }

    private static func thumbnail(source: CGImageSource, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG sized for EmbeddingGemma's vision encoder (≈280 soft tokens ≈ 800×800 px).
    static func embeddingJPEG(at url: URL) -> Data? {
        guard let image = thumbnail(at: url, maxPixels: 1024) else { return nil }
        return jpeg(flattened(image), quality: 0.9)
    }

    static func embeddingJPEG(data: Data) -> Data? {
        guard let image = thumbnail(data: data, maxPixels: 1024) else { return nil }
        return jpeg(flattened(image), quality: 0.9)
    }

    /// Composites transparent images (window captures) onto white, since JPEG has no alpha.
    static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst else { return image }
        let width = image.width, height = image.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return image }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? image
    }
}

extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

enum Pasteboard {
    static func copy(image: CGImage) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let rep = NSBitmapImageRep(cgImage: image)
        let item = NSPasteboardItem()
        if let png = rep.representation(using: .png, properties: [:]) { item.setData(png, forType: .png) }
        if let tiff = rep.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    static func copy(fileURL: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([fileURL as NSURL])
    }
}
