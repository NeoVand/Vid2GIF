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

    // GIF previews encode automatically; WebM editing uses the native player.
    enum PreviewMode { case original, output }
    @Published var previewMode: PreviewMode = .original {
        didSet {
            if previewMode == .output, settings.format == .gif {
                player?.pause()
                isPlaying = false
            }
            schedulePreviewRefresh(immediate: true)
        }
    }
    @Published var previewURL: URL?
    @Published var previewResult: ExportResult?
    @Published var previewError: String?
    @Published var previewIsCurrent = false
    @Published var isInspectingOutput = false
    @Published var previewProgress: Double = 0
    @Published var isPreviewMuted = true { didSet { updateNativePreview() } }
    private let cache = ExportCache()
    private var previewRequest: ExportRequest?
    private var isAdjustingSettings = false
    @Published var isGeneratingPreview = false
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private var previewExporter: MediaExporter?

    // Export state
    @Published var isExporting = false
    @Published var exportProgress: Double = 0
    @Published var exportMessage = ""
    @Published var exportResult: ExportResult?
    @Published var exportError: String?

    private var timeObserver: Any?
    private var exporter: MediaExporter?
    private var thumbnailTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var nativePreviewTask: Task<Void, Never>?
    private var nativeAsset: AVAsset?
    private var nativeTrack: AVAssetTrack?
    private var naturalSize: CGSize = .zero
    private var sourceTransform: CGAffineTransform = .identity
    private var nativeCompositionKey: [Double]?
    private var exportCancellationRequested = false

    var isLiveVideoPreview: Bool { settings.format == .webm && previewMode == .output }

    var exportSettings: ExportSettings {
        var value = settings
        value.startTime = trimStart
        value.endTime = trimEnd
        return value
    }

    private var currentRequest: ExportRequest? {
        videoURL.map { ExportRequest(source: $0, settings: exportSettings) }
    }

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
        guard !isExporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .video]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            load(url: url)
        }
    }

    func load(url: URL) {
        guard !isExporting else { return }
        unload()
        isLoading = true
        loadError = nil
        videoURL = url

        loadTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw ExportError.noVideoTrack
                }
                let duration = try await asset.load(.duration).seconds
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let fps = try await track.load(.nominalFrameRate)

                guard !Task.isCancelled else { return }
                let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
                self.nativeAsset = asset
                self.nativeTrack = track
                self.naturalSize = naturalSize
                self.sourceTransform = transform
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
                // Show the actual output from the start.
                self.previewMode = .output
            } catch {
                guard !Task.isCancelled else { return }
                self.isLoading = false
                self.videoURL = nil
                self.loadError = error.localizedDescription
            }
        }
    }

    func unload() {
        if let obs = timeObserver, let player { player.removeTimeObserver(obs) }
        timeObserver = nil
        loadTask?.cancel()
        nativePreviewTask?.cancel()
        nativeAsset = nil
        nativeTrack = nil
        nativeCompositionKey = nil
        thumbnailTask?.cancel()
        previewGeneration += 1
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
        clearPreview()
        cache.clear()
        isInspectingOutput = false
        isAdjustingSettings = false
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
        if previewMode == .output, settings.format == .gif {
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

    /// GIF scrubbing returns to the source; WebM keeps the live editing preview.
    func scrub(to seconds: Double) {
        if previewMode == .output, settings.format == .gif { previewMode = .original }
        seek(to: seconds)
    }

    func stepFrame(_ direction: Int) {
        if previewMode == .output, settings.format == .gif { previewMode = .original }
        player?.pause()
        isPlaying = false
        let frameDur = isLiveVideoPreview ? settings.speed / settings.fps : (sourceFPS > 0 ? 1.0 / sourceFPS : 1.0 / 30.0)
        seek(to: currentTime + frameDur * Double(direction))
    }

    func setTrimIn() {
        trimStart = min(currentTime, trimEnd - 0.05)
    }

    func setTrimOut() {
        trimEnd = max(currentTime, trimStart + 0.05)
    }

    // MARK: - Native editing and encoded previews

    private func updateNativePreview() {
        guard let player else { return }
        if previewMode == .output, settings.format == .gif {
            player.pause()
            isPlaying = false
        }
        player.isMuted = isPreviewMuted || !settings.includeAudio || settings.format == .gif
        if isPlaying { player.rate = Float(settings.speed) }
        guard isLiveVideoPreview, let asset = nativeAsset, let track = nativeTrack else {
            nativePreviewTask?.cancel()
            nativeCompositionKey = nil
            player.currentItem?.videoComposition = nil
            return
        }
        let key = [Double(settings.outputWidth), settings.fps, settings.speed]
        guard nativeCompositionKey != key else { return }
        nativeCompositionKey = key
        nativePreviewTask?.cancel()
        let s = settings
        nativePreviewTask = Task { [weak self] in
            // Coalesce rapid slider events without decoding or encoding a file.
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled, let self else { return }
            player.currentItem?.videoComposition = FrameSource.composition(
                asset: asset, track: track, naturalSize: naturalSize, transform: sourceTransform,
                duration: CMTime(seconds: duration, preferredTimescale: 600), settings: s)
        }
    }

    func beginSettingsAdjustment() {
        guard !isAdjustingSettings else { return }
        isAdjustingSettings = true
        previewGeneration += 1
        previewTask?.cancel()
        previewExporter?.cancel()
        isGeneratingPreview = false
    }

    func endSettingsAdjustment() {
        isAdjustingSettings = false
        schedulePreviewRefresh()
    }

    func inspectOutput() {
        guard settings.format == .webm, !isLoading, !isExporting else { return }
        player?.pause()
        isPlaying = false
        isInspectingOutput = true
        schedulePreviewRefresh(immediate: true)
    }

    /// Keep the previous GIF visible during updates. WebM is only encoded when
    /// explicitly inspected or exported, never as a side effect of editing.
    func schedulePreviewRefresh(immediate: Bool = false) {
        updateNativePreview()
        guard !isExporting else { return }
        previewGeneration += 1
        let generation = previewGeneration
        previewTask?.cancel()
        previewExporter?.cancel()
        previewError = nil
        previewIsCurrent = false
        isGeneratingPreview = false
        if previewResult?.format != settings.format { clearPreview() }
        guard hasVideo, !isLoading, let request = currentRequest else { return }
        if let result = cache.result(for: request) {
            installPreview(result, request: request)
            return
        }
        guard !isAdjustingSettings,
              (settings.format == .gif && previewMode == .output) || isInspectingOutput else { return }
        isGeneratingPreview = true
        previewProgress = 0
        previewRequest = request
        previewTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(350)) }
            guard !Task.isCancelled else { return }
            await self?.generatePreview(request: request, generation: generation)
        }
    }

    private func clearPreview() {
        previewURL = nil
        previewResult = nil
        previewRequest = nil
        previewError = nil
        previewIsCurrent = false
    }

    private func installPreview(_ result: ExportResult, request: ExportRequest) {
        previewURL = result.url
        previewResult = result
        previewRequest = request
        previewIsCurrent = true
        isGeneratingPreview = false
        previewProgress = 1
    }

    private func generatePreview(request: ExportRequest, generation: Int) async {
        var output: URL?
        do {
            let url = try cache.makeURL(format: request.settings.format)
            output = url
            let exporter = MediaExporter()
            previewExporter = exporter
            let result = try await Task.detached(priority: .userInitiated) { [weak self] in
                try await exporter.export(assetURL: request.source, to: url, settings: request.settings) { p, message in
                    Task { @MainActor [weak self] in
                        guard let self, generation == previewGeneration else { return }
                        previewProgress = p
                        if isExporting { exportProgress = p * 0.95; exportMessage = message }
                    }
                }
            }.value
            guard generation == previewGeneration else {
                try? FileManager.default.removeItem(at: url)
                return
            }
            guard request == currentRequest else {
                throw ExportError.readerFailed("The source video changed. Try previewing again.")
            }
            cache.store(result, for: request)
            installPreview(result, request: request)
            previewExporter = nil
        } catch {
            if generation == previewGeneration {
                isGeneratingPreview = false
                previewExporter = nil
                if case ExportError.cancelled = error {} else { previewError = error.localizedDescription }
            }
            if let output { try? FileManager.default.removeItem(at: output) }
        }
    }

    // MARK: - Export

    func startExport() {
        guard let videoURL, !isExporting, !isLoading else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [settings.format.contentType]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + "." + settings.format.rawValue
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let output = panel.url else { return }
        Task { await export(to: output) }
    }

    /// Reuse a completed encode, or join a matching preview already in progress.
    /// Both paths save atomically and never encode the same settings twice.
    func export(to output: URL) async {
        guard let request = currentRequest, !isExporting, !isLoading else { return }
        player?.pause()
        isPlaying = false
        isExporting = true
        exportCancellationRequested = false
        exportProgress = 0
        exportMessage = "Preparing export…"
        exportResult = nil
        exportError = nil
        let started = Date()
        defer { isExporting = false; exporter = nil }
        do {
            if isGeneratingPreview, previewRequest == request, let previewTask {
                exporter = previewExporter
                await previewTask.value
            } else {
                previewGeneration += 1
                previewTask?.cancel()
                previewExporter?.cancel()
                isGeneratingPreview = false
            }
            if exportCancellationRequested { throw ExportError.cancelled }
            guard request == currentRequest else {
                throw ExportError.readerFailed("The source video changed. Try exporting again.")
            }
            let encoder = MediaExporter()
            exporter = encoder
            let encoded: ExportResult
            if let cached = cache.result(for: request) {
                encoded = cached
            } else {
                let url = try cache.makeURL(format: request.settings.format)
                do {
                    encoded = try await Task.detached(priority: .userInitiated) { [weak self] in
                        try await encoder.export(assetURL: request.source, to: url, settings: request.settings) { p, message in
                            Task { @MainActor [weak self] in
                                self?.exportProgress = p * 0.95
                                self?.exportMessage = message
                            }
                        }
                    }.value
                    guard request == currentRequest else {
                        throw ExportError.readerFailed("The source video changed. Try exporting again.")
                    }
                } catch {
                    try? FileManager.default.removeItem(at: url)
                    throw error
                }
                cache.store(encoded, for: request)
            }
            if exportCancellationRequested { throw ExportError.cancelled }
            installPreview(encoded, request: request)
            exportMessage = "Saving…"
            let saved = try await Task.detached(priority: .userInitiated) {
                try encoder.saveCached(encoded, to: output, sourceURL: request.source)
            }.value
            exportResult = ExportResult(url: saved.url, frames: saved.frames, bytes: saved.bytes,
                                        wallTime: Date().timeIntervalSince(started), size: saved.size, format: saved.format)
            exportProgress = 1
        } catch {
            if case ExportError.cancelled = error {} else { exportError = error.localizedDescription }
        }
    }

    func cancelExport() {
        exportCancellationRequested = true
        exporter?.cancel()
        previewTask?.cancel()
        previewExporter?.cancel()
        previewGeneration += 1
        isGeneratingPreview = false
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
