import AppKit
import Combine
import SwiftUI

// MARK: - Image Cache

/// A singleton cache for storing downloaded NSImage objects.
final class ImageCache {
    static let shared = NSCache<NSString, NSImage>()
}

// MARK: - Image Loader

/// An observable object that asynchronously downloads and caches images.
final class ImageLoader: ObservableObject {
    @Published var image: NSImage?
    
    private var cancellable: AnyCancellable?
    
    /// The URL of the image to load.
    var url: URL?

    /// Raw image bytes to decode directly, bypassing the network fetch
    /// (e.g. Apple Music artwork, which has no URL). Takes priority over `url`.
    var data: Data?

    /// Optional target size to which the image should be resized.
    var targetSize: CGSize?

    /// Initializes the loader with an optional URL and target size.
    /// - Parameters:
    ///   - url: The URL of the image.
    ///   - targetSize: The desired size for the image.
    ///   - data: Raw image bytes to decode directly, instead of fetching `url`.
    init(url: URL?, targetSize: CGSize? = nil, data: Data? = nil) {
        self.url = url
        self.targetSize = targetSize
        self.data = data
    }
    
    /// Generates a cache key based on the URL and target size.
    private var cacheKey: NSString? {
        guard let url = url else { return nil }
        if let targetSize = targetSize {
            return "\(url.absoluteString)-\(Int(targetSize.width))x\(Int(targetSize.height))" as NSString
        } else {
            return url.absoluteString as NSString
        }
    }
    
    /// Loads the image from raw data or the URL, resizing if needed, and caches it.
    func load() {
        // Cancel any ongoing request before starting a new one.
        cancellable?.cancel()

        // Raw data is already in memory — decode it directly, no network needed.
        if let data = data {
            guard let decodedImage = NSImage(data: data) else { return }
            image = targetSize.flatMap { decodedImage.resized(to: $0) } ?? decodedImage
            return
        }

        guard let url = url, let key = cacheKey else { return }
        
        // Check for cached image.
        if let cachedImage = ImageCache.shared.object(forKey: key) {
            self.image = cachedImage
            return
        }
        
        // Download image asynchronously.
        cancellable = URLSession.shared.dataTaskPublisher(for: url)
            .tryMap { [weak self] data, _ -> NSImage? in
                guard let downloadedImage = NSImage(data: data) else { return nil }
                if let targetSize = self?.targetSize {
                    return downloadedImage.resized(to: targetSize) ?? downloadedImage
                }
                return downloadedImage
            }
            .replaceError(with: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] downloadedImage in
                if let downloadedImage = downloadedImage {
                    ImageCache.shared.setObject(downloadedImage, forKey: key)
                }
                self?.image = downloadedImage
            }
    }
    
    deinit {
        cancellable?.cancel()
    }
}

// MARK: - NSImage Extension

extension NSImage {
    /// Returns a resized version of the image.
    /// - Parameter newSize: The target size.
    /// - Returns: A new NSImage resized to the given dimensions, or nil if resizing fails.
    func resized(to newSize: NSSize) -> NSImage? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let bitsPerComponent = 8
        let bytesPerRow = 4 * Int(newSize.width)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: Int(newSize.width),
            height: Int(newSize.height),
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(origin: .zero, size: newSize))
        guard let resizedCGImage = context.makeImage() else { return nil }
        return NSImage(cgImage: resizedCGImage, size: newSize)
    }

    /// Extracts a representative accent color from the image for dynamic theming.
    ///
    /// The image is downsampled to a small grid and pixels are averaged with a
    /// weight toward saturated, mid-brightness colors — this favors a vibrant
    /// accent over the muddy grey a plain average tends to produce. Near-black,
    /// near-white, and transparent pixels are ignored. The result is nudged to a
    /// legible saturation/brightness so it reads well over the dark popup.
    func dominantColor() -> Color? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        let side = 24
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixels,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var wr = 0.0, wg = 0.0, wb = 0.0, totalWeight = 0.0
        var ar = 0.0, ag = 0.0, ab = 0.0, count = 0.0

        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255.0
            guard a > 0.3 else { continue }
            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0

            // Plain-average accumulator (fallback for greyscale art).
            ar += r; ag += g; ab += b; count += 1

            let maxC = max(r, g, b), minC = min(r, g, b)
            let brightness = maxC
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            // Skip near-black / near-white; weight the rest by vibrancy.
            guard brightness > 0.15, brightness < 0.98 else { continue }
            let weight = saturation * saturation * brightness
            wr += r * weight; wg += g * weight; wb += b * weight
            totalWeight += weight
        }

        let r: Double, g: Double, b: Double
        if totalWeight > 0.0001 {
            r = wr / totalWeight; g = wg / totalWeight; b = wb / totalWeight
        } else if count > 0 {
            r = ar / count; g = ag / count; b = ab / count
        } else {
            return nil
        }

        // Nudge toward a legible accent over the dark popup background.
        return Color(nsColor: NSColor(red: r, green: g, blue: b, alpha: 1))
            .adjustedForAccent()
    }
}

// MARK: - Color Accent Adjustment

extension Color {
    /// Ensures a color is saturated and bright enough to serve as a visible
    /// accent on a dark background.
    fileprivate func adjustedForAccent() -> Color {
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        var h: CGFloat = 0, s: CGFloat = 0, brightness: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &brightness, alpha: &a)
        let boostedS = min(1.0, max(s, 0.45))
        let boostedB = min(1.0, max(brightness, 0.75))
        return Color(
            nsColor: NSColor(
                hue: h, saturation: boostedS, brightness: boostedB, alpha: 1))
    }
}

