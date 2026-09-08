import SwiftUI
import AVKit
import QuickLookThumbnailing
import AppKit
import UniformTypeIdentifiers
import Combine
import PDFKit

// MARK: - Constants & Layout Configuration
enum LayoutConstants {
    static let dropzoneWidth: CGFloat = 400
    static let dropzoneHeight: CGFloat = 350
    static let browserWidth: CGFloat = 1120
    static let browserHeight: CGFloat = 776
    static let cardWidth: CGFloat = 264
    static let cardHeight: CGFloat = 200
    static let thumbnailWidth: CGFloat = 224
    static let thumbnailHeight: CGFloat = 145
    static let thumbnailLargeWidth: CGFloat = 448
    static let thumbnailLargeHeight: CGFloat = 290
    static let pipMaxDimension: CGFloat = 450
    static let pipAudioWidth: CGFloat = 350
    static let pipAudioHeight: CGFloat = 150
    static let autoHideDelay: TimeInterval = 3.0
    static let periodicTimeInterval: Double = 0.25
    static let maxConcurrentThumbnails: Int = ProcessInfo.processInfo.activeProcessorCount
}

enum KeyCode {
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
    static let returnKey: UInt16 = 36
    static let enterKey: UInt16 = 76
    static let spaceKey: UInt16 = 49
    static let escapeKey: UInt16 = 53
}

// MARK: - Supported Formats
enum SupportedFormats {
    static let images: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "tiff", "tif", "ico", "svg",
        "psd", "jp2", "jxl", "exr", "hdr", "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"
    ]
    static let videos: Set<String> = [
        "mp4", "m4v", "mov", "qt", "mkv", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "dv", "flv"
    ]
    static let audios: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "caf", "ac3", "au", "snd"
    ]
    static let documents: Set<String> = ["pdf"]

    static func isSupported(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return images.contains(e) || videos.contains(e) || audios.contains(e) || documents.contains(e)
    }
}

// MARK: - Window Layout Configuration Model
struct WindowLayoutSpec {
    let width: CGFloat
    let height: CGFloat
    let minWidth: CGFloat
    let minHeight: CGFloat
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let isResizable: Bool
}

enum WindowInteractionMode {
    case dropzone
    case browser
    case slideshow
}

@MainActor
enum WindowManager {
    static var primaryWindow: NSWindow? {
        NSApp.windows.first(where: { !$0.isKind(of: PiPPanel.self) })
    }
    
    static func spec(for mode: WindowInteractionMode) -> WindowLayoutSpec {
        switch mode {
        case .dropzone:
            return WindowLayoutSpec(
                width: LayoutConstants.dropzoneWidth, height: LayoutConstants.dropzoneHeight,
                minWidth: LayoutConstants.dropzoneWidth, minHeight: LayoutConstants.dropzoneHeight,
                maxWidth: LayoutConstants.dropzoneWidth, maxHeight: LayoutConstants.dropzoneHeight,
                isResizable: false
            )
        case .browser, .slideshow:
            return WindowLayoutSpec(
                width: LayoutConstants.browserWidth, height: LayoutConstants.browserHeight,
                minWidth: LayoutConstants.dropzoneWidth, minHeight: LayoutConstants.dropzoneHeight,
                maxWidth: CGFloat.greatestFiniteMagnitude, maxHeight: CGFloat.greatestFiniteMagnitude,
                isResizable: true
            )
        }
    }
    
    static func updateWindowForMode(_ mode: WindowInteractionMode) {
        guard let window = primaryWindow else { return }
        let layoutSpec = spec(for: mode)
        
        if mode == .dropzone && window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        
        if layoutSpec.isResizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
        
        window.minSize = NSSize(width: layoutSpec.minWidth, height: layoutSpec.minHeight)
        window.maxSize = NSSize(width: layoutSpec.maxWidth, height: layoutSpec.maxHeight)
        
        if !window.styleMask.contains(.fullScreen) {
            window.setContentSize(NSSize(width: layoutSpec.width, height: layoutSpec.height))
        }
    }
}

// MARK: - Models & Cache
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let isVideo: Bool
    let isAudio: Bool
    
    var isMedia: Bool { !isDirectory }
    var ext: String { url.pathExtension.lowercased() }
    var isPDF: Bool { ext == "pdf" }
}

struct FolderState {
    let url: URL
    var selectedIndex: Int
}

final class ThumbnailCache {
    static let shared: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 1024 * 1024 * 256 // 256MB
        return cache
    }()
    
    static func key(for url: URL) -> NSString {
        return NSString(string: url.standardizedFileURL.absoluteString)
    }
    
    static func fullKey(for url: URL) -> NSString {
        return NSString(string: url.standardizedFileURL.absoluteString + "_full")
    }
    
    static func pdfKey(for url: URL, page: Int) -> NSString {
        return NSString(string: "\(url.standardizedFileURL.absoluteString)_p\(page)")
    }
}

