import SwiftUI
import AVKit
import QuickLookThumbnailing
import AppKit
import UniformTypeIdentifiers
import MediaPlayer

// MARK: - App Delegate & File Open Handling
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURL: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        if let window = NSApp.windows.first {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .black
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        onOpenURL?(url)
    }
}

// MARK: - Models & Cache
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let isVideo: Bool
    let isBackAction: Bool
    
    var isMedia: Bool { !isDirectory && !isBackAction }
}

final class ThumbnailCache {
    static let shared = NSCache<NSString, NSImage>()
}

// MARK: - Concurrency Safety Box
final class SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) {
        self.value = value
    }
}

// MARK: - Async Thumbnail & Image Loader / Video Converter
actor ImageLoader {
    static func loadThumbnail(for item: MediaItem, size: CGSize) async -> NSImage? {
        let key = NSString(string: item.url.path)
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            return cached
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
            ThumbnailCache.shared.setObject(image, forKey: key)
            return image
        } catch {
            return nil
        }
    }
    
    static func loadFullImage(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
    
    // Dynamically converts an image into a temporary looping video optimized for LG TV AirPlay compatibility (720p, H.264 Main, MP4)
    static func generateAirPlayVideo(for imageUrl: URL) async -> URL? {
        guard let image = loadFullImage(from: imageUrl),
              let initialCGImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("AirPlay Video Debug: Failed to load image or cgImage from \(imageUrl)")
            return nil
        }
        
        let width = 1280
        let height = 720
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        
        guard let offscreenContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            print("AirPlay Video Debug: Failed to create offscreen context for materialization.")
            return nil
        }
        
        offscreenContext.setFillColor(NSColor.black.cgColor)
        offscreenContext.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        let initialImageRect = AVMakeRect(aspectRatio: CGSize(width: initialCGImage.width, height: initialCGImage.height), insideRect: CGRect(x: 0, y: 0, width: width, height: height))
        offscreenContext.draw(initialCGImage, in: initialImageRect)
        
        guard let cgImage = offscreenContext.makeImage() else {
            print("AirPlay Video Debug: Failed to make materialized CGImage.")
            return nil
        }
        
        let fileManager = FileManager.default
        let cacheDir = fileManager.temporaryDirectory
        let outputURL = cacheDir.appendingPathComponent("\(UUID().uuidString).mp4")
        
        if fileManager.fileExists(atPath: outputURL.path) {
            try? fileManager.removeItem(at: outputURL)
        }
        
        guard let videoWriter = try? AVAssetWriter(outputURL: outputURL, fileType: .mp4) else {
            print("AirPlay Video Debug: Failed to initialize AVAssetWriter.")
            return nil
        }
        
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel
            ]
        ]
        
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        
        let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )
        
        guard videoWriter.canAdd(writerInput) else {
            print("AirPlay Video Debug: Cannot add writer input to videoWriter.")
            return nil
        }
        videoWriter.add(writerInput)
        
        guard videoWriter.startWriting() else {
            print("AirPlay Video Debug: Failed to start writing. Error: \(String(describing: videoWriter.error))")
            return nil
        }
        videoWriter.startSession(atSourceTime: .zero)
        
        let fps: Int32 = 30
        let durationSeconds: Double = 3.0
        let totalFrames = Int(Double(fps) * durationSeconds)
        
        let queue = DispatchQueue(label: "media.slideshow.videogen")
        
        let writerBox = SendableBox(videoWriter)
        let inputBox = SendableBox(writerInput)
        let adaptorBox = SendableBox(pixelBufferAdaptor)
        
        let createBufferedPixelBuffer: (CGImage, Int, Int, AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? = { img, w, h, adapt in
            var pxBuffer: CVPixelBuffer?
            let pool = adapt.pixelBufferPool
            
            let status: CVReturn
            if let pixelBufferPool = pool {
                status = CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferPool, &pxBuffer)
            } else {
                status = CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, sourcePixelBufferAttributes as CFDictionary, &pxBuffer)
            }
            
            guard status == kCVReturnSuccess, let pixelBuffer = pxBuffer else {
                return nil
            }
            
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            
            let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return nil
            }
            
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            
            return pixelBuffer
        }
        
        await withCheckedContinuation { continuation in
            inputBox.value.requestMediaDataWhenReady(on: queue) {
                let writer = writerBox.value
                let input = inputBox.value
                let adaptor = adaptorBox.value
                
                var frameIndex = 0
                while frameIndex < totalFrames {
                    if input.isReadyForMoreMediaData {
                        let presentationTime = CMTime(value: Int64(frameIndex), timescale: fps)
                        
                        if let pixelBuffer = createBufferedPixelBuffer(cgImage, width, height, adaptor) {
                            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                        }
                        frameIndex += 1
                    } else {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                }
                
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .failed {
                        print("AirPlay Video Debug: Writing failed with error: \(String(describing: writer.error))")
                    } else if writer.status == .completed {
                        do {
                            let attr = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                            let fileSize = attr[.size] as? Int ?? 0
                            print("AirPlay Video Debug: Successfully generated video at \(outputURL), size: \(fileSize) bytes")
                        } catch {
                            print("AirPlay Video Debug: File attributes error: \(error)")
                        }
                    }
                    continuation.resume(returning: ())
                }
            }
        }
        
        return outputURL
    }

    nonisolated private static func createPixelBuffer(from cgImage: CGImage, width: Int, height: Int, adaptor: AVAssetWriterInputPixelBufferAdaptor) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool else {
            print("AirPlay Video Debug: Pixel buffer pool is nil.")
            return nil
        }
        var pxBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pxBuffer)
        guard status == kCVReturnSuccess, let buffer = pxBuffer else {
            print("AirPlay Video Debug: Failed to create pixel buffer from pool with status: \(status)")
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        
        context?.setFillColor(NSColor.black.cgColor)
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        
        let imageRect = AVMakeRect(aspectRatio: CGSize(width: cgImage.width, height: cgImage.height), insideRect: CGRect(x: 0, y: 0, width: width, height: height))
        context?.draw(cgImage, in: imageRect)
        
        return buffer
    }
}

