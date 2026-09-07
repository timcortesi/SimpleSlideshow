import SwiftUI
import AVKit
import QuickLookThumbnailing
import AppKit
import UniformTypeIdentifiers

// MARK: - Window Layout Configuration Model
struct WindowLayoutSpec {
    let width: CGFloat
    let height: CGFloat
    let isResizable: Bool
}

enum WindowInteractionMode {
    case dropzone
    case browser
    case slideshow
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
        let request = QLThumbnailGenerator.Request(
            fileAt: item.url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        
        let ext = item.url.pathExtension.lowercased()
        let validImageExts = ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "tiff"]
        let validVideoExts = ["mp4", "m4v", "mkv", "mov", "avi"]
        
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let image = representation.nsImage
            ThumbnailCache.shared.setObject(image, forKey: key)
            return image
        } catch {
            if !validImageExts.contains(ext) && !validVideoExts.contains(ext) {
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
    @Published var selectedIndex: Int = 0
    @Published var isSlideshowActive: Bool = false
    @Published var isPaused: Bool = false
    @Published var delaySeconds: Int = 5
    @Published var gridColumnsCount: Int = 3
    @Published var seekTrigger: (direction: Int, count: Int, id: UUID)? = nil
    @Published var showControlsSignal: Bool = false
    @Published var isDarkMode: Bool
    @Published var isFullScreen: Bool = false {
        didSet {
            if !isFullScreen {
                NSCursor.unhide()
            }
        }
    }
    
    // Video Progress Tracking
    @Published var videoCurrentTime: Double = 0
    @Published var videoDuration: Double = 1
    @Published var isScrubbing: Bool = false
    @Published var scrubTargetTime: Double? = nil
    
    private var timer: Timer?
    private var lastSeekTime: Date = Date()
    private var seekAcceleration: Int = 1
    
    init() {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        self.isDarkMode = isDark
    }
    
    var selectedItem: MediaItem? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }
    
    static func spec(for mode: WindowInteractionMode) -> WindowLayoutSpec {
        switch mode {
        case .dropzone:
            return WindowLayoutSpec(width: 400, height: 350, isResizable: false)
        case .browser, .slideshow:
            return WindowLayoutSpec(width: 1120, height: 776, isResizable: true)
        }
    }
    
    func resetVideoState() {
        videoCurrentTime = 0
        videoDuration = 1
        isScrubbing = false
        scrubTargetTime = nil
        seekTrigger = nil
    }
    
    func loadDirectory(_ url: URL, pushHistory: Bool = true) {
        NSCursor.unhide()
        
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
                folderItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: true, isVideo: false))
            } else if validImageExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: false))
            } else if validVideoExts.contains(ext) {
                mediaItems.append(MediaItem(url: file, name: file.lastPathComponent, isDirectory: false, isVideo: true))
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
        resetTimer()
    }
    
    func exitSlideshow() {
        isSlideshowActive = false
        timer?.invalidate()
        resetVideoState()
        NSCursor.unhide()
        
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
        
        var newIndex = selectedIndex
        let count = items.count
        
        // Loop through indices to find the next valid non-directory media item
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
        
        // If we somehow landed on a directory (e.g. all items are folders), exit slideshow
        if selectedItem?.isDirectory == true {
            exitSlideshow()
            return
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
        seekTrigger = (direction: forward ? 1 : -1, count: seekAcceleration, id: UUID())
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
    
    func resetTimer() {
        timer?.invalidate()
        guard isSlideshowActive, !isPaused, let current = selectedItem, !current.isVideo else { return }
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

// MARK: - Safe Native Video Player View
struct NativeVideoView: NSViewRepresentable {
    let url: URL
    let isPaused: Bool
    @Binding var seekTrigger: (direction: Int, count: Int, id: UUID)?
    @Binding var currentTime: Double
    @Binding var duration: Double
    @Binding var scrubTargetTime: Double?
    let onEnd: () -> Void
    
    class Coordinator: NSObject {
        var player: AVPlayer?
        var onEnd: (() -> Void)?
        var observer: Any?
        var timeObserver: Any?
        var lastHandledSeekID: UUID?
        var currentURL: URL?
        
        func cleanup() {
            if let obs = observer {
                NotificationCenter.default.removeObserver(obs)
                observer = nil
            }
            if let timeObs = timeObserver, let p = player {
                p.removeTimeObserver(timeObs)
                timeObserver = nil
            }
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
        let playerItem = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: playerItem)
        playerView.player = player
        playerView.controlsStyle = .none
        
        context.coordinator.player = player
        context.coordinator.onEnd = onEnd
        context.coordinator.currentURL = url
        context.coordinator.setupNotification(for: playerItem)
        
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        context.coordinator.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coordinator = context.coordinator] time in
            guard coordinator?.player != nil else { return }
            DispatchQueue.main.async {
                self.currentTime = time.seconds
                if let dur = player.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                    self.duration = dur
                }
            }
        }
        
        player.play()
        return playerView
    }
    
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: Coordinator) {
        coordinator.cleanup()
        nsView.player = nil
    }
    
    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        context.coordinator.onEnd = onEnd
        
        if context.coordinator.currentURL != url {
            context.coordinator.cleanup()
            context.coordinator.currentURL = url
            
            let playerItem = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: playerItem)
            nsView.player = player
            context.coordinator.player = player
            context.coordinator.setupNotification(for: playerItem)
            
            let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
            context.coordinator.timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak coordinator = context.coordinator] time in
                guard coordinator?.player != nil else { return }
                DispatchQueue.main.async {
                    self.currentTime = time.seconds
                    if let dur = player.currentItem?.duration.seconds, !dur.isNaN, dur > 0 {
                        self.duration = dur
                    }
                }
            }
            player.play()
        }
        
        if isPaused {
            nsView.player?.pause()
        } else {
            nsView.player?.play()
        }
        
        if let scrubTime = scrubTargetTime {
            DispatchQueue.main.async {
                guard let player = context.coordinator.player else { return }
                let target = CMTime(seconds: scrubTime, preferredTimescale: 600)
                player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
                self.scrubTargetTime = nil
            }
        }
        
        if let seek = seekTrigger, seek.id != context.coordinator.lastHandledSeekID {
            context.coordinator.lastHandledSeekID = seek.id
            DispatchQueue.main.async {
                guard let player = context.coordinator.player else { return }
                let baseSeek: Double = 2.0
                let totalOffset = Double(seek.direction) * baseSeek * Double(seek.count)
                let current = player.currentTime().seconds
                let targetTime = CMTime(seconds: max(0, current + totalOffset), preferredTimescale: 600)
                player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
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
            Text("📷").font(.system(size: 80))
            Text("Drop Media or Folders Here").font(.largeTitle.bold())
            Text("Drag & drop images, videos, or click below").font(.title3).foregroundColor(.secondary)
            
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
                if current.isVideo {
                    NativeVideoView(
                        url: current.url,
                        isPaused: state.isPaused,
                        seekTrigger: $state.seekTrigger,
                        currentTime: $state.videoCurrentTime,
                        duration: $state.videoDuration,
                        scrubTargetTime: $state.scrubTargetTime,
                        onEnd: {
                            state.moveSlideshowSelection(by: 1, userInitiated: false)
                        }
                    )
                    .id(current.id)
                } else {
                    PhotoSlideView(url: current.url)
                        .id(current.id)
                }
            }
            
            if showControls {
                VStack {
                    Spacer()
                    
                    HStack(spacing: 16) {
                        Button("◄ Back") { state.moveSlideshowSelection(by: -1) }
                            .buttonStyle(.plain)
                        Button(state.isPaused ? "Play" : "Pause") {
                            state.isPaused.toggle()
                            state.resetTimer()
                        }
                        .buttonStyle(.plain)
                        Button("Next ►") { state.moveSlideshowSelection(by: 1) }
                            .buttonStyle(.plain)
                        
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
                                    .foregroundColor(.white.opacity(0.7))
                            }
                        } else {
                            Stepper("Delay: \(state.delaySeconds)s", value: $state.delaySeconds, in: 1...60)
                                .onChange(of: state.delaySeconds) { state.resetTimer() }
                        }
                        
                        Divider()
                            .frame(height: 18)
                            .background(Color.white.opacity(0.3))
                        
                        Button(action: { state.toggleFullScreen() }) {
                            Image(systemName: state.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        }
                        .buttonStyle(.plain)
                        .help("Toggle Fullscreen")
                        
                        Button("✕ Exit") { state.exitSlideshow() }
                            .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(12)
                    .environment(\.colorScheme, .dark)
                    .foregroundColor(.white)
                    .padding(.bottom, 75)
                    .onHover { hovering in
                        if hovering { NSCursor.arrow.set() }
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
        
        guard state.isFullScreen else { return }
        
        cursorHideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            Task { @MainActor in
                guard state.isFullScreen, !state.isScrubbing else { return }
                if !isCursorHidden {
                    NSCursor.hide()
                    isCursorHidden = true
                }
            }
        }
    }
}

// MARK: - Root View & Key Bindings via Window-Level NSEvent Monitor
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
                    guard let currentWindow = NSApp.keyWindow, currentWindow === event.window || NSApp.windows.contains(where: { $0 === event.window }) else {
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
                            state.adjustDelay(by: -1)
                        } else {
                            state.moveGridSelection(vertical: 1)
                        }
                        return nil
                        
                    case 126: // Up Arrow
                        if state.isSlideshowActive {
                            state.adjustDelay(by: 1)
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
                        if state.isSlideshowActive {
                            state.isPaused.toggle()
                            state.resetTimer()
                        }
                        return nil
                        
                    case 53: // Escape
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
                    appDelegate.onFullScreenChange = { isFullScreen in
                        Task { @MainActor in
                            state.setFullScreenState(isFullScreen)
                        }
                    }
                }
        }
        .defaultSize(width: 400, height: 350)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}