// MARK: - Async Image Loader with Concurrency Limiter
actor ImageLoader {
    static let shared = ImageLoader()
    
    private var activeRequests = 0
    private var pendingContinuations: [UnsafeContinuation<Void, Never>] = []

    private func acquireSemaphore() async {
        if activeRequests < LayoutConstants.maxConcurrentThumbnails {
            activeRequests += 1
            return
        }
        await withUnsafeContinuation { continuation in
            pendingContinuations.append(continuation)
        }
    }

    private func releaseSemaphore() {
        if !pendingContinuations.isEmpty {
            let next = pendingContinuations.removeFirst()
            next.resume()
        } else {
            activeRequests = max(0, activeRequests - 1)
        }
    }
    
    func loadThumbnail(for item: MediaItem, size: CGSize) async -> NSImage? {
        let key = ThumbnailCache.key(for: item.url)
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            return cached
        }
        
        await acquireSemaphore()
        defer { releaseSemaphore() }

        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let didStart = item.url.startAccessingSecurityScopedResource()
            defer { if didStart { item.url.stopAccessingSecurityScopedResource() } }
            
            if item.isAudio {
                let image = NSImage(size: size)
                image.lockFocus()
                if let context = NSGraphicsContext.current?.cgContext {
                    context.setFillColor(NSColor.darkGray.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                }
                image.unlockFocus()
                let cost = Int(size.width * size.height * 4)
                ThumbnailCache.shared.setObject(image, forKey: key, cost: cost)
                return image
            }

            if item.isPDF {
                if let doc = PDFDocument(url: item.url), let page = doc.page(at: 0) {
                    let pageRect = page.bounds(for: .mediaBox)
                    let image = NSImage(size: size)
                    image.lockFocus()
                    if let context = NSGraphicsContext.current?.cgContext {
                        context.setFillColor(NSColor.white.cgColor)
                        context.fill(CGRect(origin: .zero, size: size))
                        
                        let targetRect = AVMakeRect(aspectRatio: pageRect.size, insideRect: CGRect(origin: .zero, size: size))
                        context.saveGState()
                        context.translateBy(x: targetRect.origin.x, y: targetRect.origin.y)
                        context.scaleBy(x: targetRect.width / max(1, pageRect.width), y: targetRect.height / max(1, pageRect.height))
                        page.draw(with: .mediaBox, to: context)
                        context.restoreGState()
                    }
                    image.unlockFocus()
                    let cost = Int(size.width * size.height * 4)
                    ThumbnailCache.shared.setObject(image, forKey: key, cost: cost)
                    return image
                }
            }
            
            let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
            let request = QLThumbnailGenerator.Request(
                fileAt: item.url,
                size: size,
                scale: scale,
                representationTypes: .thumbnail
            )
             
            do {
                let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                let image = representation.nsImage
                let cost = Int(image.size.width * image.size.height * 4 * scale)
                ThumbnailCache.shared.setObject(image, forKey: key, cost: cost)
                return image
            } catch {
                if !SupportedFormats.isSupported(item.ext) { return nil }
                if SupportedFormats.images.contains(item.ext), let fullImage = ImageLoader.loadFullImageSync(from: item.url) {
                    let cost = Int(fullImage.size.width * fullImage.size.height * 4)
                    ThumbnailCache.shared.setObject(fullImage, forKey: key, cost: cost)
                    return fullImage
                }
                return nil
            }
        }.value
    }
    
    nonisolated static func loadFullImageSync(from url: URL) -> NSImage? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceShouldCache: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            if let image = NSImage(contentsOf: url) {
                let fullKey = ThumbnailCache.fullKey(for: url)
                let cost = Int(image.size.width * image.size.height * 4)
                ThumbnailCache.shared.setObject(image, forKey: fullKey, cost: cost)
                return image
            }
            return nil
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        let fullKey = ThumbnailCache.fullKey(for: url)
        let cost = Int(cgImage.width * cgImage.height * 4)
        ThumbnailCache.shared.setObject(image, forKey: fullKey, cost: cost)
        return image
    }

    func loadFullImageAsync(from url: URL) async -> NSImage? {
        let fullKey = ThumbnailCache.fullKey(for: url)
        if let cached = ThumbnailCache.shared.object(forKey: fullKey) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) {
            ImageLoader.loadFullImageSync(from: url)
        }.value
    }
}

// MARK: - Picture-in-Picture Manager
final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PiPManager {
    static let shared = PiPManager()
    private var pipWindow: PiPPanel?
    private var isTransitioning = false

    var isPiPActive: Bool { pipWindow != nil }

    func togglePiP(for state: AppState) {
        if state.isFullScreen || isTransitioning { return }
        if pipWindow != nil {
            closePiP(state: state)
        } else {
            openPiP(for: state)
        }
    }

    func openPiP(for state: AppState) {
        guard !state.isFullScreen && !isTransitioning else { return }
        guard let currentItem = state.selectedItem, !currentItem.isDirectory else { return }
        
        isTransitioning = true
        closePiP(animated: false, state: state)

        if (currentItem.isVideo || currentItem.isAudio) && state.sharedPlayerViewModel.player == nil {
            state.sharedPlayerViewModel.setupPlayer(for: currentItem.url)
            state.sharedPlayerViewModel.player?.volume = Float(state.videoVolume)
        }

        let panelSize = calculatePanelSize(for: currentItem, state: state)
        let panel = PiPPanel(
            contentRect: NSRect(x: 100, y: 100, width: panelSize.width, height: panelSize.height),
            styleMask: [.borderless, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        
        let pipView = PiPContainerView(state: state)
        panel.contentView = NSHostingView(rootView: pipView)
        
        panel.orderFrontRegardless()
        panel.makeKey()
        self.pipWindow = panel

        if let mainWindow = WindowManager.primaryWindow {
            mainWindow.orderOut(nil)
        }
        
        isTransitioning = false
    }

    func updatePiPContentSize(for state: AppState) {
        guard let panel = pipWindow, let currentItem = state.selectedItem, !currentItem.isDirectory else { return }
        if currentItem.isVideo && state.sharedPlayerViewModel.assetNaturalSize == nil {
            return
        }
        
        let targetSize = calculatePanelSize(for: currentItem, state: state)
        var frame = panel.frame
        let oldHeight = frame.height
        let oldWidth = frame.width
        frame.size.width = targetSize.width
        frame.size.height = targetSize.height
        frame.origin.x += (oldWidth - targetSize.width) / 2
        frame.origin.y += (oldHeight - targetSize.height) / 2
        
        panel.setFrame(frame, display: true, animate: false)
    }

    func closePiP(animated: Bool = true, state: AppState? = nil) {
        if let window = pipWindow {
            window.orderOut(nil)
            pipWindow = nil
        }
        
        if let state = state, !state.isSlideshowActive {
            state.resetVideoState()
        }
        
        if let mainWindow = WindowManager.primaryWindow, !mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        
        isTransitioning = false
    }
    
    private func calculatePanelSize(for item: MediaItem, state: AppState) -> CGSize {
        let maxDimension = LayoutConstants.pipMaxDimension
        if item.isAudio {
            return CGSize(width: LayoutConstants.pipAudioWidth, height: LayoutConstants.pipAudioHeight)
        }
        
        var naturalSize: CGSize? = nil
        let didStart = item.url.startAccessingSecurityScopedResource()
        defer { if didStart { item.url.stopAccessingSecurityScopedResource() } }

        if item.isVideo {
            naturalSize = state.sharedPlayerViewModel.assetNaturalSize
        } else if item.isPDF {
            if let doc = PDFDocument(url: item.url), let page = doc.page(at: state.currentDocumentPage) {
                naturalSize = page.bounds(for: .mediaBox).size
            }
        } else {
            naturalSize = ImageLoader.loadFullImageSync(from: item.url)?.size
        }
        
        guard let size = naturalSize, size.width > 0, size.height > 0 else {
            let defaultHeight = item.isVideo ? (maxDimension * 9.0 / 16.0) : 300
            return CGSize(width: maxDimension, height: defaultHeight)
        }
        
        if size.width >= size.height {
            return CGSize(width: maxDimension, height: maxDimension * (size.height / size.width))
        } else {
            return CGSize(width: maxDimension * (size.width / size.height), height: maxDimension)
        }
    }
}

// MARK: - Shared Player Model
@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var assetNaturalSize: CGSize? = nil
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    @Published var isScrubbing: Bool = false
    
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private nonisolated(unsafe) var timeObserverToken: Any?
    private nonisolated(unsafe) var observedPlayer: AVPlayer?
    private static var sizeCache: [URL: CGSize] = [:]
    private var securityScopedURL: URL?
    private var sizeTask: Task<Void, Never>?
    
    var onVideoEnded: (() -> Void)?

    deinit {
        if let token = timeObserverToken, let player = observedPlayer {
            player.removeTimeObserver(token)
        }
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        statusObserver?.invalidate()
    }
    
    func setupPlayer(for url: URL) {
        cleanup()
        
        let didStart = url.startAccessingSecurityScopedResource()
        if didStart { securityScopedURL = url }
        
        if let cachedSize = Self.sizeCache[url] {
            self.assetNaturalSize = cachedSize
        }
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        statusObserver = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                if item.status == .failed {
                    self.onVideoEnded?()
                }
            }
        }
        
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                self.removeEndObserver()
                self.onVideoEnded?()
            }
        }
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer
        observedPlayer = newPlayer
        
        let interval = CMTime(seconds: LayoutConstants.periodicTimeInterval, preferredTimescale: 600)
        let token = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, self.player === newPlayer else { return }
                guard !self.isScrubbing else { return }
                self.currentTime = time.seconds
                if let dur = newPlayer.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                    self.duration = dur
                }
            }
        }
        timeObserverToken = token
        
        sizeTask = Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                guard !Task.isCancelled else { return }
                let size = try? await track.load(.naturalSize)
                let transform = try? await track.load(.preferredTransform)
                if let size = size, !Task.isCancelled {
                    let isRotated = (transform?.a == 0 && transform?.b == 1.0) || (transform?.a == 0 && transform?.b == -1.0)
                    let finalSize = isRotated ? CGSize(width: size.height, height: size.width) : size
                    Self.sizeCache[url] = finalSize
                    self.assetNaturalSize = finalSize
                }
            }
        }
        
        newPlayer.play()
    }
    
    func removeTimeObserver() {
        if let token = timeObserverToken, let player = observedPlayer {
            player.removeTimeObserver(token)
            timeObserverToken = nil
            observedPlayer = nil
        }
    }
    
    private func removeEndObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }
    
    func cleanup() {
        sizeTask?.cancel()
        sizeTask = nil
        statusObserver?.invalidate()
        statusObserver = nil
        removeTimeObserver()
        removeEndObserver()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        observedPlayer = nil
        assetNaturalSize = nil
        currentTime = 0
        duration = 1
        isScrubbing = false
        
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
    }
}

