import SwiftUI
import AVKit
import QuickLookThumbnailing
import AppKit
import UniformTypeIdentifiers
import Combine
import PDFKit

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

// MARK: - Picture-in-Picture Floating Panel Manager
final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class PiPManager {
    static let shared = PiPManager()
    private var pipWindow: PiPPanel?
    private var isTransitioning = false

    var isPiPActive: Bool {
        return pipWindow != nil
    }

    @MainActor
    func togglePiP(for state: AppState) {
        if state.isFullScreen || isTransitioning { return }
        
        if pipWindow != nil {
            closePiP()
        } else {
            openPiP(for: state)
        }
    }

    @MainActor
    func openPiP(for state: AppState) {
        guard !state.isFullScreen && !isTransitioning else { return }
        guard let currentItem = state.selectedItem, !currentItem.isDirectory else { return }
        
        isTransitioning = true
        closePiP(animated: false)

        if (currentItem.isVideo || currentItem.isAudio) && state.sharedPlayerViewModel.player == nil {
            state.sharedPlayerViewModel.setupPlayer(for: currentItem.url)
            state.sharedPlayerViewModel.player?.volume = Float(state.videoVolume)
        }

        let maxDimension: CGFloat = 450
        var panelWidth: CGFloat = maxDimension
        var panelHeight: CGFloat = currentItem.isAudio ? 150 : (currentItem.isVideo ? (maxDimension * 9.0 / 16.0) : 300)
        
        var naturalSize: CGSize? = nil
        let didStart = currentItem.url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                currentItem.url.stopAccessingSecurityScopedResource()
            }
        }

        if currentItem.isAudio {
            panelWidth = 350
            panelHeight = 150
        } else if currentItem.isVideo {
            naturalSize = state.sharedPlayerViewModel.assetNaturalSize
        } else if currentItem.url.pathExtension.lowercased() == "pdf" {
            if let doc = PDFDocument(url: currentItem.url), let page = doc.page(at: state.currentDocumentPage) {
                naturalSize = page.bounds(for: .mediaBox).size
            }
        } else {
            naturalSize = ImageLoader.loadFullImage(from: currentItem.url)?.size
        }
        
        if let size = naturalSize, size.width > 0, size.height > 0 {
            if size.width >= size.height {
                panelWidth = maxDimension
                panelHeight = maxDimension * (size.height / size.width)
            } else {
                panelHeight = maxDimension
                panelWidth = maxDimension * (size.width / size.height)
            }
        }

        let panel = PiPPanel(
            contentRect: NSRect(x: 100, y: 100, width: panelWidth, height: panelHeight),
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

        if let mainWindow = NSApp.windows.first(where: { !$0.isKind(of: PiPPanel.self) }) {
            mainWindow.orderOut(nil)
        }
        
        isTransitioning = false
    }

    @MainActor
    func updatePiPContentSize(for state: AppState) {
        guard let panel = pipWindow, let currentItem = state.selectedItem, !currentItem.isDirectory else { return }
        
        let maxDimension: CGFloat = 450
        var panelWidth: CGFloat = maxDimension
        var panelHeight: CGFloat = currentItem.isAudio ? 150 : (currentItem.isVideo ? (maxDimension * 9.0 / 16.0) : 300)
        
        var naturalSize: CGSize? = nil
        let didStart = currentItem.url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                currentItem.url.stopAccessingSecurityScopedResource()
            }
        }

        if currentItem.isAudio {
            panelWidth = 350
            panelHeight = 150
        } else if currentItem.isVideo {
            naturalSize = state.sharedPlayerViewModel.assetNaturalSize
        } else if currentItem.url.pathExtension.lowercased() == "pdf" {
            if let doc = PDFDocument(url: currentItem.url), let page = doc.page(at: state.currentDocumentPage) {
                naturalSize = page.bounds(for: .mediaBox).size
            }
        } else {
            naturalSize = ImageLoader.loadFullImage(from: currentItem.url)?.size
        }
        
        if currentItem.isVideo && naturalSize == nil {
            return
        }
        
        if let size = naturalSize, size.width > 0, size.height > 0 && !currentItem.isAudio {
            if size.width >= size.height {
                panelWidth = maxDimension
                panelHeight = maxDimension * (size.height / size.width)
            } else {
                panelHeight = maxDimension
                panelWidth = maxDimension * (size.width / size.height)
            }
        }
        
        var frame = panel.frame
        let oldHeight = frame.height
        let oldWidth = frame.width
        frame.size.width = panelWidth
        frame.size.height = panelHeight
        frame.origin.x += (oldWidth - panelWidth) / 2
        frame.origin.y += (oldHeight - panelHeight) / 2
        
        panel.setFrame(frame, display: true, animate: false)
    }

    @MainActor
    func closePiP(animated: Bool = true) {
        if let window = pipWindow {
            window.orderOut(nil)
            pipWindow = nil
        }
        
        if let mainWindow = NSApp.windows.first(where: { !$0.isKind(of: PiPPanel.self) }), !mainWindow.isVisible {
            mainWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        
        isTransitioning = false
    }
}