// MARK: - Navigation History State
struct FolderState {
    let url: URL
    var selectedIndex: Int
}

// MARK: - App State (Updated with AirPlay Video Caching)
@MainActor
final class AppState: ObservableObject {
    @Published var currentFolder: URL?
    @Published var folderHistory: [FolderState] = []
    @Published var items: [MediaItem] = []
    @Published var selectedIndex: Int = 0
    @Published var isSlideshowActive: Bool = false
    @Published var isPaused: Bool = false
    @Published var delaySeconds: Int = 5
    @Published var gridColumnsCount: Int = 3
    @Published var seekTrigger: (direction: Int, count: Int)? = nil
    @Published var showControlsSignal: Bool = false
    @Published var airplayTriggerSignal: Bool = false
    @Published var isAirPlayActive: Bool = false
    
    // Video & Photo AirPlay Progress Tracking
    @Published var videoCurrentTime: Double = 0
    @Published var videoDuration: Double = 1
    @Published var isScrubbing: Bool = false
    @Published var scrubTargetTime: Double? = nil
    @Published var photoAirPlayVideoURL: URL? = nil
    
    // Cache to prevent regenerating and disconnecting AirPlay streams for previously loaded photos
    private var photoAirPlayVideoCache: [URL: URL] = [:]
    
    private var timer: Timer?
    private var lastSeekTime: Date = Date()
    private var seekAcceleration: Int = 1
    