// MARK: - App Domain State
@MainActor
final class AppState: ObservableObject {
    @Published var currentFolder: URL?
    @Published var folderHistory: [FolderState] = []
    @Published var items: [MediaItem] = []
    @Published var isLoadingDirectory: Bool = false
    @Published var selectedIndex: Int = 0 {
        didSet {
            if PiPManager.shared.isPiPActive {
                PiPManager.shared.updatePiPContentSize(for: self)
            }
            preloadAdjacentItems()
        }
    }
    @Published var currentDocumentPage: Int = 0 {
        didSet {
            if PiPManager.shared.isPiPActive {
                PiPManager.shared.updatePiPContentSize(for: self)
            }
        }
    }
    @Published var totalDocumentPages: Int = 1
    
    @Published var isSlideshowActive: Bool = false
    @Published var isPaused: Bool = false
    @Published var delaySeconds: Int = 5
    @Published var videoVolume: Double = 1.0 {
        didSet {
            sharedPlayerViewModel.player?.volume = Float(videoVolume)
        }
    }
    @Published var gridColumnsCount: Int = 3
    @Published var showControlsSignal: Bool = false
    @Published var isDarkMode: Bool
    @Published var isFullScreen: Bool = false {
        didSet {
            if !isFullScreen {
                NSCursor.unhide()
            } else {
                PiPManager.shared.closePiP(state: self)
            }
        }
    }
    
    @Published var errorMessage: String? = nil
    
    let sharedPlayerViewModel = PlayerViewModel()
    private var currentPDFDocument: PDFDocument? = nil
    private var activeFolderSecurityScope: URL?
    
    @Published var isScrubbing: Bool = false
    @Published var scrubTargetTime: Double? = nil
    
    private var timer: Timer?
    private var lastSeekTime: Date = Date()
    private var seekAcceleration: Int = 1
    
    init() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.isDarkMode = isDark
        