// MARK: - Shared Video & Audio Player Model
@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var assetNaturalSize: CGSize? = nil
    @Published var currentTime: Double = 0
    @Published var duration: Double = 1
    
    private var endObserver: NSObjectProtocol?
    private var timeObserverToken: Any?
    private static var sizeCache: [URL: CGSize] = [:]
    private var securityScopedURL: URL?
    
    var onVideoEnded: (() -> Void)?
    
    func setupPlayer(for url: URL) {
        cleanup()
        
        let didStart = url.startAccessingSecurityScopedResource()
        if didStart {
            securityScopedURL = url
        }
        
        if let cachedSize = Self.sizeCache[url] {
            self.assetNaturalSize = cachedSize
        }
        
        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.removeEndObserver()
                self.onVideoEnded?()
            }
        }
        
        let newPlayer = AVPlayer(playerItem: playerItem)
        player = newPlayer
        
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = newPlayer.addPeriodicTimeObserver(forInterval: interval, queue: nil) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self = self, self.player === newPlayer else { return }
                self.currentTime = time.seconds
                if let dur = newPlayer.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                    self.duration = dur
                }
            }
        }
        
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let size = try? await track.load(.naturalSize)
                let transform = try? await track.load(.preferredTransform)
                if let size = size {
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
        if let token = timeObserverToken, let player = player {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
    }
    
    private func removeEndObserver() {
        if let observer = endObserver {
            NotificationCenter.default.removeObserver(observer)
            endObserver = nil
        }
    }
    
    func cleanup() {
        removeTimeObserver()
        removeEndObserver()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        assetNaturalSize = nil
        currentTime = 0
        duration = 1
        
        if let url = securityScopedURL {
            url.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
        }
    }
}

// MARK: - PiP Container View wrapper with hover-based controls
struct PiPContainerView: View {
    @ObservedObject var state: AppState
    @State private var isHovered = false

