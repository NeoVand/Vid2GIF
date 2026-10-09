import SwiftUI
import AVFoundation
import AppKit
import WebKit

struct ExportPreviewView: View {
    let url: URL
    let format: ExportFormat

    var body: some View {
        if format == .gif {
            AnimatedGIFView(url: url)
        } else {
            WebMPreviewView(url: url)
        }
    }
}

/// WebKit plays WebM directly, so the preview shows the actual exported file.
/// Used only for explicit output inspection and the result card. All controls
/// are native SwiftUI; the editing canvas always uses AVPlayerLayer.
struct WebMPreviewView: NSViewRepresentable {
    let url: URL
    var playback: WebMPlaybackController? = nil

    func makeCoordinator() -> Coordinator { Coordinator(playback: playback) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(context.coordinator, name: "playback")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .black
        playback?.view = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        // Keep both HTML and media inside one isolated read-access directory.
        // A hard link avoids copying large videos and survives preview cleanup.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vid2gif-player-\(UUID().uuidString)", isDirectory: true)
        let htmlURL = directory.appendingPathComponent("index.html")
        let videoURL = directory.appendingPathComponent("video.webm")
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;width:100%;height:100%;background:#000;overflow:hidden}video{width:100%;height:100%;object-fit:contain}p{color:#ddd;font:13px system-ui;text-align:center;padding:24px}</style></head>
        <body><video src="video.webm" autoplay loop muted playsinline aria-label="WebM output preview"
        onclick="this.paused ? this.play() : this.pause()" oncontextmenu="return false"
        onerror="this.hidden=true;document.getElementById('error').hidden=false"></video>
        <p id="error" hidden>Unable to play this preview. You can still export the video and open it in a WebM-compatible player.</p>
        <script>
        const video = document.querySelector('video');
        const report = () => window.webkit.messageHandlers.playback.postMessage({
            time: video.currentTime, duration: Number.isFinite(video.duration) ? video.duration : 0,
            playing: !video.paused, muted: video.muted
        });
        for (const event of ['loadedmetadata','timeupdate','play','pause','volumechange']) video.addEventListener(event, report);
        </script></body></html>
        """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            context.coordinator.directories.append(directory)
            do {
                try FileManager.default.linkItem(at: url, to: videoURL)
            } catch {
                try FileManager.default.copyItem(at: url, to: videoURL)
            }
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            view.loadFileURL(htmlURL, allowingReadAccessTo: directory)
        } catch {
            view.loadHTMLString("<p>Unable to load video preview.</p>", baseURL: nil)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "playback")
        coordinator.playback?.view = nil
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let playback: WebMPlaybackController?
        init(playback: WebMPlaybackController?) { self.playback = playback }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? [String: Any] else { return }
            playback?.currentTime = value["time"] as? Double ?? 0
            playback?.duration = value["duration"] as? Double ?? 0
            playback?.isPlaying = value["playing"] as? Bool ?? false
            playback?.isMuted = value["muted"] as? Bool ?? true
        }
        var url: URL?
        var directories: [URL] = []
        deinit { for url in directories { try? FileManager.default.removeItem(at: url) } }
    }
}

@MainActor
final class WebMPlaybackController: ObservableObject {
    weak var view: WKWebView?
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPlaying = true
    @Published var isMuted = true

    func togglePlayback() { view?.evaluateJavaScript("(()=>{const v=document.querySelector('video'); v.paused ? v.play() : v.pause();})()", completionHandler: nil) }
    func toggleMute() { view?.evaluateJavaScript("(()=>{const v=document.querySelector('video'); v.muted = !v.muted;})()", completionHandler: nil) }
    func seek(to time: Double) {
        guard time.isFinite else { return }
        view?.evaluateJavaScript("document.querySelector('video').currentTime = \(max(0, min(time, duration)));", completionHandler: nil)
    }
}

struct EncodedOutputInspector: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = WebMPlaybackController()

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("WebM output").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(SubtleButtonStyle()).keyboardShortcut(.cancelAction)
            }
            ZStack {
                Color.black
                if let result = model.previewResult, result.format == .webm {
                    WebMPreviewView(url: result.url, playback: playback).id(result.url)
                } else if !model.isGeneratingPreview {
                    Text(model.previewError ?? "Preview unavailable").padding(24)
                }
                if model.isGeneratingPreview, model.previewURL == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            HStack(spacing: 12) {
                Button { playback.togglePlayback() } label: {
                    HugeIcon(name: playback.isPlaying ? "pause" : "play", size: 18)
                }
                .buttonStyle(SubtleButtonStyle())
                .accessibilityLabel(playback.isPlaying ? "Pause output" : "Play output")
                .keyboardShortcut(.space, modifiers: [])
                Slider(value: Binding(get: { playback.currentTime }, set: { playback.seek(to: $0) }),
                       in: 0...max(0.01, playback.duration))
                    .accessibilityLabel("Output position")
                Text(formatTime(playback.currentTime)).monospacedDigit()
                Button { playback.toggleMute() } label: {
                    Image(systemName: playback.isMuted ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(SubtleButtonStyle())
                .accessibilityLabel(playback.isMuted ? "Unmute output" : "Mute output")
            }
            .disabled(model.isGeneratingPreview || playback.duration == 0)
            HStack {
                if model.isGeneratingPreview {
                    ProgressView(value: model.previewProgress).frame(width: 120)
                    Text("Encoding output…").foregroundStyle(Theme.textSecondary)
                } else if let error = model.previewError {
                    Text(error).foregroundStyle(Theme.textSecondary)
                    Button("Retry") { model.schedulePreviewRefresh(immediate: true) }
                } else if let result = model.previewResult {
                    Text("\(result.size.width)×\(result.size.height) · \(result.frames) frames · \(formatBytes(result.bytes))")
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Ready to export").foregroundStyle(Theme.textTertiary)
                }
            }
            .font(.system(size: 11))
        }
        .padding(20)
        .frame(width: 700, height: 540)
        .background(Theme.bg)
        .preferredColorScheme(.dark)
    }
}

/// Bare AVPlayerLayer host — hardware-accelerated, no system chrome.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let v = PlayerHostView()
        v.playerLayer.player = player
        return v
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        init() {
            super.init(frame: .zero)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}

/// Animated GIF preview using NSImageView (which natively animates GIFs).
struct AnimatedGIFView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> NSImageView {
        let v = NSImageView()
        v.animates = true
        v.imageScaling = .scaleProportionallyUpOrDown
        v.image = NSImage(contentsOf: url)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return v
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        if context.coordinator.url != url {
            context.coordinator.url = url
            nsView.image = NSImage(contentsOf: url)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator {
        var url: URL
        init(url: URL) { self.url = url }
    }
}