    var selectedItem: MediaItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }
    
    func resetVideoState() {
        videoCurrentTime = 0
        videoDuration = 1
        isScrubbing = false
        scrubTargetTime = nil
        seekTrigger = nil
        photoAirPlayVideoURL = nil
    }
    
    func loadDirectory(_ url: URL, pushHistory: Bool = true) {
        NSCursor.unhide()
        var target = url
        var isDir: ObjCBool = false
        
        let fileExists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        
        if fileExists && !isDir.boolValue {
            target = url.deletingLastPathComponent()
            
            if pushHistory, let current = currentFolder {
                folderHistory.append(FolderState(url: current, selectedIndex: selectedIndex))
            }
            
            parseDirectory(target, resetIndex: true)
            
            if let matchedIndex = items.firstIndex(where: { $0.url.standardizedFileIOPassed == url.standardizedFileIOPassed }) {
                selectedIndex = matchedIndex
                startSlideshow(at: matchedIndex)
            }
            return
        }
        
        if pushHistory, let current = currentFolder {
            folderHistory.append(FolderState(url: current, selectedIndex: selectedIndex))
        }
        
        parseDirectory(target, resetIndex: true)
        setFullScreen(true)
    }
    
    private func parseDirectory(_ target: URL, resetIndex: Bool = true) {
        self.items = []
        if resetIndex {
            self.selectedIndex = 0
        }
        self.currentFolder = target
        
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
            return
        }
        
        let validImageExts = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff"]
        let validVideoExts = ["mp4", "mkv", "mov", "avi"]
        
        var folderItems: [MediaItem] = []
        var mediaItems: [MediaItem] = []
        
        for file in files {
            let resourceValues = try? file.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let ext = file.pathExtension.lowercased()
            
            if isDirectory {
                folderItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: true, isVideo: false, isBackAction: false))
            } else if validImageExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: false, isBackAction: false))
            } else if validVideoExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: true, isBackAction: false))
            }
        }
        
        folderItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        mediaItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        var combinedItems: [MediaItem] = []
        if currentFolder != nil || !folderHistory.isEmpty {
            let backItem = MediaItem(url: target, name: ".. (Back)", isDirectory: false, isVideo: false, isBackAction: true)
            combinedItems.append(backItem)
        }
        
        combinedItems.append(contentsOf: folderItems)
        combinedItems.append(contentsOf: mediaItems)
        
        self.items = combinedItems
        if resetIndex {
            self.selectedIndex = 0
        } else {
            self.selectedIndex = min(max(0, self.selectedIndex), max(0, self.items.count - 1))
        }
        setFullScreen(true)
    }
    
    func navigateBack() {
        NSCursor.unhide()
        if let previousState = folderHistory.popLast() {
            parseDirectory(previousState.url, resetIndex: false)
            selectedIndex = min(max(0, previousState.selectedIndex), max(0, items.count - 1))
        } else {
            currentFolder = nil
            items = []
            folderHistory.removeAll()
            selectedIndex = 0
            setFullScreen(false)
        }
    }
    
    func startSlideshow(at index: Int? = nil) {
        if let idx = index { self.selectedIndex = idx }
        guard let item = selectedItem else { return }
        
        if item.isBackAction {
            navigateBack()
            return
        }
        
        if item.isDirectory {
            loadDirectory(item.url)
            return
        }
        
        resetVideoState()
        isSlideshowActive = true
        setFullScreen(true)
        prepareCurrentMediaForAirPlay()
        resetTimer()
    }
    
    func exitSlideshow() {
        isSlideshowActive = false
        timer?.invalidate()
        resetVideoState()
        NSCursor.unhide()
        
        if let folder = currentFolder {
            parseDirectory(folder, resetIndex: false)
            setFullScreen(true)
        } else {
            setFullScreen(false)
        }
    }
    
    func moveSlideshowSelection(by delta: Int, userInitiated: Bool = true) {
        guard !items.isEmpty else { return }
        if userInitiated {
            triggerControls()
        }
        resetVideoState()
        
        var newIndex = selectedIndex + delta
        if newIndex >= items.count {
            newIndex = 0
        } else if newIndex < 0 {
            newIndex = items.count - 1
        }
        selectedIndex = newIndex
        prepareCurrentMediaForAirPlay()
        resetTimer()
    }
    
    func prepareCurrentMediaForAirPlay() {
        guard let item = selectedItem, !item.isVideo, !item.isDirectory, !item.isBackAction else {
            self.photoAirPlayVideoURL = nil
            return
        }
        let url = item.url
        
        // Return instantly from cache if already generated to maintain smooth TV transitions
        if let cachedURL = photoAirPlayVideoCache[url] {
            self.photoAirPlayVideoURL = cachedURL
            return
        }
        
        Task {
            let videoURL = await ImageLoader.generateAirPlayVideo(for: url)
            await MainActor.run {
                if let videoURL = videoURL {
                    self.photoAirPlayVideoCache[url] = videoURL
                }
                if self.selectedItem?.url == url {
                    self.photoAirPlayVideoURL = videoURL
                }
            }
        }
    }
    
    func moveGridSelection(horizontal: Int = 0, vertical: Int = 0) {
        guard !items.isEmpty else { return }
        triggerControls()
        resetVideoState()
        
        let cols = max(1, gridColumnsCount)
        let currentRow = selectedIndex / cols
        let currentCol = selectedIndex % cols
        
        if horizontal != 0 {
            let newCol = currentCol + horizontal
            if newCol >= 0 && newCol < cols {
                let newIndex = currentRow * cols + newCol
                if newIndex < items.count {
                    selectedIndex = newIndex
                }
            }
        } else if vertical != 0 {
            let newRow = currentRow + vertical
            let maxRow = max(0, (items.count - 1) / cols)
            if newRow >= 0 && newRow <= maxRow {
                let targetCol = min(currentCol, (newRow == maxRow) ? max(0, (items.count - 1) % cols) : (cols - 1))
                let newIndex = newRow * cols + targetCol
                if newIndex < items.count {
                    selectedIndex = newIndex
                }
            }
        }
    }
    
    func seekVideo(forward: Bool) {
        triggerControls()
        let now = Date()
        if now.timeIntervalSince(lastSeekTime) < 0.25 {
            seekAcceleration = min(seekAcceleration + 1, 3)
        } else {
            seekAcceleration = 1
        }
        lastSeekTime = now
        seekTrigger = (direction: forward ? 1 : -1, count: seekAcceleration)
    }
    
    func adjustDelay(by seconds: Int) {
        triggerControls()
        let newDelay = delaySeconds + seconds
        delaySeconds = min(max(1, newDelay), 60)
        resetTimer()
    }
    
    func triggerControls() {
        showControlsSignal.toggle()
    }
    
    func triggerAirPlay() {
        triggerControls()
        airplayTriggerSignal.toggle()
    }
    
    func resetTimer() {
        timer?.invalidate()
        guard isSlideshowActive, !isPaused, let current = selectedItem, !current.isVideo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delaySeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.moveSlideshowSelection(by: 1, userInitiated: false)
            }
        }
    }
    
    func setFullScreen(_ enable: Bool) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if (enable && !isFull) || (!enable && isFull) {
            window.toggleFullScreen(nil)
        }
    }
}