    var body: some View {
        ZStack {
            Color.black
            if let current = state.selectedItem, !current.isDirectory {
                let ext = current.url.pathExtension.lowercased()
                if current.isAudio {
                    AudioSlideView(url: current.url, viewModel: state.sharedPlayerViewModel)
                        .id(current.id)
                } else if current.isVideo {
                    SharedVideoView(viewModel: state.sharedPlayerViewModel, gravity: .resizeAspect)
                        .id(current.id)
                } else if ext == "pdf" {
                    PDFSlideView(url: current.url, pageIndex: state.currentDocumentPage)
                        .id("\(current.id)_p\(state.currentDocumentPage)")
                } else {
                    PhotoSlideView(url: current.url)
                        .id(current.id)
                }
            }
            
            if isHovered {
                VStack {
                    HStack {
                        Spacer()
                        Button(action: {
                            PiPManager.shared.closePiP()
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.white.opacity(0.8))
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
                                .foregroundColor(.white.opacity(0.9))
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
                case .active(_):
                    isHovered = true
                case .ended:
                    isHovered = false
                }
            }
        }
        .onChange(of: state.sharedPlayerViewModel.assetNaturalSize) { _, newSize in
            if newSize != nil {
                PiPManager.shared.updatePiPContentSize(for: state)
            }
        }
        .onChange(of: state.selectedIndex) { _, _ in
            PiPManager.shared.updatePiPContentSize(for: state)
        }
        .onChange(of: state.currentDocumentPage) { _, _ in
            PiPManager.shared.updatePiPContentSize(for: state)
        }
    }
}

// MARK: - App Delegate & File Open Handling
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var state: AppState? {
        didSet {
            if let url = pendingURL, let state = state {
                pendingURL = nil
                Task { @MainActor in
                    state.loadDirectory(url)
                }
            }
        }
    }
    var pendingURL: URL?
    var onFullScreenChange: ((Bool) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        
        let windows = NSApp.windows
        if windows.count > 1 {
            for window in windows.dropFirst() {
                window.close()
            }
        }
        
        if let window = NSApp.windows.first {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .windowBackgroundColor
            window.delegate = self
            let spec = AppState.spec(for: .dropzone)
            window.setContentSize(NSSize(width: spec.width, height: spec.height))
            window.minSize = NSSize(width: spec.minWidth, height: spec.minHeight)
            window.maxSize = NSSize(width: spec.maxWidth, height: spec.maxHeight)
            window.styleMask.remove(.resizable)
        }
        
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            NSCursor.unhide()
        }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        if let state = state {
            Task { @MainActor in
                state.loadDirectory(url)
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            pendingURL = url
        }
        return true
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        
        let windows = NSApp.windows
        if windows.count > 1 {
            for window in windows.dropFirst() {
                window.close()
            }
        }
        
        if let state = state {
            Task { @MainActor in
                state.loadDirectory(url)
                if let window = NSApp.windows.first {
                    window.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        } else {
            pendingURL = url
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

// MARK: - Models & Cache
struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let isVideo: Bool
    let isAudio: Bool
    
    var isMedia: Bool { !isDirectory }
}

final class ThumbnailCache {
    static let shared = NSCache<NSString, NSImage>()
}

// MARK: - Async Thumbnail & Image Loader
actor ImageLoader {
    static func loadThumbnail(for item: MediaItem, size: CGSize) async -> NSImage? {
        let parentDir = item.url.deletingLastPathComponent().lastPathComponent
        let cacheKeyString = "\(parentDir)_\(item.name)"
        let key = NSString(string: cacheKeyString)
        
        if let cached = ThumbnailCache.shared.object(forKey: key) {
            return cached
        }
        
        let scale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 2.0 }
        
        let ext = item.url.pathExtension.lowercased()
        let validImageExts = [
            "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "tiff", "tif", "ico", "svg",
            "psd", "jp2", "jxl", "exr", "hdr",
            "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"
        ]
        let validVideoExts = [
            "mp4", "m4v", "mov", "qt", "mkv", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "dv", "flv"
        ]
        let validAudioExts = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "flac", "caf", "ac3", "au", "snd"]
        let validDocExts = ["pdf"]
         
        let didStart = item.url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                item.url.stopAccessingSecurityScopedResource()
            }
        }
        
        if item.isAudio {
            let image = NSImage(size: size)
            image.lockFocus()
            if let context = NSGraphicsContext.current?.cgContext {
                context.setFillColor(NSColor.darkGray.cgColor)
                context.fill(CGRect(origin: .zero, size: size))
            }
            image.unlockFocus()
            ThumbnailCache.shared.setObject(image, forKey: key)
            return image
        }

        if ext == "pdf" {
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
                    context.scaleBy(x: targetRect.width / pageRect.width, y: targetRect.height / pageRect.height)
                    page.draw(with: .mediaBox, to: context)
                    context.restoreGState()
                }
                image.unlockFocus()
                ThumbnailCache.shared.setObject(image, forKey: key)
                return image
            }
        }
        
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
            if !validImageExts.contains(ext) && !validVideoExts.contains(ext) && !validAudioExts.contains(ext) && !validDocExts.contains(ext) {
                return nil
            }
            
            if validImageExts.contains(ext), let fullImage = loadFullImage(from: item.url) {
                ThumbnailCache.shared.setObject(fullImage, forKey: key)
                return fullImage
            }
            
            return nil
        }
    }
    
    static func loadFullImage(from url: URL) -> NSImage? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - Navigation History State
struct FolderState {
    let url: URL
    var selectedIndex: Int
}