        sharedPlayerViewModel.onVideoEnded = { [weak self] in
            guard let self = self else { return }
            self.isPaused = false
            if self.isSlideshowActive {
                self.moveSlideshowSelection(by: 1, userInitiated: false)
            } else {
                self.resetVideoState()
            }
            
            if PiPManager.shared.isPiPActive {
                PiPManager.shared.updatePiPContentSize(for: self)
            }
        }
    }
    
    var selectedItem: MediaItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }
    
    func resetVideoState() {
        isScrubbing = false
        scrubTargetTime = nil
        sharedPlayerViewModel.cleanup()
    }
    
    func loadCurrentDocument() {
        guard let item = selectedItem, item.isPDF else {
            currentPDFDocument = nil
            totalDocumentPages = 1
            return
        }
        
        let didStart = item.url.startAccessingSecurityScopedResource()
        defer { if didStart { item.url.stopAccessingSecurityScopedResource() } }
        
        if let doc = PDFDocument(url: item.url) {
            currentPDFDocument = doc
            totalDocumentPages = max(1, doc.pageCount)
        } else {
            currentPDFDocument = nil
            totalDocumentPages = 1
        }
    }
    
    func loadDirectory(_ url: URL, pushHistory: Bool = true) {
        NSCursor.unhide()
        PiPManager.shared.closePiP(state: self)
        errorMessage = nil
        
        if isSlideshowActive {
            isSlideshowActive = false
            timer?.invalidate()
            resetVideoState()
        }
        
        WindowManager.updateWindowForMode(.browser)
        
        if let window = WindowManager.primaryWindow {
            let contentWidth = window.contentView?.bounds.width ?? LayoutConstants.browserWidth
            let availableWidth = contentWidth - 40
            let calculatedCols = max(1, Int(availableWidth / LayoutConstants.cardWidth))
            self.gridColumnsCount = calculatedCols
        }
        
        var target = url
        var isDir: ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let isSingleFile = fileExists && !isDir.boolValue
        
        if isSingleFile {
            target = url.deletingLastPathComponent()
        }
        
        if pushHistory, let current = currentFolder {
            folderHistory.append(FolderState(url: current, selectedIndex: selectedIndex))
        }
        
        Task {
            await parseDirectoryAsync(target, resetIndex: true)
            if isSingleFile {
                if let matchedIndex = items.firstIndex(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                    selectedIndex = matchedIndex
                    startSlideshow(at: matchedIndex)
                }
            }
        }
    }
    
    private func parseDirectoryAsync(_ target: URL, resetIndex: Bool) async {
        isLoadingDirectory = true
        defer { isLoadingDirectory = false }
        
        if activeFolderSecurityScope != nil {
            activeFolderSecurityScope?.stopAccessingSecurityScopedResource()
            activeFolderSecurityScope = nil
        }
        
        if target.startAccessingSecurityScopedResource() {
            activeFolderSecurityScope = target
        }

        self.currentFolder = target
        let targetURL = target
        
        let parsedItems = await Task.detached(priority: .userInitiated) { () -> [MediaItem]? in
            let keys: [URLResourceKey] = [.isDirectoryKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: targetURL, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
                return nil
            }
            
            var folderItems: [MediaItem] = []
            var mediaItems: [MediaItem] = []
            
            for file in files {
                let resourceValues = try? file.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = resourceValues?.isDirectory ?? false
                let ext = file.pathExtension.lowercased()
                
                if isDirectory {
                    folderItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: true, isVideo: false, isAudio: false))
                } else if SupportedFormats.images.contains(ext) || SupportedFormats.documents.contains(ext) {
                    mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: false, isAudio: false))
                } else if SupportedFormats.videos.contains(ext) {
                    mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: true, isAudio: false))
                } else if SupportedFormats.audios.contains(ext) {
                    mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: false, isAudio: true))
                }
            }
            
            folderItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            mediaItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            
            return folderItems + mediaItems
        }.value

        if let result = parsedItems {
            self.items = result
            if resetIndex {
                self.selectedIndex = 0
            } else {
                self.selectedIndex = min(max(0, self.selectedIndex), max(0, self.items.count - 1))
            }
        } else {
            self.errorMessage = "Unable to read directory permissions."
            self.items = []
        }
    }
    
    func navigateBack() {
        NSCursor.unhide()
        PiPManager.shared.closePiP(state: self)
        errorMessage = nil
        if let previousState = folderHistory.popLast() {
            Task {
                await parseDirectoryAsync(previousState.url, resetIndex: false)
                self.selectedIndex = min(max(0, previousState.selectedIndex), max(0, self.items.count - 1))
                WindowManager.updateWindowForMode(.browser)
            }
        } else {
            currentFolder = nil
            items = []
            folderHistory.removeAll()
            selectedIndex = 0
            if let scope = activeFolderSecurityScope {
                scope.stopAccessingSecurityScopedResource()
                activeFolderSecurityScope = nil
            }
            WindowManager.updateWindowForMode(.dropzone)
        }
    }
    
    func startSlideshow(at index: Int? = nil) {
        if let idx = index { self.selectedIndex = idx }
        guard let item = selectedItem else { return }
        
        if item.isDirectory {
            loadDirectory(item.url)
            return
        }
        
        WindowManager.updateWindowForMode(.slideshow)
        resetVideoState()
        isSlideshowActive = true
        isPaused = false
        currentDocumentPage = 0
        loadCurrentDocument()
        
        if item.isVideo || item.isAudio {
            sharedPlayerViewModel.setupPlayer(for: item.url)
            sharedPlayerViewModel.player?.volume = Float(videoVolume)
        }
        
        resetTimer()
        preloadAdjacentItems()
    }
    
    func exitSlideshow() {
        isSlideshowActive = false
        timer?.invalidate()
        resetVideoState()
        NSCursor.unhide()
        PiPManager.shared.closePiP(state: self)
        
        if let folder = currentFolder {
            Task {
                await parseDirectoryAsync(folder, resetIndex: false)
                WindowManager.updateWindowForMode(.browser)
            }
        }
    }
    
    func moveSlideshowSelection(by delta: Int, userInitiated: Bool = true) {
        guard !items.isEmpty else { return }
        if userInitiated { triggerControls() }
        
        if let current = selectedItem, current.isPDF {
            if currentPDFDocument == nil { loadCurrentDocument() }
            
            let nextPage = currentDocumentPage + delta
            if nextPage >= 0 && nextPage < totalDocumentPages {
                currentDocumentPage = nextPage
                resetTimer()
                return
            }
        }
        
        var newIndex = selectedIndex
        let count = items.count
        
        for _ in 0..<count {
            newIndex += delta
            if newIndex >= count {
                newIndex = 0
            } else if newIndex < 0 {
                newIndex = count - 1
            }
            if !items[newIndex].isDirectory { break }
        }
        
        if let oldItem = selectedItem, (oldItem.isVideo || oldItem.isAudio) {
            resetVideoState()
        }
        
        selectedIndex = newIndex
        loadCurrentDocument()
        if delta < 0, let current = selectedItem, current.isPDF {
            currentDocumentPage = max(0, totalDocumentPages - 1)
        } else {
            currentDocumentPage = 0
        }
        
        if selectedItem?.isDirectory == true {
            exitSlideshow()
            return
        }
        
        if let current = selectedItem, (current.isVideo || current.isAudio) {
            isPaused = false
            sharedPlayerViewModel.setupPlayer(for: current.url)
            sharedPlayerViewModel.player?.volume = Float(videoVolume)
        }
        
        resetTimer()
    }

    func moveGridSelection(horizontal: Int = 0, vertical: Int = 0) {
        guard !items.isEmpty else { return }
        triggerControls()
        resetVideoState()
        
        let cols = max(1, gridColumnsCount)
        
        if horizontal != 0 {
            let newIndex = selectedIndex + horizontal
            if newIndex >= 0 && newIndex < items.count {
                selectedIndex = newIndex
            }
        } else if vertical != 0 {
            let newIndex = selectedIndex + (vertical * cols)
            if newIndex >= 0 && newIndex < items.count {
                selectedIndex = newIndex
            } else if vertical > 0 && selectedIndex < items.count - 1 {
                selectedIndex = items.count - 1
            } else if vertical < 0 && selectedIndex > 0 {
                selectedIndex = 0
            }
        }
    }
    
    func seekVideo(forward: Bool) {
        triggerControls()
        let now = Date()
        seekAcceleration = now.timeIntervalSince(lastSeekTime) < 0.25 ? min(seekAcceleration + 1, 3) : 1
        lastSeekTime = now
        
        guard let player = sharedPlayerViewModel.player else { return }
        let baseSeek: Double = 3.0
        let totalOffset = (forward ? 1.0 : -1.0) * baseSeek * Double(seekAcceleration)
        let maxDuration = sharedPlayerViewModel.duration
        let targetSeconds = min(max(0, player.currentTime().seconds + totalOffset), maxDuration)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        
        player.seek(to: targetTime, toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
    }
    
    func adjustDelay(by seconds: Int) {
        triggerControls()
        delaySeconds = min(max(1, delaySeconds + seconds), 60)
        resetTimer()
    }
    
    func adjustVolume(by amount: Double) {
        triggerControls()
        videoVolume = min(max(0.0, videoVolume + amount), 1.0)
    }
    
    func triggerControls() {
        showControlsSignal.toggle()
    }
    
    func resetTimer() {
        timer?.invalidate()
        guard isSlideshowActive, !isPaused, let current = selectedItem, !current.isVideo, !current.isAudio else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.moveSlideshowSelection(by: 1, userInitiated: false)
            }
        }
    }
    
    func toggleFullScreen() {
        guard let window = WindowManager.primaryWindow else { return }
        window.toggleFullScreen(nil)
    }
    
    func setFullScreenState(_ fullScreen: Bool) {
        isFullScreen = fullScreen
    }
    
    private func preloadAdjacentItems() {
        guard isSlideshowActive, !items.isEmpty else { return }
        let count = items.count
        let nextIndex = (selectedIndex + 1) % count
        let prevIndex = (selectedIndex - 1 + count) % count
        
        for idx in [nextIndex, prevIndex] {
            let item = items[idx]
            if !item.isDirectory && !item.isVideo && !item.isAudio {
                let url = item.url
                Task.detached(priority: .utility) {
                    _ = await ImageLoader.shared.loadFullImageAsync(from: url)
                }
            }
        }
    }
}