// MARK: - Rotate Animated Cached Image View

/// A view that displays a cached image with a rotation and blur animation when the image changes.
struct RotateAnimatedCachedImage<RotatingContent: View>: View {
    let url: URL?
    let data: Data?
    let targetSize: CGSize?

    @StateObject private var loader: ImageLoader
    @State private var displayedImage: NSImage?
    @State private var rotation: Double = 1
    let rotatingModifier: (Image) -> RotatingContent

    /// Initializes the view with a URL (or raw data), optional target size, and a custom rotating modifier.
    init(
        url: URL?,
        data: Data? = nil,
        targetSize: CGSize? = nil,
        @ViewBuilder rotatingModifier: @escaping (Image) -> RotatingContent
    ) {
        self.url = url
        self.data = data
        self.targetSize = targetSize
        _loader = StateObject(wrappedValue: ImageLoader(url: url, targetSize: targetSize, data: data))
        self.rotatingModifier = rotatingModifier
    }

    /// Convenience initializer when no custom modifier is needed.
    init(url: URL?, data: Data? = nil, targetSize: CGSize? = nil) where RotatingContent == Image {
        self.init(url: url, data: data, targetSize: targetSize) { image in image }
    }

    var body: some View {
        Group {
            if let image = displayedImage {
                rotatingModifier(Image(nsImage: image).resizable())
                    .blur(radius: abs(1 - rotation) * 5)
                    .scaleEffect(x: rotation)
            } else {
                Color.clear
            }
        }
        .onAppear { loader.load() }
        .onReceive(loader.$image) { newImage in
            guard let newImage = newImage else { return }
            // If image is loading for the first time.
            if displayedImage == nil {
                displayedImage = newImage
            } else if displayedImage != newImage {
                // Animate the transition.
                withAnimation(.easeInOut(duration: 0.2)) { rotation = 0 }
                withAnimation(.easeOut(duration: 0.3).delay(0.2)) { rotation = 1 }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    displayedImage = newImage
                }
            }
        }
        .onChange(of: url) { _, newURL in
            loader.url = newURL
            loader.load()
        }
        .onChange(of: data) { _, newData in
            loader.data = newData
            loader.load()
        }
    }
}

// MARK: - Fade Animated Cached Image View

/// A view that displays a cached image with a fade transition when the image changes.
struct FadeAnimatedCachedImage<Content: View>: View {
    let url: URL?
    let data: Data?
    let targetSize: CGSize?

    @StateObject private var loader: ImageLoader
    @State private var currentImage: NSImage?
    @State private var nextImage: NSImage?
    @State private var showNextImage: Bool = false
    let content: (Image) -> Content

    /// Initializes the view with a URL (or raw data), optional target size, and a custom content modifier.
    init(
        url: URL?,
        data: Data? = nil,
        targetSize: CGSize? = nil,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.data = data
        self.targetSize = targetSize
        _loader = StateObject(wrappedValue: ImageLoader(url: url, targetSize: targetSize, data: data))
        self.content = content
    }

    /// Convenience initializer when no custom modifier is needed.
    init(url: URL?, data: Data? = nil, targetSize: CGSize? = nil) where Content == Image {
        self.init(url: url, data: data, targetSize: targetSize) { image in image }
    }
    
    var body: some View {
        ZStack {
            if let currentImage = currentImage {
                content(Image(nsImage: currentImage))
            }
            
            if let nextImage = nextImage {
                content(Image(nsImage: nextImage))
                    .opacity(showNextImage ? 1 : 0)
            }
        }
        .onAppear { loader.load() }
        .onReceive(loader.$image) { newImage in
            guard let newImage = newImage else { return }
            // Set the image for the first time.
            if currentImage == nil {
                currentImage = newImage
            } else if currentImage != newImage {
                // Animate the fade transition.
                nextImage = newImage
                withAnimation(.easeInOut(duration: 0.5)) {
                    showNextImage = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    currentImage = newImage
                    nextImage = nil
                    showNextImage = false
                }
            }
        }
        .onChange(of: url) { _, newURL in
            loader.url = newURL
            loader.load()
        }
        .onChange(of: data) { _, newData in
            loader.data = newData
            loader.load()
        }
    }
}

// MARK: - Cached Image View

/// A view that displays a cached image without animation.
struct CachedImage<Content: View>: View {
    let url: URL?
    let targetSize: CGSize?
    
    @StateObject private var loader: ImageLoader
    @State private var displayedImage: NSImage?
    let content: (Image) -> Content
    
    /// Initializes the view with a URL and optional target size.
    init(
        url: URL?,
        targetSize: CGSize? = nil,
        @ViewBuilder content: @escaping (Image) -> Content
    ) {
        self.url = url
        self.targetSize = targetSize
        _loader = StateObject(wrappedValue: ImageLoader(url: url, targetSize: targetSize))
        self.content = content
    }
    
    var body: some View {
        Group {
            if let image = displayedImage {
                Image(nsImage: image).resizable()
            } else {
                Color.clear
            }
        }
        .onAppear { loader.load() }
        .onReceive(loader.$image) { newImage in
            displayedImage = newImage
        }
        .onChange(of: url) { _, newURL in
            loader.url = newURL
            loader.load()
        }
    }
}