// MARK: - App State
@MainActor
final class AppState: ObservableObject {
    @Published var currentFolder: URL?
    @Published var folderHistory: [FolderState] = []
    @Published var items: [MediaItem] = []
    @Published var selectedIndex: Int = 0 {
        didSet {
            if PiPManager.shared.isPiPActive {
                PiPManager.shared.updatePiPContentSize(for: self)
            }
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
    @Published var seekTrigger: (direction: Int, count: Int, id: UUID)? = nil
    @Published var showControlsSignal: Bool = false
    @Published var isDarkMode: Bool
    @Published var isFullScreen: Bool = false {
        didSet {
            if !isFullScreen {
                NSCursor.unhide()
            } else {
                PiPManager.shared.closePiP()
            }
        }
    }
    
    @Published var sharedPlayerViewModel = PlayerViewModel()
    
    private var currentPDFDocument: PDFDocument? = nil
    
    var videoCurrentTime: Double {
        get { sharedPlayerViewModel.currentTime }
        set { sharedPlayerViewModel.currentTime = newValue }
    }
    
    var videoDuration: Double {
        get { sharedPlayerViewModel.duration }
        set { sharedPlayerViewModel.duration = newValue }
    }
    
    @Published var isScrubbing: Bool = false
    @Published var scrubTargetTime: Double? = nil
    
    private var timer: Timer?
    private var lastSeekTime: Date = Date()
    private var seekAcceleration: Int = 1
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.isDarkMode = isDark
        
        sharedPlayerViewModel.$currentTime
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        sharedPlayerViewModel.$duration
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
        
        sharedPlayerViewModel.onVideoEnded = { [weak self] in
            guard let self = self else { return }
            self.isPaused = false
            self.moveSlideshowSelection(by: 1, userInitiated: false)
            
            if PiPManager.shared.isPiPActive {
                PiPManager.shared.updatePiPContentSize(for: self)
            }
        }
    }
    
    var selectedItem: MediaItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }
    
    static func spec(for mode: WindowInteractionMode) -> WindowLayoutSpec {
        switch mode {
        case .dropzone:
            return WindowLayoutSpec(
                width: 400, height: 350,
                minWidth: 400, minHeight: 350,
                maxWidth: 400, maxHeight: 350,
                isResizable: false
            )
        case .browser, .slideshow:
            return WindowLayoutSpec(
                width: 1120, height: 776,
                minWidth: 400, minHeight: 350,
                maxWidth: CGFloat.greatestFiniteMagnitude, maxHeight: CGFloat.greatestFiniteMagnitude,
                isResizable: true
            )
        }
    }
    
    func resetVideoState() {
        videoCurrentTime = 0
        videoDuration = 1
        isScrubbing = false
        scrubTargetTime = nil
        seekTrigger = nil
        sharedPlayerViewModel.cleanup()
    }
    