private extension URL {
    var standardizedFileIOPassed: URL {
        return self.standardizedFileURL
    }
}

// MARK: - AirPlay Route Picker Wrapper View
struct AirPlayRoutePickerView: NSViewRepresentable {
    @Binding var triggerSignal: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        context.coordinator.picker = picker
        return picker
    }
    
    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        if triggerSignal != context.coordinator.lastTriggerSignal {
            context.coordinator.lastTriggerSignal = triggerSignal
            if let button = nsView.subviews.first(where: { $0 is NSButton }) as? NSButton {
                button.performClick(nil)
            }
        }
    }
    
    class Coordinator: NSObject {
        var picker: AVRoutePickerView?
        var lastTriggerSignal: Bool = false
    }
}

// MARK: - Safe Native Video Player View (Non-destructive player updates for persistent AirPlay)
struct NativeVideoView: NSViewRepresentable {
    let url: URL
    let isPaused: Bool
    let isLooping: Bool
    @Binding var seekTrigger: (direction: Int, count: Int)?
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var scrubTargetTime: Double?
    var onExternalPlaybackChanged: ((Bool) -> Void)? = nil
    let onEnd: () -> Void
    
    class Coordinator: NSObject, @unchecked Sendable {
        var player: AVPlayer?
        var onEnd: (() -> Void)?
        var observer: Any?
        var timeObserver: Any?
        var externalPlaybackObserver: NSKeyValueObservation?
        var airplayVideoWriterObserver: NSKeyValueObservation?
        var routeDiscoveryObserver: Any?
        var looper: AVPlayerLooper?
        var onExternalPlaybackChanged: ((Bool) -> Void)?
        