// MARK: - App Delegate & Application Lifecycle
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var state: AppState? {
        didSet {
            if let url = pendingURL, let state = state {
                pendingURL = nil
                Task { @MainActor in state.loadDirectory(url) }
            }
        }
    }
    var pendingURL: URL?
    var onFullScreenChange: ((Bool) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        closeExtraWindows()
        
        if let window = WindowManager.primaryWindow {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.delegate = self
            let layoutSpec = WindowManager.spec(for: .dropzone)
            window.setContentSize(NSSize(width: layoutSpec.width, height: layoutSpec.height))
            window.minSize = NSSize(width: layoutSpec.minWidth, height: layoutSpec.minHeight)
            window.maxSize = NSSize(width: layoutSpec.maxWidth, height: layoutSpec.maxHeight)
            window.styleMask.remove(.resizable)
        }
        
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            NSCursor.unhide()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        handleOpenURL(URL(fileURLWithPath: filename))
        return true
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        handleOpenURL(url)
    }
    
    @MainActor
    private func handleOpenURL(_ url: URL) {
        closeExtraWindows()
        if let state = state {
            state.loadDirectory(url)
            if let window = WindowManager.primaryWindow {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        } else {
            pendingURL = url
        }
    }
    
    private func closeExtraWindows() {
        let windows = NSApp.windows
        if windows.count > 1 {
            for window in windows.dropFirst() {
                if !window.isKind(of: PiPPanel.self) {
                    window.close()
                }
            }
        }
    }
    
    func windowDidEnterFullScreen(_ notification: Notification) {
        onFullScreenChange?(true)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        NSCursor.unhide()
        onFullScreenChange?(false)
    }
}

// MARK: - Reusable Slide Media Presenter
struct MediaSlideContentView: View {
    let item: MediaItem
    let pageIndex: Int
    @ObservedObject var playerViewModel: PlayerViewModel

    var body: some View {
        Group {
            if item.isAudio {
                AudioSlideView(url: item.url)
                    .id(item.id)
            } else if item.isVideo {
                SharedVideoView(viewModel: playerViewModel, gravity: .resizeAspect)
                    .id(item.id)
            } else if item.isPDF {
                PDFSlideView(url: item.url, pageIndex: pageIndex)
                    .id("\(item.id)_p\(pageIndex)")
            } else {
                PhotoSlideView(url: item.url)
                    .id(item.id)
            }
        }
    }
}

// MARK: - Picture-in-Picture Container View
struct PiPContainerView: View {
    @ObservedObject var state: AppState
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.black
            if let current = state.selectedItem, !current.isDirectory {
                MediaSlideContentView(
                    item: current,
                    pageIndex: state.currentDocumentPage,
                    playerViewModel: state.sharedPlayerViewModel
                )
            }
            
            if isHovered {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: { PiPManager.shared.closePiP(state: state) }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    state.isDarkMode ? Color.white : Color.black,
                                    state.isDarkMode ? Color.black.opacity(0.7) : Color.white.opacity(0.9)
                                )
                                .shadow(color: state.isDarkMode ? .black.opacity(0.3) : .white.opacity(0.3), radius: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                        .help("Exit Picture-in-Picture")
                    }
                    
                    Spacer()
                    
                    if let current = state.selectedItem, !current.isDirectory {
                        Button(action: {
                            state.isPaused.toggle()
                            if current.isVideo || current.isAudio {
                                if state.isPaused {
                                    state.sharedPlayerViewModel.player?.pause()
                                } else {
                                    state.sharedPlayerViewModel.player?.play()
                                }
                            }
                            state.resetTimer()
                        }) {
                            Image(systemName: state.isPaused ? "play.circle.fill" : "pause.circle.fill")
                                .font(.system(size: 44))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(
                                    state.isDarkMode ? Color.white : Color.black,
                                    state.isDarkMode ? Color.black.opacity(0.7) : Color.white.opacity(0.9)
                                )
                                .shadow(color: state.isDarkMode ? .black.opacity(0.3) : .white.opacity(0.3), radius: 4)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 20)
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onContinuousHover { phase in
            withAnimation(.easeInOut(duration: 0.15)) {
                switch phase {
                case .active(_): isHovered = true
                case .ended:     isHovered = false
                }
            }
        }
        .onChange(of: state.sharedPlayerViewModel.assetNaturalSize) { _, newSize in
            if newSize != nil { PiPManager.shared.updatePiPContentSize(for: state) }
        }
        .onChange(of: state.selectedIndex) { _, _ in
            PiPManager.shared.updatePiPContentSize(for: state)
        }
        .onChange(of: state.currentDocumentPage) { _, _ in
            PiPManager.shared.updatePiPContentSize(for: state)
        }
    }
}

// MARK: - Slide Renderers
struct SharedVideoView: NSViewRepresentable {
    @ObservedObject var viewModel: PlayerViewModel
    var gravity: AVLayerVideoGravity = .resizeAspect
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.player = viewModel.player
        playerView.videoGravity = gravity
        return playerView
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== viewModel.player {
            nsView.player = viewModel.player
        }
        nsView.videoGravity = gravity
    }
}

struct AudioSlideView: View {
    let url: URL
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 140, height: 140)
                Image(systemName: "waveform")
                    .font(.system(size: 60))
                    .foregroundColor(.white)
            }
            .shadow(radius: 10)
            
            Text(url.lastPathComponent)
                .font(.title2.bold())
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct PhotoSlideView: View {
    let url: URL
    @State private var image: NSImage?
    
    init(url: URL) {
        self.url = url
        let fullKey = ThumbnailCache.fullKey(for: url)
        let thumbKey = ThumbnailCache.key(for: url)
        let cached = ThumbnailCache.shared.object(forKey: fullKey) ?? ThumbnailCache.shared.object(forKey: thumbKey)
        _image = State(initialValue: cached)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: url) {
            if let fullImage = await ImageLoader.shared.loadFullImageAsync(from: url) {
                self.image = fullImage
            }
        }
    }
}