    func loadCurrentDocument() {
        guard let item = selectedItem, item.url.pathExtension.lowercased() == "pdf" else {
            currentPDFDocument = nil
            totalDocumentPages = 1
            return
        }
        
        let didStart = item.url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                item.url.stopAccessingSecurityScopedResource()
            }
        }
        
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
        PiPManager.shared.closePiP()
        
        if isSlideshowActive {
            isSlideshowActive = false
            timer?.invalidate()
            resetVideoState()
        }
        
        updateWindowForMode(.browser)
        
        if let window = NSApp.keyWindow ?? NSApp.windows.first {
            let contentWidth = window.contentView?.bounds.width ?? 1120
            let availableWidth = contentWidth - 40
            let calculatedCols = max(1, Int(availableWidth / 264.0))
            self.gridColumnsCount = calculatedCols
        }
        
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
    }
    
    private func parseDirectory(_ target: URL, resetIndex: Bool = true) {
        self.items = []
        if resetIndex {
            self.selectedIndex = 0
        }
        self.currentFolder = target
        
        let didStart = target.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                target.stopAccessingSecurityScopedResource()
            }
        }
        
        let keys: [URLResourceKey] = [.isDirectoryKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: target, includingPropertiesForKeys: keys, options: .skipsHiddenFiles) else {
            return
        }
        
        let validImageExts = [
            "png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif", "tiff", "tif", "ico", "svg",
            "psd", "jp2", "jxl", "exr", "hdr",
            "raw", "cr2", "cr3", "nef", "arw", "dng", "orf", "rw2"
        ]
        let validVideoExts = [
            "mp4", "m4v", "mov", "qt", "mkv", "avi", "mpg", "mpeg", "ts", "mts", "m2ts", "dv", "flv"
        ]
        let validAudioExts = [
            "mp3", "m4a", "m4b", "aac", "wav", "aiff", "aif", "flac", "caf", "ac3", "au", "snd"
        ]
        let validDocExts = ["pdf"]
        
        var folderItems: [MediaItem] = []
        var mediaItems: [MediaItem] = []
        
        for file in files {
            let resourceValues = try? file.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = resourceValues?.isDirectory ?? false
            let ext = file.pathExtension.lowercased()
            
            if isDirectory {
                folderItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: true, isVideo: false, isAudio: false))
            } else if validImageExts.contains(ext) || validDocExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: false, isAudio: false))
            } else if validVideoExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: true, isAudio: false))
            } else if validAudioExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: false, isAudio: true))
            }
        }
        
        folderItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        mediaItems.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        var combinedItems: [MediaItem] = []
        combinedItems.append(contentsOf: folderItems)
        combinedItems.append(contentsOf: mediaItems)
        
        self.items = combinedItems
        if resetIndex {
            self.selectedIndex = 0
        } else {
            self.selectedIndex = min(max(0, self.selectedIndex), max(0, self.items.count - 1))
        }
    }
    
    func navigateBack() {
        NSCursor.unhide()
        PiPManager.shared.closePiP()
        if let previousState = folderHistory.popLast() {
            parseDirectory(previousState.url, resetIndex: false)
            selectedIndex = min(max(0, previousState.selectedIndex), max(0, items.count - 1))
            updateWindowForMode(.browser)
        } else {
            currentFolder = nil
            items = []
            folderHistory.removeAll()
            selectedIndex = 0
            updateWindowForMode(.dropzone)
        }
    }
    
    func startSlideshow(at index: Int? = nil) {
        if let idx = index { self.selectedIndex = idx }
        guard let item = selectedItem else { return }
        
        if item.isDirectory {
            loadDirectory(item.url)
            return
        }
        
        updateWindowForMode(.slideshow)
        resetVideoState()
        isSlideshowActive = true
        currentDocumentPage = 0
        loadCurrentDocument()
        
        if item.isVideo || item.isAudio {
            sharedPlayerViewModel.setupPlayer(for: item.url)
            sharedPlayerViewModel.player?.volume = Float(videoVolume)
        }
        
        resetTimer()
    }
    
    func exitSlideshow() {
        isSlideshowActive = false
        timer?.invalidate()
        resetVideoState()
        NSCursor.unhide()
        PiPManager.shared.closePiP()
        
        if let folder = currentFolder {
            parseDirectory(folder, resetIndex: false)
            updateWindowForMode(.browser)
        }
    }
    
    func moveSlideshowSelection(by delta: Int, userInitiated: Bool = true) {
        guard !items.isEmpty else { return }
        if userInitiated {
            triggerControls()
        }
        resetVideoState()
        
        let currentItem = selectedItem
        
        if let current = currentItem, current.url.pathExtension.lowercased() == "pdf" {
            if currentPDFDocument == nil {
                loadCurrentDocument()
            }
            
            let nextPage = currentDocumentPage + delta
            if nextPage >= 0 && nextPage < totalDocumentPages {
                currentDocumentPage = nextPage
                resetTimer()
                return
            } else if nextPage >= totalDocumentPages && delta > 0 {
                currentDocumentPage = 0
            } else if nextPage < 0 && delta < 0 {
                currentDocumentPage = 0
            }
        }
        
        var newIndex = selectedIndex
        let count = items.count
        
        for _ in 0..<count {
            newIndex = newIndex + delta
            if newIndex >= count {
                newIndex = 0
            } else if newIndex < 0 {
                newIndex = count - 1
            }
            
            if !items[newIndex].isDirectory {
                break
            }
        }
        
        selectedIndex = newIndex
        currentDocumentPage = 0
        loadCurrentDocument()
        
        if selectedItem?.isDirectory == true {
            exitSlideshow()
            return
        }
        
        if let current = selectedItem, (current.isVideo || current.isAudio) {
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
            let maxRow = (items.count - 1) / cols
            if newRow >= 0 && newRow <= maxRow {
                let targetCol = min(currentCol, (newRow == maxRow) ? ((items.count - 1) % cols) : (cols - 1))
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
        
        guard let player = sharedPlayerViewModel.player else { return }
        let baseSeek: Double = 2.0
        let totalOffset = (forward ? 1.0 : -1.0) * baseSeek * Double(seekAcceleration)
        let current = player.currentTime().seconds
        let targetTime = CMTime(seconds: max(0, current + totalOffset), preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    
    func adjustDelay(by seconds: Int) {
        triggerControls()
        let newDelay = delaySeconds + seconds
        delaySeconds = min(max(1, newDelay), 60)
        resetTimer()
    }
    
    func adjustVolume(by amount: Double) {
        triggerControls()
        let newVolume = videoVolume + amount
        videoVolume = min(max(0.0, newVolume), 1.0)
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
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        window.toggleFullScreen(nil)
    }
    
    func setFullScreenState(_ fullScreen: Bool) {
        isFullScreen = fullScreen
    }
    
    private func updateWindowForMode(_ mode: WindowInteractionMode) {
        guard let window = NSApp.keyWindow ?? NSApp.windows.first else { return }
        let spec = AppState.spec(for: mode)
        
        if mode == .dropzone && window.styleMask.contains(.fullScreen) {
            window.toggleFullScreen(nil)
        }
        
        if spec.isResizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
        
        window.minSize = NSSize(width: spec.minWidth, height: spec.minHeight)
        window.maxSize = NSSize(width: spec.maxWidth, height: spec.maxHeight)
        
        if !window.styleMask.contains(.fullScreen) {
            window.setContentSize(NSSize(width: spec.width, height: spec.height))
        }
    }
}

private extension URL {
    var standardizedFileIOPassed: URL {
        return self.standardizedFileURL
    }
}

// MARK: - Shared Native Video Player View
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

// MARK: - Audio Slide View
struct AudioSlideView: View {
    let url: URL
    @ObservedObject var viewModel: PlayerViewModel
    
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

// MARK: - Photo Viewer
struct PhotoSlideView: View {
    let url: URL
    @State private var image: NSImage?
    
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
            image = ImageLoader.loadFullImage(from: url)
        }
    }
}

// MARK: - PDF Slide Viewer
struct PDFSlideView: View {
    let url: URL
    let pageIndex: Int
    @State private var pageImage: NSImage?
    
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
            pageImage = renderPDFPage(url: url, pageIndex: pageIndex)
        }
    }
    
    private func renderPDFPage(url: URL, pageIndex: Int) -> NSImage? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }
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
        return image
    }
}