        func cleanup() {
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
                observer = nil
            }
            if let routeObs = routeDiscoveryObserver {
                NotificationCenter.default.removeObserver(routeObs)
                routeDiscoveryObserver = nil
            }
            if let timeObs = timeObserver, let p = player {
                p.removeTimeObserver(timeObs)
                timeObserver = nil
            }
            externalPlaybackObserver?.invalidate()
            externalPlaybackObserver = nil
            airplayVideoWriterObserver?.invalidate()
            airplayVideoWriterObserver = nil
            looper = nil
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
        
        func setupNotification(for playerItem: AVPlayerItem) {
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
            }
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: playerItem,
                queue: .main
            ) { [weak self] _ in
                self?.onEnd?()
            }
        }
        
        deinit {
            cleanup()
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeNSView(context: Context) -> AVPlayerView {
        let playerView = AVPlayerView()
        let player: AVPlayer = isLooping ? AVQueuePlayer() : AVPlayer()
        player.allowsExternalPlayback = true
        playerView.player = player
        
        let coordinator = context.coordinator
        coordinator.player = player
        coordinator.onEnd = onEnd
        coordinator.onExternalPlaybackChanged = onExternalPlaybackChanged
        
        // Monitor external playback state changes persistently on the single player instance
        coordinator.externalPlaybackObserver = player.observe(\.isExternalPlaybackActive, options: [.new, .old]) { _, change in
            let isActive = change.newValue ?? false
            DispatchQueue.main.async {
                coordinator.onExternalPlaybackChanged?(isActive)
            }
        }
        
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        coordinator.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard coordinator.player != nil else { return }
            DispatchQueue.main.async {
                self.currentTime = time.seconds
                if let dur = player.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                    self.duration = dur
                }
            }
        }
        
        loadAsset(into: player, coordinator: coordinator, url: url, isLooping: isLooping)
        return playerView
    }
    
    private func loadAsset(into player: AVPlayer, coordinator: Coordinator, url: URL, isLooping: Bool) {
        Task {
            let asset = AVURLAsset(url: url)
            do {
                let tracks = try await asset.load(.tracks)
                guard tracks.contains(where: { $0.mediaType == .video }) else { return }
                let playerItem = AVPlayerItem(asset: asset)
                
                await MainActor.run {
                    coordinator.looper = nil
                    if isLooping {
                        if let queuePlayer = player as? AVQueuePlayer {
                            queuePlayer.removeAllItems()
                            coordinator.looper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
                        }
                    } else {
                        player.replaceCurrentItem(with: playerItem)
                        coordinator.setupNotification(for: playerItem)
                    }
                    player.play()
                }
            } catch {
                print("AirPlay Handshake Error: Failed to load asset tracks: \(error)")
            }
        }
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.cleanup()
        nsView.player = nil
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEnd = onEnd
        coordinator.onExternalPlaybackChanged = onExternalPlaybackChanged
        
        let currentPlayer = nsView.player
        let currentAssetURL = (currentPlayer?.currentItem?.asset as? AVURLAsset)?.url
        
        // Seamlessly update content item on the existing player without triggering view/player teardown
        if currentAssetURL != url, let player = currentPlayer {
            loadAsset(into: player, coordinator: coordinator, url: url, isLooping: isLooping)
        }
        
        if isPaused {
            nsView.player?.pause()
        } else {
            nsView.player?.play()
        }
        
        if let scrubTime = scrubTargetTime {
            DispatchQueue.main.async {
                guard let player = coordinator.player else { return }
                let target = CMTime(seconds: scrubTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                self.scrubTargetTime = nil
            }
        }
        
        if let seek = seekTrigger {
            DispatchQueue.main.async {
                guard let player = coordinator.player else { return }
                let baseSeek: Double = 2.0
                let totalOffset = Double(seek.direction) * baseSeek * Double(seek.count)
                let current = player.currentTime().seconds
                let targetTime = CMTime(seconds: max(0, current + totalOffset), preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
                seekTrigger = nil
            }
        }
    }
}

// MARK: - Photo Viewer (With AirPlay Background Video Handoff Support)
struct PhotoSlideView: View {
    let item: MediaItem
    @ObservedObject var state: AppState
    @State private var image: NSImage?
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                
                if let videoURL = state.photoAirPlayVideoURL {
                    NativeVideoView(
                        url: videoURL,
                        isPaused: state.isPaused,
                        isLooping: true,
                        seekTrigger: .constant(nil),
                        currentTime: $state.videoCurrentTime,
                        duration: $state.videoDuration,
                        scrubTargetTime: .constant(nil),
                        onExternalPlaybackChanged: { active in
                            print("AirPlay Handshake Debug: Photo slide AirPlay state updated -> active: \(active)")
                            state.isAirPlayActive = active
                        },
                        onEnd: {}
                    )
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                }
                
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
        .edgesIgnoringSafeArea(.all)
        .task(id: item.url) {
            image = ImageLoader.loadFullImage(from: item.url)
        }
    }
}