struct PDFSlideView: View {
    let url: URL
    let pageIndex: Int
    @State private var pageImage: NSImage?
    
    init(url: URL, pageIndex: Int) {
        self.url = url
        self.pageIndex = pageIndex
        let pdfKey = ThumbnailCache.pdfKey(for: url, page: pageIndex)
        let thumbKey = ThumbnailCache.key(for: url)
        let cached = ThumbnailCache.shared.object(forKey: pdfKey) ?? ThumbnailCache.shared.object(forKey: thumbKey)
        _pageImage = State(initialValue: cached)
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = pageImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    ProgressView()
                }
            }
        }
        .task(id: "\(url.absoluteString)_p\(pageIndex)") {
            if let rendered = await renderPDFPageAsync(url: url, pageIndex: pageIndex) {
                self.pageImage = rendered
            }
        }
    }
    
    private func renderPDFPageAsync(url: URL, pageIndex: Int) async -> NSImage? {
        let pdfKey = ThumbnailCache.pdfKey(for: url, page: pageIndex)
        if let cached = ThumbnailCache.shared.object(forKey: pdfKey) {
            return cached
        }
        return await Task.detached(priority: .userInitiated) { () -> NSImage? in
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            guard let doc = PDFDocument(url: url), let page = doc.page(at: pageIndex) else { return nil }
            let pageRect = page.bounds(for: .mediaBox)
            let image = NSImage(size: pageRect.size)
            
            image.lockFocus()
            if let context = NSGraphicsContext.current?.cgContext {
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(origin: .zero, size: pageRect.size))
                page.draw(with: .mediaBox, to: context)
            }
            image.unlockFocus()
            let cost = Int(pageRect.width * pageRect.height * 4)
            ThumbnailCache.shared.setObject(image, forKey: pdfKey, cost: cost)
            return image
        }.value
    }
}

// MARK: - Dropzone View
struct DropzoneView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button(action: { state.isDarkMode.toggle() }) {
                    Image(systemName: state.isDarkMode ? "sun.max.fill" : "moon.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .padding()
            }
            Text("📁").font(.system(size: 80))
            Text("Drop Media or Folders Here").font(.largeTitle.bold())
            Text("Supports images, videos, audio, and PDFs").font(.title3).foregroundColor(.secondary)
            
            Button("📂 Choose Folder") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    state.loadDirectory(url)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(state.isDarkMode ? Color.black : Color(NSColor.windowBackgroundColor))
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Gallery Components
struct GalleryCardView: View {
    let item: MediaItem
    let isSelected: Bool
    let isDarkMode: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovered: Bool = false
    
    init(item: MediaItem, isSelected: Bool, isDarkMode: Bool, action: @escaping () -> Void) {
        self.item = item
        self.isSelected = isSelected
        self.isDarkMode = isDarkMode
        self.action = action
        let key = ThumbnailCache.key(for: item.url)
        _thumbnail = State(initialValue: ThumbnailCache.shared.object(forKey: key))
    }
    
