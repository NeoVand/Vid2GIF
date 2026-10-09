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
/// Start muted; the native video controls allow playback, seeking and audio.
struct WebMPreviewView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .black
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
        <body><video src="video.webm" autoplay loop muted playsinline controls aria-label="WebM output preview"
        onerror="this.hidden=true;document.getElementById('error').hidden=false"></video>
        <p id="error" hidden>Unable to play this preview. You can still export the video and open it in a WebM-compatible player.</p></body></html>
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
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator {
        var url: URL?
        var directories: [URL] = []
        deinit { for url in directories { try? FileManager.default.removeItem(at: url) } }
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
