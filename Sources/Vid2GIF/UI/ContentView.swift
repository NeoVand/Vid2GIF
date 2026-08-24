import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var isDropTargeted = false
    @State private var keyMonitor: Any?
    @State private var showAbout = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            if model.hasVideo {
                editor
            } else {
                EmptyStateView(isDropTargeted: $isDropTargeted)
            }

            if model.isExporting {
                ExportProgressOverlay()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let result = model.exportResult {
                ExportResultCard(result: result)
                    .padding(20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: model.exportResult != nil)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .alert("Couldn't open video", isPresented: Binding(
            get: { model.loadError != nil },
            set: { if !$0 { model.loadError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.loadError ?? "")
        }
        .alert("Export failed", isPresented: Binding(
            get: { model.exportError != nil },
            set: { if !$0 { model.exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.exportError ?? "")
        }
        .onAppear(perform: installKeyMonitor)
        .preferredColorScheme(.dark)
    }

    // MARK: editor layout

    private var editor: some View {
        HStack(spacing: 14) {
            VStack(spacing: 12) {
                topBar
                preview
                TimelineView()
                    .padding(14)
                    .panel()
            }

            ControlsPanel()
                .frame(width: 290)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .sheet(isPresented: $showAbout) { AboutView() }
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                Button {
                    showAbout = true
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "film.stack")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                        Text("Vid2GIF")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }
                .buttonStyle(.plain)
                .help("About Vid2GIF")

                if let url = model.videoURL {
                    Text(url.lastPathComponent)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Text("\(Int(model.sourceSize.width))×\(Int(model.sourceSize.height)) · \(Int(model.sourceFPS.rounded())) fps · \(formatTime(model.duration))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }

                Spacer()

                Button("Open…") { model.presentOpenPanel() }
                    .buttonStyle(SubtleButtonStyle())
                    .keyboardShortcut("o", modifiers: .command)
            }

            previewModeToggle
        }
        .padding(.top, 14) // clear the traffic lights with transparent titlebar
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black)

            if model.previewMode == .gif {
                gifPreview
            } else {
                sourcePreview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Theme.panelBorder, lineWidth: 1)
        )
    }

    private var sourcePreview: some View {
        ZStack {
            if let player = model.player {
                PlayerLayerView(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            if !model.isPlaying {
                Circle()
                    .fill(.black.opacity(0.5))
                    .frame(width: 64, height: 64)
                    .overlay(
                        Image(systemName: "play.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 2)
                    )
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlayback() }
    }

    /// The real output: an actual encoded GIF, looping exactly as exported.
    private var gifPreview: some View {
        ZStack {
            if let url = model.previewGIFURL {
                AnimatedGIFView(url: url)
                    .padding(10)
                    .id(url) // force refresh when a new preview lands
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Rendering GIF preview…")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if let result = model.previewResult {
                HStack(spacing: 8) {
                    if model.isGeneratingPreview {
                        ProgressView().controlSize(.mini)
                    }
                    Text(formatBytes(result.bytes))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                    Text("\(result.size.width)×\(result.size.height) · \(result.frames)f")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.black.opacity(0.65)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                .padding(12)
            }
        }
    }

    private var previewModeToggle: some View {
        HStack(spacing: 2) {
            modeButton("Source", mode: .original)
            modeButton("GIF", mode: .gif)
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    private func modeButton(_ label: String, mode: AppModel.PreviewMode) -> some View {
        let selected = model.previewMode == mode
        return Button {
            model.previewMode = mode
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selected ? Theme.selection : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: input

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            let videoExts = ["mov", "mp4", "m4v", "avi", "webm", "mkv", "mpg", "mpeg", "gif"]
            guard videoExts.contains(url.pathExtension.lowercased()) else { return }
            Task { @MainActor in
                model.load(url: url)
            }
        }
        return true
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Don't steal keys from text editing or when modifiers are held.
            if event.modifierFlags.intersection([.command, .option, .control]).isEmpty == false {
                return event
            }
            if let responder = NSApp.keyWindow?.firstResponder,
               responder is NSTextView || responder is NSTextField {
                return event
            }
            guard model.hasVideo, !model.isExporting else { return event }

            switch event.keyCode {
            case 49: // space
                model.togglePlayback()
                return nil
            case 34: // i
                model.setTrimIn()
                return nil
            case 31: // o
                model.setTrimOut()
                return nil
            case 123: // left arrow
                model.stepFrame(-1)
                return nil
            case 124: // right arrow
                model.stepFrame(1)
                return nil
            default:
                return event
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)

            VStack(spacing: 4) {
                Text("Vid2GIF")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Version \(version)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            }

            Text("Blazingly fast, hardware-accelerated\nvideo → GIF conversion for macOS.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(2)

            Text("Developed by Neo Mohsenvand")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textPrimary)

            Button {
                NSWorkspace.shared.open(URL(string: "https://github.com/NeoVand/Vid2GIF")!)
            } label: {
                HStack(spacing: 7) {
                    GitHubMark()
                        .frame(width: 15, height: 15)
                    Text("View on GitHub")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(GradientButtonStyle())

            Button("Close") { dismiss() }
                .buttonStyle(SubtleButtonStyle())
                .keyboardShortcut(.cancelAction)
        }
        .padding(28)
        .frame(width: 300)
        .background(Theme.bg)
    }
}

/// The GitHub octocat silhouette as a vector shape (no assets needed).
struct GitHubMark: View {
    var body: some View {
        GitHubShape()
            .fill(Theme.textPrimary)
            .aspectRatio(1, contentMode: .fit)
    }
}

struct GitHubShape: Shape {
    func path(in rect: CGRect) -> Path {
        // GitHub mark, normalized from the official 16×16 octicon path.
        let s = min(rect.width, rect.height) / 16
        var p = Path()
        p.move(to: CGPoint(x: 8, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: 8.2), control1: CGPoint(x: 3.58, y: 0), control2: CGPoint(x: 0, y: 3.67))
        p.addCurve(to: CGPoint(x: 5.47, y: 15.98), control1: CGPoint(x: 0, y: 11.82), control2: CGPoint(x: 2.29, y: 14.9))
        p.addCurve(to: CGPoint(x: 6.02, y: 15.59), control1: CGPoint(x: 5.87, y: 16.06), control2: CGPoint(x: 6.02, y: 15.81))
        p.addCurve(to: CGPoint(x: 6.01, y: 14.19), control1: CGPoint(x: 6.02, y: 15.4), control2: CGPoint(x: 6.01, y: 14.87))
        p.addCurve(to: CGPoint(x: 3.31, y: 13.19), control1: CGPoint(x: 3.78, y: 14.69), control2: CGPoint(x: 3.31, y: 13.19))
        p.addCurve(to: CGPoint(x: 2.18, y: 11.66), control1: CGPoint(x: 2.95, y: 12.25), control2: CGPoint(x: 2.42, y: 11.86))
        p.addCurve(to: CGPoint(x: 2.26, y: 11.09), control1: CGPoint(x: 1.26, y: 11.02), control2: CGPoint(x: 2.25, y: 11.03))
        p.addCurve(to: CGPoint(x: 3.9, y: 12.22), control1: CGPoint(x: 3.28, y: 11.16), control2: CGPoint(x: 3.82, y: 12.16))
        p.addCurve(to: CGPoint(x: 6.94, y: 13.11), control1: CGPoint(x: 4.8, y: 13.81), control2: CGPoint(x: 6.26, y: 13.36))
        p.addCurve(to: CGPoint(x: 7.61, y: 11.68), control1: CGPoint(x: 7.03, y: 12.44), control2: CGPoint(x: 7.29, y: 11.98))
        p.addCurve(to: CGPoint(x: 3.95, y: 7.62), control1: CGPoint(x: 5.83, y: 11.47), control2: CGPoint(x: 3.95, y: 10.77))
        p.addCurve(to: CGPoint(x: 4.79, y: 5.42), control1: CGPoint(x: 3.95, y: 6.72), control2: CGPoint(x: 4.27, y: 5.99))
        p.addCurve(to: CGPoint(x: 4.87, y: 3.24), control1: CGPoint(x: 4.7, y: 5.21), control2: CGPoint(x: 4.42, y: 4.38))
        p.addCurve(to: CGPoint(x: 7.12, y: 4.08), control1: CGPoint(x: 4.87, y: 3.24), control2: CGPoint(x: 5.55, y: 3.02))
        p.addCurve(to: CGPoint(x: 8, y: 3.96), control1: CGPoint(x: 7.41, y: 4), control2: CGPoint(x: 7.7, y: 3.96))
        p.addCurve(to: CGPoint(x: 8.88, y: 4.08), control1: CGPoint(x: 8.3, y: 3.96), control2: CGPoint(x: 8.59, y: 4))
        p.addCurve(to: CGPoint(x: 11.13, y: 3.24), control1: CGPoint(x: 10.45, y: 3.02), control2: CGPoint(x: 11.13, y: 3.24))
        p.addCurve(to: CGPoint(x: 11.21, y: 5.42), control1: CGPoint(x: 11.58, y: 4.38), control2: CGPoint(x: 11.3, y: 5.21))
        p.addCurve(to: CGPoint(x: 12.05, y: 7.62), control1: CGPoint(x: 11.73, y: 5.99), control2: CGPoint(x: 12.05, y: 6.72))
        p.addCurve(to: CGPoint(x: 8.38, y: 11.67), control1: CGPoint(x: 12.05, y: 10.78), control2: CGPoint(x: 10.16, y: 11.47))
        p.addCurve(to: CGPoint(x: 9.1, y: 13.23), control1: CGPoint(x: 8.66, y: 11.91), control2: CGPoint(x: 9.1, y: 12.39))
        p.addCurve(to: CGPoint(x: 9.08, y: 15.59), control1: CGPoint(x: 9.1, y: 14.35), control2: CGPoint(x: 9.08, y: 15.26))
        p.addCurve(to: CGPoint(x: 9.63, y: 15.97), control1: CGPoint(x: 9.08, y: 15.82), control2: CGPoint(x: 9.23, y: 16.07))
        p.addCurve(to: CGPoint(x: 16, y: 8.2), control1: CGPoint(x: 12.81, y: 14.9), control2: CGPoint(x: 16, y: 11.82))
        p.addCurve(to: CGPoint(x: 8, y: 0), control1: CGPoint(x: 16, y: 3.67), control2: CGPoint(x: 12.42, y: 0))
        p.closeSubpath()
        return p.applying(CGAffineTransform(scaleX: s, y: s))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    @EnvironmentObject var model: AppModel
    @Binding var isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: 96, height: 96)
                    .opacity(0.15)
                Image(systemName: "film.stack")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(Theme.accentGradient)
            }

            VStack(spacing: 8) {
                Text("Drop a video to begin")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Trim, tune, and convert to a beautifully compressed GIF.\nHardware-accelerated — even long clips convert in seconds.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                model.presentOpenPanel()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text("Browse Files")
                }
                .frame(width: 160)
            }
            .buttonStyle(GradientButtonStyle())
            .keyboardShortcut("o", modifiers: .command)

            Text("MOV · MP4 · M4V · WEBM")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isDropTargeted ? Theme.accent : Color.white.opacity(0.1),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
                .padding(28)
                .animation(.easeOut(duration: 0.15), value: isDropTargeted)
        )
    }
}

// MARK: - Export progress

struct ExportProgressOverlay: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            VStack(spacing: 18) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.1), lineWidth: 6)
                        .frame(width: 72, height: 72)
                    Circle()
                        .trim(from: 0, to: model.exportProgress)
                        .stroke(
                            Theme.accentGradient,
                            style: StrokeStyle(lineWidth: 6, lineCap: .round)
                        )
                        .frame(width: 72, height: 72)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.2), value: model.exportProgress)
                    Text("\(Int(model.exportProgress * 100))%")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                }

                Text(model.exportMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)

                Button("Cancel") { model.cancelExport() }
                    .buttonStyle(SubtleButtonStyle())
            }
            .padding(36)
            .panel(cornerRadius: 20)
        }
    }
}

// MARK: - Export result

struct ExportResultCard: View {
    @EnvironmentObject var model: AppModel
    let result: ExportResult

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("GIF Exported")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Button {
                    model.exportResult = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            AnimatedGIFView(url: result.url)
                .frame(width: 280, height: 175)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrag { NSItemProvider(object: result.url as NSURL) }
                .help("Drag this GIF into any app")

            HStack {
                Text("\(result.size.width)×\(result.size.height) · \(result.frames) frames")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text(formatBytes(result.bytes))
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
                Text(String(format: "in %.1fs", result.wallTime))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([result.url])
                } label: {
                    Label("Reveal in Finder", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SubtleButtonStyle())

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([result.url as NSURL])
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SubtleButtonStyle())
                .help("Copy the GIF file — paste into Slack, Messages, etc.")
            }
        }
        .padding(16)
        .frame(width: 312)
        .panel(cornerRadius: 16)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }
}
