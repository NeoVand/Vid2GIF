import Foundation
import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    // Loaded video
    @Published var videoURL: URL?
    @Published var player: AVPlayer?
    @Published var duration: Double = 0
    @Published var sourceSize: CGSize = .zero
    @Published var sourceFPS: Double = 0
    @Published var thumbnails: [CGImage] = []
    @Published var loadError: String?
    @Published var isLoading = false

    // Timeline state (seconds)
    @Published var trimStart: Double = 0 {
        didSet { if oldValue != trimStart { schedulePreviewRefresh() } }
    }
    @Published var trimEnd: Double = 0 {
        didSet { if oldValue != trimEnd { schedulePreviewRefresh() } }
    }
    @Published var currentTime: Double = 0
    @Published var isPlaying = false

    // Export configuration
    @Published var settings = ExportSettings() {
        didSet { schedulePreviewRefresh() }
    }

    // Live GIF preview: the preview pane renders the REAL encoded GIF.
    enum PreviewMode { case original, gif }
    @Published var previewMode: PreviewMode = .original {
        didSet {
            if previewMode == .gif {
                player?.pause()
                isPlaying = false
                schedulePreviewRefresh(immediate: true)
            }
        }
    }
    @Published var previewGIFURL: URL?
    @Published var previewResult: ExportResult?
    @Published var isGeneratingPreview = false
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var previewExporter: GIFExporter?

    // Export state
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportMessage = ""
    @Published var exportResult: ExportResult?
    @Published var exportError: String?

    private var timeObserver: Any?
    private var exporter: GIFExporter?
    private var thumbnailTask: Task<Void, Never>?

    var hasVideo: Bool { videoURL != nil }

    var clipDuration: Double { max(0, trimEnd - trimStart) }

    var outputDuration: Double { settings.speed > 0 ? clipDuration / settings.speed : clipDuration }

    var outputPixelSize: (width: Int, height: Int) {
        guard sourceSize.width > 0 else { return (0, 0) }
        return settings.outputSize(for: sourceSize)
    }

    /// Rough pre-export size estimate (bytes). Calibrated for screen content
    /// with delta encoding; camera footage runs higher.
    var estimatedBytes: Int {
        let (w, h) = outputPixelSize
        let frames = outputDuration * settings.fps
        let bytesPerPixel = settings.useDelta ? 0.13 : 0.42
        return Int(Double(w * h) * frames * bytesPerPixel)
    }

    // MARK: - Loading

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .video]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        unload()
        isLoading = true
        loadError = nil
        videoURL = url

        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw ExportError.noVideoTrack
                }
                let duration = try await asset.load(.duration).seconds
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let fps = try await track.load(.nominalFrameRate)

                let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
                self.sourceSize = CGSize(width: abs(rect.width), height: abs(rect.height))
                self.duration = duration
                self.sourceFPS = Double(fps)
                self.trimStart = 0
                self.trimEnd = duration
                self.currentTime = 0

                // Sensible defaults per clip: don't upscale, cap fps at source.
                if self.sourceSize.width < Double(self.settings.outputWidth) {
                    self.settings.outputWidth = Int(self.sourceSize.width)
                }
                if fps > 0, Double(fps) < self.settings.fps {
                    self.settings.fps = Double(Int(fps.rounded()))
                }

                let player = AVPlayer(url: url)
                player.isMuted = true
                self.player = player
                self.installTimeObserver(on: player)
                self.isLoading = false
                self.generateThumbnails(asset: asset)
                // The point of the app: show the real GIF from the start.
                self.previewMode = .gif
            } catch {
                self.isLoading = false
                self.videoURL = nil
                self.loadError = error.localizedDescription
            }
        }
    }

    func unload() {
        if let obs = timeObserver, let player { player.removeTimeObserver(obs) }
        timeObserver = nil
        thumbnailTask?.cancel()
        previewTask?.cancel()
        previewExporter?.cancel()
        player?.pause()
        player = nil
        videoURL = nil
        thumbnails = []
        exportResult = nil
        exportError = nil
        isPlaying = false
        duration = 0
        currentTime = 0
        previewGIFURL = nil
        previewResult = nil
        isGeneratingPreview = false
        previewMode = .original
    }

    private func installTimeObserver(on player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 60), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.currentTime = time.seconds
                // Loop playback inside the trim range.
                if self.isPlaying, time.seconds >= self.trimEnd - 0.02 {
                    self.seek(to: self.trimStart)
                }
            }
        }
    }

    private func generateThumbnails(asset: AVAsset) {
        thumbnailTask?.cancel()
        let duration = self.duration
        thumbnailTask = Task {
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 240, height: 120)
            gen.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
            gen.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)
            let count = 16
            var images: [CGImage] = []
            for i in 0..<count {
                if Task.isCancelled { return }
                let t = duration * (Double(i) + 0.5) / Double(count)
                if let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                    images.append(img)
                    let snapshot = images
                    self.thumbnails = snapshot
                }
            }
        }
    }

    // MARK: - Playback

    func togglePlayback() {
        guard let player else { return }
        if previewMode == .gif {
            // Playback controls operate on the source video.
            previewMode = .original
        }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= trimEnd - 0.05 || currentTime < trimStart {
                seek(to: trimStart)
            }
            player.play()
            player.rate = Float(settings.speed)
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, 0), duration)
        currentTime = clamped
        player?.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: CMTime(value: 1, timescale: 60),
            toleranceAfter: CMTime(value: 1, timescale: 60)
        )
    }

    /// Scrubbing from the timeline always inspects the source video.
    func scrub(to seconds: Double) {
        if previewMode == .gif { previewMode = .original }
        seek(to: seconds)
    }

    func stepFrame(_ direction: Int) {
        if previewMode == .gif { previewMode = .original }
        player?.pause()
        isPlaying = false
        let frameDur = sourceFPS > 0 ? 1.0 / sourceFPS : 1.0 / 30.0
        seek(to: currentTime + frameDur * Double(direction))
    }

    func setTrimIn() {
        trimStart = min(currentTime, trimEnd - 0.05)
    }

    func setTrimOut() {
        trimEnd = max(currentTime, trimStart + 0.05)
    }

    // MARK: - Live GIF preview

    /// Debounced regeneration of the real-output preview GIF.
    func schedulePreviewRefresh(immediate: Bool = false) {
        guard previewMode == .gif, hasVideo, !isExporting else { return }
        previewGeneration += 1
        let gen = previewGeneration
        previewTask?.cancel()
        previewExporter?.cancel()
        previewTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .milliseconds(350))
            }
            guard !Task.isCancelled else { return }
            await self?.generatePreview(generation: gen)
        }
    }

    private func generatePreview(generation: Int) async {
        guard let videoURL else { return }
        isGeneratingPreview = true

        var s = settings
        s.startTime = trimStart
        s.endTime = trimEnd

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Vid2GIF-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let outURL = dir.appendingPathComponent("preview-\(generation).gif")

        let exporter = GIFExporter()
        previewExporter = exporter
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try await exporter.export(assetURL: videoURL, to: outURL, settings: s) { _, _ in }
            }.value
            if generation == previewGeneration {
                let old = previewGIFURL
                previewGIFURL = outURL
                previewResult = result
                isGeneratingPreview = false
                if let old, old != outURL {
                    try? FileManager.default.removeItem(at: old)
                }
            } else {
                try? FileManager.default.removeItem(at: outURL)
            }
        } catch {
            if generation == previewGeneration {
                isGeneratingPreview = false
            }
            try? FileManager.default.removeItem(at: outURL)
        }
    }

    // MARK: - Export

    func startExport() {
        guard let videoURL, !isExporting else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".gif"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let outURL = panel.url else { return }

        player?.pause()
        isPlaying = false
        previewTask?.cancel()
        previewExporter?.cancel()
        isExporting = true
        exportProgress = 0
        exportMessage = "Starting…"
        exportResult = nil
        exportError = nil

        var s = settings
        s.startTime = trimStart
        s.endTime = trimEnd

        let exporter = GIFExporter()
        self.exporter = exporter

        Task.detached(priority: .userInitiated) { [s] in
            do {
                let result = try await exporter.export(assetURL: videoURL, to: outURL, settings: s) { p, msg in
                    Task { @MainActor [weak self] in
                        self?.exportProgress = p
                        self?.exportMessage = msg
                    }
                }
                await MainActor.run { [weak self] in
                    self?.isExporting = false
                    self?.exportResult = result
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isExporting = false
                    if case ExportError.cancelled = error {
                        self?.exportError = nil
                    } else {
                        self?.exportError = error.localizedDescription
                    }
                }
            }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }
}

func formatBytes(_ bytes: Int) -> String {
    if bytes < 1000 { return "\(bytes) B" }
    if bytes < 1_000_000 { return String(format: "%.0f KB", Double(bytes) / 1000) }
    return String(format: "%.1f MB", Double(bytes) / 1_000_000)
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00.00" }
    let m = Int(seconds) / 60
    let s = seconds - Double(m * 60)
    return String(format: "%d:%05.2f", m, s)
}
