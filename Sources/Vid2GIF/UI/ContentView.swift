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
        .sheet(isPresented: $model.isInspectingOutput) { EncodedOutputInspector() }
        .preferredColorScheme(.dark)
    }

    // MARK: editor layout

    private var editor: some View {
        HStack(spacing: 14) {
            VStack(spacing: 12) {
                topBar
                preview
                TimelineView()
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
        HStack(spacing: 10) {
            Button {
                showAbout = true
            } label: {
                HStack(spacing: 7) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 22, height: 22)
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
                    .truncationMode(.middle)
                Text("\(Int(model.sourceSize.width))×\(Int(model.sourceSize.height)) · \(Int(model.sourceFPS.rounded())) fps · \(formatTime(model.duration))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .layoutPriority(-1)
            }

            Spacer(minLength: 16)

            previewModeToggle

            Button("Open…") { model.presentOpenPanel() }
                .disabled(model.isExporting)
                .buttonStyle(SubtleButtonStyle())
                .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.top, 14) // clear the traffic lights with transparent titlebar
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.black)

            if model.previewMode == .output, model.settings.format == .gif {
                outputPreview
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
                        HugeIcon(name: "play", size: 28)
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    )
                    .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlayback() }
        .overlay(alignment: .bottomTrailing) {
            if model.isLiveVideoPreview {
                Text("Live preview")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(8)
                    .background(Capsule().fill(.black.opacity(0.6)))
                    .padding(12)
            }
        }
    }

    /// The real output: an actual encoded file in the selected format.
    private var outputPreview: some View {
        ZStack {
            if let url = model.previewURL {
                AnimatedGIFView(url: url)
                    .padding(10)
                    .id(url) // force refresh when a new preview lands
            } else if let error = model.previewError {
                VStack(spacing: 12) {
                    Text("Preview unavailable")
                        .font(.system(size: 14, weight: .semibold))
                    Text(error)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.textSecondary)
                    Button("Retry") { model.schedulePreviewRefresh(immediate: true) }
                        .buttonStyle(SubtleButtonStyle())
                }
                .padding(30)
            } else {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Rendering \(model.settings.format.title) preview…")
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
                    Text(model.previewIsCurrent ? formatBytes(result.bytes) : (model.previewError == nil ? "Updating…" : "Update failed"))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .help(model.previewError ?? "Exact GIF preview")
                    if model.previewError != nil {
                        Button("Retry") { model.schedulePreviewRefresh(immediate: true) }
                            .buttonStyle(SubtleButtonStyle())
                    }
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
            modeButton(model.settings.format == .webm ? "Preview" : "GIF", mode: .output)
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
        guard !model.isExporting, let provider = providers.first else { return false }
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
            guard model.hasVideo, !model.isExporting, !model.isInspectingOutput else { return event }

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

            Text("Blazingly fast, hardware-accelerated\nvideo → GIF and WebM conversion for macOS.")
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
                    HugeIcon(name: "github", size: 15)
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
                HugeIcon(name: "video", size: 44)
                    .foregroundStyle(Theme.accent)
            }

            VStack(spacing: 8) {
                Text("Drop a video to begin")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Trim, tune, and export as GIF or WebM video.\nSet the size, frame rate, speed, and quality in one place.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Button {
                model.presentOpenPanel()
            } label: {
                HStack(spacing: 8) {
                    HugeIcon(name: "folder-open", size: 15)
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
                    HugeIcon(name: "checkmark-circle", size: 15)
                        .foregroundStyle(Theme.accent)
                    Text("\(result.format.title) Exported")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Spacer()
                Button {
                    model.exportResult = nil
                } label: {
                    HugeIcon(name: "cancel", size: 10)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            ExportPreviewView(url: result.url, format: result.format)
                .frame(width: 280, height: 175)
                .background(RoundedRectangle(cornerRadius: 8).fill(.black))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onDrag { NSItemProvider(object: result.url as NSURL) }
                .help("Drag this file into another app")

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
                    HStack(spacing: 6) {
                        HugeIcon(name: "search", size: 13)
                        Text("Reveal in Finder")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SubtleButtonStyle())

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects([result.url as NSURL])
                } label: {
                    HStack(spacing: 6) {
                        HugeIcon(name: "copy", size: 13)
                        Text("Copy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(SubtleButtonStyle())
                .help("Copy the exported file — paste into another app.")
            }
        }
        .padding(16)
        .frame(width: 312)
        .panel(cornerRadius: 16)
        .shadow(color: .black.opacity(0.5), radius: 24, y: 8)
    }
}