// MARK: - Views
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

// MARK: - Gallery Card View
struct GalleryCardView: View {
    let item: MediaItem
    let isSelected: Bool
    let isDarkMode: Bool
    let action: () -> Void
    @State private var thumbnail: NSImage?
    @State private var isHovered: Bool = false
    
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
                    .frame(width: 224, height: 145)
                    
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
                    .frame(width: 224, height: 145)
                    
                    Text(item.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .task(id: item.url) {
                    thumbnail = nil
                    thumbnail = await ImageLoader.loadThumbnail(for: item, size: CGSize(width: 448, height: 290))
                }
            } else {
                VStack(spacing: 6) {
                    Group {
                        if let thumbnail = thumbnail {
                            Image(nsImage: thumbnail)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 224, height: 160)
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
                    thumbnail = nil
                    thumbnail = await ImageLoader.loadThumbnail(for: item, size: CGSize(width: 448, height: 320))
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
            
            GeometryReader { geometry in
                let availableWidth = geometry.size.width - 40
                let cols = max(1, Int(availableWidth / cardWidth))
                
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
                    .onChange(of: cols) { _, newCols in state.gridColumnsCount = newCols }
                    .onChange(of: state.selectedIndex) { _, newIndex in
                        proxy.scrollTo(newIndex, anchor: .center)
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

struct SlideshowView: View {
    @ObservedObject var state: AppState
    @State private var showControls = false
    @State private var controlsTimer: Timer?
    @State private var cursorHideTimer: Timer?
    @State private var isCursorHidden = false
    @State private var showVolumePopover = false
    
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
            
            if let current = state.selectedItem, !current.isDirectory {
                let ext = current.url.pathExtension.lowercased()
                if current.isAudio {
                    AudioSlideView(url: current.url, viewModel: state.sharedPlayerViewModel)
                        .id(current.id)
                } else if current.isVideo {
                    SharedVideoView(viewModel: state.sharedPlayerViewModel, gravity: .resizeAspect)
                        .id(current.id)
                } else if ext == "pdf" {
                    PDFSlideView(url: current.url, pageIndex: state.currentDocumentPage)
                        .id("\(current.id)_p\(state.currentDocumentPage)")
                } else {
                    PhotoSlideView(url: current.url)
                        .id(current.id)
                }
            }
            
            if showControls {
                GeometryReader { proxy in
                    let totalWidth = proxy.size.width
                    let isMediaPlayback = (state.selectedItem?.isVideo ?? false) || (state.selectedItem?.isAudio ?? false)
                    let isReallyWideMedia = isMediaPlayback && totalWidth > 900
                    let isWide = totalWidth > 600
                    
                    let panelWidth: CGFloat = isMediaPlayback
                        ? (isReallyWideMedia ? min(totalWidth * 0.90, 900) : (isWide ? totalWidth * 0.90 : totalWidth - 32))
                        : (isWide ? min(totalWidth * 0.9, 500) : totalWidth - 32)
                    
                    let isCompactAudio = totalWidth < 600
                    
                    VStack {
                        Spacer()
                        
                        VStack(spacing: 12) {
                            if isReallyWideMedia {
                                HStack(spacing: 16) {
                                    controlButtons
                                    
                                    Divider()
                                        .frame(height: 20)
                                        .background(Color.white.opacity(0.2))
                                    
                                    Text(formatTime(state.videoCurrentTime))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.white)
                                    
                                    Slider(
                                        value: Binding(
                                            get: { min(max(0, state.videoCurrentTime), state.videoDuration) },
                                            set: { newValue in
                                                state.videoCurrentTime = newValue
                                                let target = CMTime(seconds: newValue, preferredTimescale: 600)
                                                state.sharedPlayerViewModel.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                                            }
                                        ),
                                        in: 0...max(1.0, state.videoDuration),
                                        onEditingChanged: { editing in
                                            state.isScrubbing = editing
                                            triggerControls()
                                        }
                                    )
                                    .accentColor(.blue)
                                    .frame(maxWidth: .infinity)
                                    
                                    Text(formatTime(state.videoDuration))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.white.opacity(0.7))
                                    
                                    Divider()
                                        .frame(height: 20)
                                        .background(Color.white.opacity(0.2))
                                    
                                    HStack(spacing: 6) {
                                        Image(systemName: state.videoVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                            .foregroundColor(.white.opacity(0.8))
                                            .font(.caption)
                                        Slider(
                                            value: $state.videoVolume,
                                            in: 0...1.0,
                                            onEditingChanged: { _ in
                                                triggerControls()
                                            }
                                        )
                                        .accentColor(.blue)
                                        .frame(width: 80)
                                    }
                                    
                                    Divider()
                                        .frame(height: 20)
                                        .background(Color.white.opacity(0.2))
                                    
                                    utilityButtons
                                }
                            } else {
                                HStack(spacing: 16) {
                                    controlButtons
                                    
                                    Spacer()
                                    
                                    if let current = state.selectedItem, !current.isDirectory {
                                        if current.url.pathExtension.lowercased() == "pdf" {
                                            Text("Page \(state.currentDocumentPage + 1) of \(state.totalDocumentPages)")
                                                .font(.caption.bold())
                                                .foregroundColor(.white.opacity(0.8))
                                        } else if !current.isVideo && !current.isAudio {
                                            Stepper("Delay: \(state.delaySeconds)s", value: $state.delaySeconds, in: 1...60)
                                                .onChange(of: state.delaySeconds) { state.resetTimer() }
                                        }
                                    }
                                    
                                    utilityButtons
                                }
                                
                                if let current = state.selectedItem, current.isVideo || current.isAudio {
                                    Divider()
                                        .background(Color.white.opacity(0.2))
                                    
                                    HStack(spacing: 12) {
                                        Text(formatTime(state.videoCurrentTime))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.white)
                                        
                                        Slider(
                                            value: Binding(
                                                get: { min(max(0, state.videoCurrentTime), state.videoDuration) },
                                                set: { newValue in
                                                    state.videoCurrentTime = newValue
                                                    let target = CMTime(seconds: newValue, preferredTimescale: 600)
                                                    state.sharedPlayerViewModel.player?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                                                }
                                            ),
                                            in: 0...max(1.0, state.videoDuration),
                                            onEditingChanged: { editing in
                                                state.isScrubbing = editing
                                                triggerControls()
                                            }
                                        )
                                        .accentColor(.blue)
                                        .frame(maxWidth: .infinity)
                                        
                                        Text(formatTime(state.videoDuration))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.white.opacity(0.7))
                                        
                                        if isCompactAudio {
                                            Button(action: { showVolumePopover.toggle() }) {
                                                Image(systemName: state.videoVolume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                                    .foregroundColor(.white.opacity(0.8))
                                                    .font(.body)
                                            }
                                            .buttonStyle(.plain)
                                            .help("Volume Settings")
                                            .popover(isPresented: $showVolumePopover, arrowEdge: .top) {
                                                VStack(spacing: 8) {
                                                    Text("Volume: \(Int(state.videoVolume * 100))%")
                                                        .font(.caption.bold())
                                                    Slider(
                                                        value: $state.videoVolume,
                                                        in: 0...1.0,
                                                        onEditingChanged: { _ in
                                                            triggerControls()
                                                        }
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
                                                    onEditingChanged: { _ in
                                                        triggerControls()
                                                    }
                                                )
                                                .accentColor(.blue)
                                                .frame(width: 90)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .frame(width: panelWidth)
                        .background(Color.black.opacity(0.85))
                        .cornerRadius(12)
                        .environment(\.colorScheme, .dark)
                        .foregroundColor(.white)
                        .padding(.bottom, state.isFullScreen ? 75 : 16)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .transition(.opacity)
            }
        }
        .onTapGesture(count: 2) {
            state.toggleFullScreen()
        }
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
        .onChange(of: state.isFullScreen) { _, isFull in
            if !isFull {
                NSCursor.unhide()
                isCursorHidden = false
                cursorHideTimer?.invalidate()
            } else {
                startCursorHideTimer()
            }
        }
    }
    
    @ViewBuilder
    private var controlButtons: some View {
        Group {
            Button(action: { state.moveSlideshowSelection(by: -1) }) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .help("Previous Item")
            
            Button(action: {
                state.isPaused.toggle()
                if let current = state.selectedItem, current.isVideo || current.isAudio {
                    if state.isPaused {
                        state.sharedPlayerViewModel.player?.pause()
                    } else {
                        state.sharedPlayerViewModel.player?.play()
                    }
                }
                state.resetTimer()
            }) {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.plain)
            .help(state.isPaused ? "Play" : "Pause")
            
            Button(action: { state.moveSlideshowSelection(by: 1) }) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .help("Next Item")
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
        
        guard !state.isScrubbing && !showVolumePopover else { return }
        
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                withAnimation { showControls = false }
            }
        }
    }
    
    private func startCursorHideTimer() {
        cursorHideTimer?.invalidate()
        
        guard state.isFullScreen else { return }
        
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
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

// MARK: - Root View & Key Bindings
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
                    let targetWindow = NSApp.keyWindow ?? NSApp.windows.first
                    guard let currentWindow = targetWindow, currentWindow === event.window || NSApp.windows.contains(where: { $0 === event.window }) else {
                        return event
                    }
                    
                    let isCommandPressed = event.modifierFlags.contains(.command)
                    
                    if state.isSlideshowActive {
                        NSCursor.unhide()
                    }
                    
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
                    case 124: // Right Arrow
                        if isCommandPressed && state.isSlideshowActive, let current = state.selectedItem, current.isVideo {
                            state.seekVideo(forward: true)
                        } else if state.isSlideshowActive {
                            state.moveSlideshowSelection(by: 1)
                        } else {
                            state.moveGridSelection(horizontal: 1)
                        }
                        return nil
                        
                    case 123: // Left Arrow
                        if isCommandPressed && state.isSlideshowActive, let current = state.selectedItem, current.isVideo {
                            state.seekVideo(forward: false)
                        } else if state.isSlideshowActive {
                            state.moveSlideshowSelection(by: -1)
                        } else {
                            state.moveGridSelection(horizontal: -1)
                        }
                        return nil
                        
                    case 125: // Down Arrow
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
                        
                    case 126: // Up Arrow
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
                        
                    case 36, 76: // Return /Enter
                        state.triggerControls()
                        if !state.isSlideshowActive {
                            state.startSlideshow()
                        }
                        return nil
                        
                    case 49: // Spacebar
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
                        
                    case 53: // Escape
                        if PiPManager.shared.isPiPActive {
                            PiPManager.shared.closePiP()
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
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
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
        .defaultSize(width: 400, height: 350)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}