// MARK: - Views
struct DropzoneView: View {
    @ObservedObject var state: AppState
    
    var body: some View {
        VStack(spacing: 20) {
            Text("📷").font(.system(size: 80))
            Text("Drop Media or Folders Here").font(.largeTitle.bold()).foregroundColor(.white)
            Text("Drag & drop images, videos, or click below").font(.title3).foregroundColor(.gray)
            
            Button("📁 Choose Folder") {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
    }
}

// MARK: - Gallery Card View
struct GalleryCardView: View {
    let item: MediaItem
    let isSelected: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovered: Bool = false
    
    var body: some View {
        let activeColor = isHovered ? Color.green : (isSelected ? Color.blue : Color.clear)
        let bgColor = isHovered ? Color.green.opacity(0.3) : (isSelected ? Color.blue.opacity(0.4) : Color.white.opacity(0.1))
        
        Group {
            if item.isBackAction {
                VStack(spacing: 12) {
                    Text("↩️").font(.system(size: 64))
                    Text("Back").font(.body.bold()).foregroundColor(.white)
                }
            } else if item.isDirectory {
                VStack(spacing: 8) {
                    Text("📁").font(.system(size: 64))
                    Text(item.name)
                        .font(.body.bold())
                        .foregroundColor(.white)
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
                    .frame(width: 224, height: 145)
                    
                    Text(item.name)
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .task(id: item.url) {
                    thumbnail = nil
                    thumbnail = await ImageLoader.loadThumbnail(for: item, size: CGSize(width: 448, height: 290))
                }
            } else {
                Group {
                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 224, height: 184)
                    } else {
                        ProgressView()
                    }
                }
                .task(id: item.url) {
                    thumbnail = nil
                    thumbnail = await ImageLoader.loadThumbnail(for: item, size: CGSize(width: 448, height: 368))
                }
            }
        }
        .padding(8)
        .frame(width: 240, height: 200)
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
        .onTapGesture {
            action()
        }
    }
}

struct GalleryView: View {
    @ObservedObject var state: AppState
    let cardWidth: CGFloat = 264
    
    var body: some View {
        VStack {
            HStack {
                Text("📁 \(state.currentFolder?.lastPathComponent ?? "Gallery")")
                    .font(.title.bold())
                    .foregroundColor(.white)
                Spacer()
                Button("✕ Exit to Dropzone") {
                    state.currentFolder = nil
                    state.folderHistory.removeAll()
                    NSCursor.unhide()
                    state.setFullScreen(false)
                }
                .controlSize(.large)
                .onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
            }
            .padding()
            
            GeometryReader { geometry in
                let availableWidth = max(100, geometry.size.width - 40)
                let cols = max(1, Int(availableWidth / cardWidth))
                
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(240), spacing: 24), count: cols), spacing: 24) {
                            ForEach(Array(state.items.enumerated()), id: \.element.id) { index, item in
                                GalleryCardView(item: item, isSelected: index == state.selectedIndex) {
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
                    .onChange(of: cols) { _, newCols in state.gridColumnsCount = newCols }
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .background(Color.black)
        .onAppear { NSCursor.unhide() }
        .onHover { hovering in
            if hovering { NSCursor.arrow.set() }
        }
    }
}

struct SlideshowView: View {
    @ObservedObject var state: AppState
    @State private var showControls = false
    @State private var controlsTimer: Timer?
    @State private var cursorHideTimer: Timer?
    @State private var isCursorHidden = false
    
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && seconds.isFinite && seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds)
        let mins = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }
    