    var body: some View {
        let activeColor = isHovered ? Color.green : (isSelected ? Color.blue : Color.clear)
        let bgColor = isHovered ? Color.green.opacity(0.3) : (isSelected ? Color.blue.opacity(0.4) : (isDarkMode ? Color.white.opacity(0.1) : Color.black.opacity(0.05)))
        
        Group {
            if item.isDirectory {
                VStack(spacing: 8) {
                    Text("📁").font(.system(size: 64))
                    Text(item.name)
                        .font(.body.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if item.isAudio {
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(LinearGradient(colors: [.purple.opacity(0.7), .blue.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                            .foregroundColor(.white)
                    }
                    .frame(width: LayoutConstants.thumbnailWidth, height: LayoutConstants.thumbnailHeight)
                    
                    Text(item.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else if item.isVideo {
                VStack(spacing: 6) {
                    Group {
                        if let thumbnail = thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            ProgressView()
                        }
                    }
                    .frame(width: LayoutConstants.thumbnailWidth, height: LayoutConstants.thumbnailHeight)
                    
                    Text(item.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .task(id: item.url) {
                    if thumbnail == nil {
                        thumbnail = await ImageLoader.shared.loadThumbnail(for: item, size: CGSize(width: LayoutConstants.thumbnailLargeWidth, height: LayoutConstants.thumbnailLargeHeight))
                    }
                }
            } else {
                VStack(spacing: 6) {
                    Group {
                        if let thumbnail = thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: LayoutConstants.thumbnailWidth, height: 160)
                        } else {
                            ProgressView()
                        }
                    }
                    
                    Text(item.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .task(id: item.url) {
                    if thumbnail == nil {
                        thumbnail = await ImageLoader.shared.loadThumbnail(for: item, size: CGSize(width: LayoutConstants.thumbnailLargeWidth, height: 320))
                    }
                }
            }
        }
        .padding(8)
        .frame(width: 240, height: LayoutConstants.cardHeight)
        .background(bgColor)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(activeColor, lineWidth: 4)
        )
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
        .onTapGesture { action() }
    }
}

struct GalleryView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if !state.folderHistory.isEmpty || state.currentFolder != nil {
                    Button(action: { state.navigateBack() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 12, weight: .bold))
                            Text(state.folderHistory.last?.url.lastPathComponent ?? "Back")
                                .font(.body.bold())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .help("Back to previous folder (Esc)")
                }
                
                Text("📁 \(state.currentFolder?.lastPathComponent ?? "Gallery")")
                    .font(.title.bold())
                
                Spacer()
                
                Button(action: { state.toggleFullScreen() }) {
                    Image(systemName: state.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.plain)
                .help("Toggle Fullscreen")
                
                Button(action: { state.isDarkMode.toggle() }) {
                    Image(systemName: state.isDarkMode ? "sun.max.fill" : "moon.fill")
                }
                .buttonStyle(.plain)
                .help("Toggle Theme")
            }
            .padding()
            
            if let error = state.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.bottom, 8)
            }
            
            if state.isLoadingDirectory {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading \(state.currentFolder?.lastPathComponent ?? "Folder")...")
                        .font(.title3.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No supported media files found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GeometryReader { geometry in
                    let availableWidth = geometry.size.width - 40
                    let cols = max(1, Int(availableWidth / LayoutConstants.cardWidth))
                    
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 24), count: cols), spacing: 24) {
                                ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                                    GalleryCardView(item: item, isSelected: index == state.selectedIndex, isDarkMode: state.isDarkMode) {
                                        state.startSlideshow(at: index)
                                    }
                                    .id(index)
                                }
                            }
                            .padding()
                        }
                        .id(state.currentFolder)
                        .onAppear {
                            state.gridColumnsCount = cols
                            proxy.scrollTo(state.selectedIndex, anchor: .center)
                        }
                        .onChange(of: cols) { _, _ in state.gridColumnsCount = cols }
                        .onChange(of: state.selectedIndex) { _, newIndex in
                            proxy.scrollTo(newIndex, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(state.isDarkMode ? Color.black : Color(NSColor.windowBackgroundColor))
        .onAppear { NSCursor.unhide() }
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Modularized Slideshow Sub-Components
struct MediaScrubberView: View {
    @ObservedObject var playerViewModel: PlayerViewModel
    @ObservedObject var state: AppState

    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(formatTime(playerViewModel.currentTime))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white)
            
            Slider(
                value: Binding(
                    get: { min(max(0, playerViewModel.currentTime), playerViewModel.duration) },
                    set: { newValue in
                        playerViewModel.currentTime = newValue
                        let target = CMTime(seconds: newValue, preferredTimescale: 600)
                        playerViewModel.player?.seek(to: target, toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
                    }
                ),
                in: 0...max(1.0, playerViewModel.duration),
                onEditingChanged: { editing in
                    playerViewModel.isScrubbing = editing
                    state.isScrubbing = editing
                    state.triggerControls()
                }
            )
            .accentColor(.blue)
            .frame(maxWidth: .infinity)
            
            Text(formatTime(playerViewModel.duration))
                .font(.caption.monospacedDigit())
                .foregroundColor(.white.opacity(0.7))
        }
    }
}

struct VolumeControlView: View {
    @ObservedObject var state: AppState
    let isCompact: Bool
    @Binding var showVolumePopover: Bool

    var body: some View {
        if isCompact {
            Button(action: { showVolumePopover.toggle() }) {
                Image(systemName: state.videoVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.body)
            }
            .buttonStyle(.plain)
            .help("Volume Settings")
            .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
                VStack(spacing: 8) {
                    Text("Volume: \(Int((state.videoVolume * 100).rounded()))%")
                        .font(.caption.bold())
                    Slider(
                        value: $state.videoVolume,
                        in: 0...1.0,
                        onEditingChanged: { _ in state.triggerControls() }
                    )
                    .accentColor(.blue)
                    .frame(width: 140)
                }
                .padding(12)
                .background(Color.black.opacity(0.9))
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: state.videoVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundColor(.white.opacity(0.8))
                    .font(.caption)
                Slider(
                    value: $state.videoVolume,
                    in: 0...1.0,
                    onEditingChanged: { _ in state.triggerControls() }
                )
                .accentColor(.blue)
                .frame(width: 90)
            }
        }
    }
}

struct SlideshowControlBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var playerViewModel: PlayerViewModel
    @Binding var showVolumePopover: Bool
    let totalWidth: CGFloat

    var body: some View {
        let isMediaPlayback = (state.selectedItem?.isVideo ?? false) || (state.selectedItem?.isAudio ?? false)
        let isReallyWideMedia = isMediaPlayback && totalWidth > 900
        let isWide = totalWidth > 600
        let panelWidth: CGFloat = isMediaPlayback
            ? (isReallyWideMedia ? min(totalWidth * 0.90, 900) : (isWide ? totalWidth * 0.90 : totalWidth - 32))
            : (isWide ? min(totalWidth * 0.9, 500) : totalWidth - 32)
        let isCompactAudio = totalWidth < 600

        VStack(spacing: 12) {
            if isReallyWideMedia {
                HStack(spacing: 16) {
                    controlButtons
                    Divider().frame(height: 20).background(Color.white.opacity(0.2))
                    MediaScrubberView(playerViewModel: playerViewModel, state: state)
                    Divider().frame(height: 20).background(Color.white.opacity(0.2))
                    VolumeControlView(state: state, isCompact: false, showVolumePopover: $showVolumePopover)
                    Divider().frame(height: 20).background(Color.white.opacity(0.2))
                    utilityButtons
                }
            } else {
                HStack(spacing: 16) {
                    controlButtons
                    Spacer()
                    slideInfoControls
                    utilityButtons
                }
                
                if let current = state.selectedItem, current.isVideo || current.isAudio {
                    Divider().background(Color.white.opacity(0.2))
                    HStack(spacing: 12) {
                        MediaScrubberView(playerViewModel: playerViewModel, state: state)
                        VolumeControlView(state: state, isCompact: isCompactAudio, showVolumePopover: $showVolumePopover)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(width: panelWidth)
        .background(Color.black.opacity(0.85))
        .cornerRadius(12)
        .foregroundColor(.white)
    }

    @ViewBuilder
    private var controlButtons: some View {
        Group {
            Button(action: { state.moveSlideshowSelection(by: -1) }) {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.plain)
            .help("Previous Item")
            
            Button(action: {
                state.isPaused.toggle()
                if let current = state.selectedItem, current.isVideo || current.isAudio {
                    if state.isPaused {
                        playerViewModel.player?.pause()
                    } else {
                        playerViewModel.player?.play()
                    }
                }
                state.resetTimer()
            }) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(state.isPaused ? "Play" : "Pause")
            
            Button(action: { state.moveSlideshowSelection(by: 1) }) {
                Image(systemName: "forward.end.fill")
            }
            .buttonStyle(.plain)
            .help("Next Item")
        }
    }

    @ViewBuilder
    private var slideInfoControls: some View {
        if let current = state.selectedItem, !current.isDirectory, !current.isVideo && !current.isAudio {
            HStack(spacing: 12) {
                if current.isPDF {
                    Text("Page \(state.currentDocumentPage + 1) of \(state.totalDocumentPages)")
                        .font(.caption.bold())
                        .foregroundColor(.white.opacity(0.8))
                }
                
                Stepper("Delay: \(state.delaySeconds)s", value: $state.delaySeconds, in: 1...60)
                    .onChange(of: state.delaySeconds) { _, _ in
                        state.resetTimer()
                    }
            }
        }
    }
    
    @ViewBuilder
    private var utilityButtons: some View {
        Group {
            if !state.isFullScreen {
                Button(action: { PiPManager.shared.togglePiP(for: state) }) {
                    Image(systemName: "pip.enter")
                }
                .buttonStyle(.plain)
                .help("Toggle Picture-in-Picture (P)")
            }

            Button(action: { state.toggleFullScreen() }) {
                Image(systemName: state.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Toggle Fullscreen")
            
            Button("✕ Exit") { state.exitSlideshow() }
                .buttonStyle(.plain)
        }
    }
}

// MARK: - Slideshow View & Main Overlay
struct SlideshowView: View {
    @ObservedObject var state: AppState
    @ObservedObject var playerViewModel: PlayerViewModel
    
    @State private var showControls = false
    @State private var controlsTimer: Timer?
    @State private var cursorHideTimer: Timer?
    @State private var isCursorHidden = false
    @State private var showVolumePopover = false
    @State private var lastMouseActivityTime = Date.distantPast
    
    init(state: AppState) {
        self.state = state
        self.playerViewModel = state.sharedPlayerViewModel
    }
    
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.edgesIgnoringSafeArea(.all)
                    .onTapGesture(count: 2) {
                        state.toggleFullScreen()
                    }
                    .onTapGesture(count: 1) {
                        handleMouseActivity()
                    }
                
                if let current = state.selectedItem, !current.isDirectory {
                    MediaSlideContentView(
                        item: current,
                        pageIndex: state.currentDocumentPage,
                        playerViewModel: playerViewModel
                    )
                }
                
                if showControls {
                    VStack {
                        Spacer()
                        SlideshowControlBar(
                            state: state,
                            playerViewModel: playerViewModel,
                            showVolumePopover: $showVolumePopover,
                            totalWidth: proxy.size.width
                        )
                        .padding(.bottom, state.isFullScreen ? 75 : 16)
                    }
                    .transition(.opacity)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                handleMouseActivity()
            case .ended:
                break
            }
        }
        .onAppear {
            showControls = true
            NSCursor.unhide()
            isCursorHidden = false
            resetAutoHideTimers()
        }
        .onDisappear {
            NSCursor.unhide()
            cursorHideTimer?.invalidate()
            controlsTimer?.invalidate()
        }
        .onChange(of: state.showControlsSignal) { _, _ in triggerControls() }
        .onChange(of: state.isFullScreen) { _, isFull in
            if !isFull {
                NSCursor.unhide()
                isCursorHidden = false
                cursorHideTimer?.invalidate()
            } else {
                resetAutoHideTimers()
            }
        }
    }
    
    private func handleMouseActivity() {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        }
        
        if !showControls {
            withAnimation(.easeOut(duration: 0.2)) {
                showControls = true
            }
        }
        
        let now = Date()
        if now.timeIntervalSince(lastMouseActivityTime) > 0.25 {
            lastMouseActivityTime = now
            resetAutoHideTimers()
        }
    }
    
    private func triggerControls() {
        if !showControls {
            withAnimation(.easeOut(duration: 0.2)) { showControls = true }
        }
        resetAutoHideTimers()
    }
    
    private func resetAutoHideTimers() {
        controlsTimer?.invalidate()
        cursorHideTimer?.invalidate()
        
        guard !state.isScrubbing && !showVolumePopover else { return }
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: LayoutConstants.autoHideDelay, repeats: false) { _ in
            Task { @MainActor in
                withAnimation(.easeIn(duration: 0.25)) { showControls = false }
            }
        }
        
        if state.isFullScreen {
            cursorHideTimer = Timer.scheduledTimer(withTimeInterval: LayoutConstants.autoHideDelay, repeats: false) { _ in
                Task { @MainActor in
                    guard state.isFullScreen, !state.isScrubbing, !showVolumePopover else { return }
                    if !isCursorHidden {
                        NSCursor.hide()
                        isCursorHidden = true
                    }
                }
            }
        }
    }
}

// MARK: - Keyboard Command Handler
@MainActor
enum KeyCommandHandler {
    static func handle(event: NSEvent, state: AppState) -> NSEvent? {
        guard let primaryWindow = WindowManager.primaryWindow,
              primaryWindow === event.window || NSApp.windows.contains(where: { $0 === event.window }) else {
            return event
        }
        
        let isCommandPressed = event.modifierFlags.contains(.command)
        if state.isSlideshowActive { NSCursor.unhide() }
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""
        
        if characters == "f" {
            state.toggleFullScreen()
            return nil
        }
        
        if characters == "p" {
            PiPManager.shared.togglePiP(for: state)
            return nil
        }
        
        switch event.keyCode {
        case KeyCode.rightArrow:
            if isCommandPressed && state.isSlideshowActive, let current = state.selectedItem, (current.isVideo || current.isAudio) {
                state.seekVideo(forward: true)
            } else if state.isSlideshowActive {
                state.moveSlideshowSelection(by: 1)
            } else {
                state.moveGridSelection(horizontal: 1)
            }
            return nil
            
        case KeyCode.leftArrow:
            if isCommandPressed && state.isSlideshowActive, let current = state.selectedItem, (current.isVideo || current.isAudio) {
                state.seekVideo(forward: false)
            } else if state.isSlideshowActive {
                state.moveSlideshowSelection(by: -1)
            } else {
                state.moveGridSelection(horizontal: -1)
            }
            return nil
            
        case KeyCode.downArrow:
            if state.isSlideshowActive {
                if let current = state.selectedItem, current.isVideo || current.isAudio {
                    state.adjustVolume(by: -0.1)
                } else {
                    state.adjustDelay(by: -1)
                }
            } else {
                state.moveGridSelection(vertical: 1)
            }
            return nil
            
        case KeyCode.upArrow:
            if state.isSlideshowActive {
                let current = state.selectedItem
                if current?.isVideo == true || current?.isAudio == true {
                    state.adjustVolume(by: 0.1)
                } else {
                    state.adjustDelay(by: 1)
                }
            } else {
                state.moveGridSelection(vertical: -1)
            }
            return nil
            
        case KeyCode.returnKey, KeyCode.enterKey:
            state.triggerControls()
            if !state.isSlideshowActive {
                state.startSlideshow()
            }
            return nil
            
        case KeyCode.spaceKey:
            state.triggerControls()
            if state.isSlideshowActive || PiPManager.shared.isPiPActive {
                state.isPaused.toggle()
                if let current = state.selectedItem, current.isVideo || current.isAudio {
                    if state.isPaused {
                        state.sharedPlayerViewModel.player?.pause()
                    } else {
                        state.sharedPlayerViewModel.player?.play()
                    }
                }
                state.resetTimer()
            }
            return nil
            
        case KeyCode.escapeKey:
            if PiPManager.shared.isPiPActive {
                PiPManager.shared.closePiP(state: state)
                return nil
            }
            if state.isSlideshowActive {
                state.exitSlideshow()
            } else if state.currentFolder != nil {
                state.navigateBack()
            }
            return nil
            
        default:
            return event
        }
    }
}

// MARK: - Root View & Unified Event Interceptor
struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var keyMonitor: Any?
    
    var body: some View {
        Group {
            if state.isSlideshowActive {
                SlideshowView(state: state)
            } else if state.currentFolder != nil {
                GalleryView(state: state)
            } else {
                DropzoneView(state: state)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in state.loadDirectory(url) }
                }
            }
            return true
        }
        .onAppear {
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    KeyCommandHandler.handle(event: event, state: state)
                }
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
    }
}

// MARK: - Application Main Entry
@main
struct SimpleSlideshowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .preferredColorScheme(state.isDarkMode ? .dark : .light)
                .onAppear {
                    appDelegate.state = state
                    appDelegate.onFullScreenChange = { isFullScreenIn in
                        Task { @MainActor in
                            state.setFullScreenState(isFullScreenIn)
                        }
                    }
                }
        }
        .defaultSize(width: LayoutConstants.dropzoneWidth, height: LayoutConstants.dropzoneHeight)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}