import SwiftUI

/// Right-hand sidebar: output configuration + live summary + export.
/// A plain VStack sized to the window — the Result panel stretches to absorb
/// leftover height so the column always packs the full window.
struct ControlsPanel: View {
    @EnvironmentObject var model: AppModel

    private let widthPresets = [320, 480, 640, 800, 960, 1280]
    private let fpsPresets: [Double] = [10, 12, 15, 20, 24, 30]
    private let colorPresets = [64, 128, 255]

    var body: some View {
        VStack(spacing: 14) {
            outputSection
            if model.settings.format == .gif {
                qualitySection
            } else {
                videoQualitySection
            }
            summarySection
                .frame(maxHeight: .infinity, alignment: .top)
            exportArea
        }
    }

    // MARK: sections

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var outputSection: some View {
        VStack(spacing: 16) {
            sectionHeader("Output")

            labeledRow("Format", icon: "video") {
                SegmentedControl(
                    options: ExportFormat.allCases.map { (label: $0.title, value: $0) },
                    selection: $model.settings.format
                )
            }

            labeledRow("Width", icon: "ruler") {
                Picker("Width", selection: $model.settings.outputWidth) {
                    ForEach(availableWidths, id: \.self) { w in
                        Text(w == sourceWidth ? "\(w) px (source)" : "\(w) px").tag(w)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            labeledRow("Frame rate", icon: "clock") {
                Picker("Frame rate", selection: $model.settings.fps) {
                    ForEach(availableFPS, id: \.self) { f in
                        Text("\(Int(f)) fps").tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            VStack(spacing: 10) {
                labeledRow("Speed", icon: "speed") {
                    Text(String(format: "%.2g×", model.settings.speed))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textPrimary)
                }
                SpeedSlider(speed: $model.settings.speed)
                    .onChange(of: model.settings.speed) { _, newValue in
                        if model.isPlaying { model.player?.rate = Float(newValue) }
                    }
            }
        }
        .padding(16)
        .panel()
    }

    private var qualitySection: some View {
        VStack(spacing: 16) {
            sectionHeader("Quality")

            labeledRow("Colors", icon: "palette") {
                SegmentedControl(
                    options: colorPresets.map { (label: $0 == 255 ? "256" : "\($0)", value: $0) },
                    selection: $model.settings.maxColors
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                rowLabel("Dithering", icon: "blur")
                    .frame(maxWidth: .infinity, alignment: .leading)
                SegmentedControl(
                    options: DitherMode.allCases.map { (label: $0.rawValue, value: $0) },
                    selection: $model.settings.dither,
                    fillWidth: true
                )
                Text(model.settings.dither.help)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            toggleRow(
                icon: "repeat", title: "Loop forever", detail: "Repeat endlessly",
                isOn: $model.settings.loopForever
            )

            toggleRow(
                icon: "layers", title: "Optimize static areas",
                detail: "Encode only changed pixels — much smaller files",
                isOn: $model.settings.useDelta
            )
        }
        .padding(16)
        .panel()
    }

    private var summarySection: some View {
        VStack(spacing: 14) {
            sectionHeader("Result")
            summaryRow("Dimensions", icon: "aspect-ratio",
                       "\(model.outputPixelSize.width) × \(model.outputPixelSize.height)")
            summaryRow("Duration", icon: "timer", String(format: "%.2fs", model.outputDuration))
            if let result = model.previewResult, model.previewMode == .output, !model.isGeneratingPreview {
                summaryRow("Frames", icon: "film", "\(result.frames)")
                summaryRow("File size", icon: "hard-drive", formatBytes(result.bytes))
            } else {
                summaryRow("Frames", icon: "film",
                           "\(Int((model.outputDuration * model.settings.fps).rounded()))")
                if model.settings.format == .gif {
                    summaryRow("Est. size", icon: "hard-drive", "~" + formatBytes(model.estimatedBytes))
                } else {
                    summaryRow("File size", icon: "hard-drive", "After encoding")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .panel()
    }

    private var exportArea: some View {
        Button {
            model.startExport()
        } label: {
            HStack(spacing: 8) {
                HugeIcon(name: "sparkles", size: 15)
                Text("Export \(model.settings.format.title)")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(GradientButtonStyle(disabled: model.isExporting || !model.hasVideo || model.isLoading, height: 52))
        .disabled(model.isExporting || !model.hasVideo || model.isLoading)
        .keyboardShortcut("e", modifiers: .command)
        .help("Export \(model.settings.format.title) (⌘E)")
    }

    private var videoQualitySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Quality")
            SegmentedControl(
                options: VideoQuality.allCases.map { (label: $0.title, value: $0) },
                selection: $model.settings.videoQuality,
                fillWidth: true
            )
            Text(model.settings.videoQuality.help)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            toggleRow(icon: "video", title: "Include audio",
                      detail: "Keep source audio, matched to playback speed",
                      isOn: $model.settings.includeAudio)
            Text("WebM keeps full color. Looping is controlled by the app or website playing your video.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .panel()
    }

    // MARK: helpers

    private var sourceWidth: Int {
        Int(model.sourceSize.width)
    }

    private var availableWidths: [Int] {
        var ws = widthPresets.filter { $0 < sourceWidth }
        if sourceWidth > 0 { ws.append(sourceWidth) }
        if !ws.contains(model.settings.outputWidth) {
            ws.append(model.settings.outputWidth)
            ws.sort()
        }
        return ws
    }

    private var availableFPS: [Double] {
        var fs = fpsPresets
        if !fs.contains(model.settings.fps) {
            fs.append(model.settings.fps)
            fs.sort()
        }
        return fs
    }

    private func rowLabel(_ label: String, icon: String) -> some View {
        HStack(spacing: 9) {
            HugeIcon(name: icon, size: 15)
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func labeledRow(
        _ label: String, icon: String, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack {
            rowLabel(label, icon: icon)
            Spacer()
            content()
        }
    }

    private func toggleRow(
        icon: String, title: String, detail: String, isOn: Binding<Bool>
    ) -> some View {
        HStack(alignment: .center, spacing: 9) {
            HugeIcon(name: icon, size: 15)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }

    private func summaryRow(_ label: String, icon: String, _ value: String) -> some View {
        HStack {
            rowLabel(label, icon: icon)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// Log-scale speed slider: 0.25× … 4×, detented at 1×. Custom DragGesture
/// implementation — the stock Slider loses drags to window-move on macOS 26.
struct SpeedSlider: View {
    @Binding var speed: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            let frac = (log2(speed) + 2) / 4
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12))
                    .frame(height: 4)
                Capsule().fill(Theme.accent)
                    .frame(width: max(4, frac * w), height: 4)
                // 1× detent mark
                Rectangle().fill(Color.white.opacity(0.35))
                    .frame(width: 1.5, height: 8)
                    .offset(x: w / 2 - 0.75)
                Circle().fill(.white)
                    .frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .offset(x: frac * w - 7)
            }
            .frame(width: w, height: 18, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let f = min(max(0, v.location.x / w), 1)
                        var s = pow(2, f * 4 - 2)
                        if abs(s - 1) < 0.08 { s = 1 } // snap to 1×
                        speed = (s * 100).rounded() / 100
                    }
            )
        }
        .frame(height: 18)
    }
}