    var body: some View {
        ZStack {
            Color.black.edgesIgnoringSafeArea(.all)
            
            AirPlayRoutePickerView(triggerSignal: $state.airplayTriggerSignal)
                .frame(width: 0, height: 0)
                .opacity(0)
            
            if let current = state.selectedItem {
                if current.isVideo {
                    NativeVideoView(
                        url: current.url,
                        isPaused: state.isPaused,
                        isLooping: false,
                        seekTrigger: $state.seekTrigger,
                        currentTime: $state.videoCurrentTime,
                        duration: $state.videoDuration,
                        scrubTargetTime: $state.scrubTargetTime,
                        onExternalPlaybackChanged: { active in
                            print("AirPlay Handshake Debug: Slideshow video playback AirPlay state updated -> active: \(active)")
                            state.isAirPlayActive = active
                        },
                        onEnd: {
                            state.moveSlideshowSelection(by: 1, userInitiated: false)
                        }
                    )
                    .id(current.url)
                    .edgesIgnoringSafeArea(.all)
                } else {
                    PhotoSlideView(item: current, state: state)
                }
            }
            
            if showControls {
                VStack {
                    Spacer()
                    
                    HStack(spacing: 16) {
                        Button("◄ Back") { state.moveSlideshowSelection(by: -1) }
                        Button(state.isPaused ? "Play" : "Pause") {
                            state.isPaused.toggle()
                            state.resetTimer()
                        }
                        Button("Next ►") { state.moveSlideshowSelection(by: 1) }
                        
                        Divider()
                            .frame(height: 18)
                            .background(Color.white.opacity(0.3))
                        
                        AirPlayRoutePickerView(triggerSignal: $state.airplayTriggerSignal)
                            .frame(width: 32, height: 24)
                        
                        Divider()
                            .frame(height: 18)
                            .background(Color.white.opacity(0.3))
                        
                        if let current = state.selectedItem, current.isVideo {
                            HStack(spacing: 8) {
                                Text(formatTime(state.videoCurrentTime))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.white)
                                
                                Slider(
                                    value: Binding(
                                        get: { min(max(0, state.videoCurrentTime), state.videoDuration) },
                                        set: { newValue in
                                            state.videoCurrentTime = newValue
                                            state.scrubTargetTime = newValue
                                        }
                                    ),
                                    in: 0...max(1.0, state.videoDuration),
                                    onEditingChanged: { editing in
                                        state.isScrubbing = editing
                                        triggerControls()
                                    }
                                )
                                .accentColor(.blue)
                                .frame(width: 200)
                                
                                Text(formatTime(state.videoDuration))
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.gray)
                            }
                        } else {
                            Stepper("Delay: \(state.delaySeconds)s", value: $state.delaySeconds, in: 1...60)
                                .onChange(of: state.delaySeconds) { state.resetTimer() }
                        }
                        
                        Divider()
                            .frame(height: 18)
                            .background(Color.white.opacity(0.3))
                        
                        Button("✕ Exit") { state.exitSlideshow() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .padding(.bottom, 75)
                    .onHover { hovering in
                        if hovering { NSCursor.arrow.set() }
                    }
                }
                .transition(.opacity)
            }
        }
        .edgesIgnoringSafeArea(.all)
        .onContinuousHover { _ in
            handleMouseActivity()
        }
        .onAppear {
            showControls = false
            NSCursor.unhide()
            isCursorHidden = false
            startCursorHideTimer()
        }
        .onDisappear {
            NSCursor.unhide()
            cursorHideTimer?.invalidate()
            controlsTimer?.invalidate()
        }
        .onChange(of: state.showControlsSignal) { _, _ in
            triggerControls()
        }
    }
    
    private func handleMouseActivity() {
        if isCursorHidden {
            NSCursor.unhide()
            isCursorHidden = false
        } else {
            NSCursor.arrow.set()
        }
        triggerControls()
        startCursorHideTimer()
    }
    
    private func triggerControls() {
        withAnimation { showControls = true }
        controlsTimer?.invalidate()
        
        guard !state.isScrubbing else { return }
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation { showControls = false }
            }
        }
    }
    
    private func startCursorHideTimer() {
        cursorHideTimer?.invalidate()
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                guard !state.isScrubbing else { return }
                if !isCursorHidden {
                    NSCursor.hide()
                    isCursorHidden = true
                }
            }
        }
    }
}

// MARK: - Root View & Key Bindings
struct ContentView: View {
    @ObservedObject var state: AppState
    @FocusState private var isFocused: Bool
    
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
        .edgesIgnoringSafeArea(.all)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onAppear { isFocused = true }
        .onChange(of: state.isSlideshowActive) { _, _ in isFocused = true }
        .onChange(of: state.currentFolder) { _, _ in isFocused = true }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    Task { @MainActor in state.loadDirectory(url) }
                }
            }
            return true
        }
        .onKeyPress { press in
            let isCommandPressed = press.modifiers.contains(EventModifiers.command)
            
            if state.isSlideshowActive {
                NSCursor.unhide()
            }
            
            if state.isSlideshowActive && (press.key == KeyEquivalent("a") || press.key == KeyEquivalent("A")) {
                state.triggerAirPlay()
                return .handled
            }
            
            switch press.key {
            case .rightArrow:
                if isCommandPressed && state.isSlideshowActive, let current = state.selectedItem, current.isVideo {
                    state.seekVideo(forward: true)
                } else if state.isSlideshowActive {
                    state.moveSlideshowSelection(by: 1)
                } else {
                    state.moveGridSelection(horizontal: 1)
                }
                return .handled
                
            case .leftArrow:
                if isCommandPressed && state.isSlideshowActive, let current = state.selectedItem, current.isVideo {
                    state.seekVideo(forward: false) // Fixed: changed forward from true to false
                } else if state.isSlideshowActive {
                    state.moveSlideshowSelection(by: -1)
                } else {
                    state.moveGridSelection(horizontal: -1)
                }
                return .handled
                
            case .downArrow:
                if state.isSlideshowActive {
                    state.adjustDelay(by: -1)
                } else {
                    state.moveGridSelection(vertical: 1)
                }
                return .handled
                
            case .upArrow:
                if state.isSlideshowActive {
                    state.adjustDelay(by: 1) // Fixed: changed decrement (-1) to increment (1)
                } else {
                    state.moveGridSelection(vertical: -1)
                }
                return .handled
                
            case .return:
                state.triggerControls()
                if !state.isSlideshowActive {
                    state.startSlideshow()
                }
                return .handled
            case .space:
                state.triggerControls()
                if state.isSlideshowActive {
                    state.isPaused.toggle()
                    state.resetTimer()
                }
                return .handled
            case .escape:
                if state.isSlideshowActive {
                    state.exitSlideshow()
                } else if state.currentFolder != nil {
                    state.navigateBack()
                }
                return .handled
                
            case .tab:
                return .ignored
                
            default:
                return .ignored
            }
        }
    }
}

// MARK: - Application Entry Point
@main
struct SimpleSlideshowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var state = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView(state: state)
                .preferredColorScheme(.dark)
                .onAppear {
                    appDelegate.onOpenURL = { url in
                        Task { @MainActor in
                            state.loadDirectory(url)
                        }
                    }
                }
        }
        .defaultSize(width: 400, height: 300) 
        .windowStyle(.hiddenTitleBar)
    }
}