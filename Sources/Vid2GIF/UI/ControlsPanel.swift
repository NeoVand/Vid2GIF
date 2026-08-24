import SwiftUI

/// Right-hand sidebar: output configuration + live summary + export.
struct ControlsPanel: View {
    @EnvironmentObject var model: AppModel

    private let widthPresets = [320, 480, 640, 800, 960, 1280]
    private let fpsPresets: [Double] = [10, 12, 15, 20, 24, 30]
    private let colorPresets = [64, 128, 255]

    var body: some View {
        VStack(spacing: 14) {
            ScrollView {
                VStack(spacing: 14) {
                    outputSection
                    qualitySection
                    summarySection
                }
            }
            .scrollIndicators(.never)

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
        VStack(spacing: 12) {
            sectionHeader("Output")

            labeledRow("Width") {
                Picker("", selection: $model.settings.outputWidth) {
                    ForEach(availableWidths, id: \.self) { w in
                        Text(w == sourceWidth ? "\(w) px (source)" : "\(w) px").tag(w)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            labeledRow("Frame rate") {
                Picker("", selection: $model.settings.fps) {
                    ForEach(availableFPS, id: \.self) { f in
                        Text("\(Int(f)) fps").tag(f)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }

            VStack(spacing: 6) {
                labeledRow("Speed") {
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
        .padding(14)
        .panel()
    }

    private var qualitySection: some View {
        VStack(spacing: 12) {
            sectionHeader("Quality")

            labeledRow("Colors") {
                SegmentedControl(
                    options: colorPresets.map { (label: $0 == 255 ? "256" : "\($0)", value: $0) },
                    selection: $model.settings.maxColors
                )
            }

            VStack(alignment: .leading, spacing: 6) {
                labeledRow("Dithering") {
                    SegmentedControl(
                        options: DitherMode.allCases.map { (label: $0.rawValue, value: $0) },
                        selection: $model.settings.dither
                    )
                }
                Text(model.settings.dither.help)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle(isOn: $model.settings.loopForever) {
                toggleLabel("Loop forever", detail: "Repeat endlessly")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.accent)

            Toggle(isOn: $model.settings.useDelta) {
                toggleLabel("Optimize static areas", detail: "Encode only changed pixels — much smaller files")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Theme.accent)
        }
        .padding(14)
        .panel()
    }

    private var summarySection: some View {
        VStack(spacing: 8) {
            sectionHeader("Result")
            summaryRow("Dimensions", "\(model.outputPixelSize.width) × \(model.outputPixelSize.height)")
            summaryRow("Duration", String(format: "%.2fs", model.outputDuration))
            if let result = model.previewResult, model.previewMode == .gif, !model.isGeneratingPreview {
                summaryRow("Frames", "\(result.frames)")
                summaryRow("File size", formatBytes(result.bytes))
            } else {
                summaryRow("Frames", "\(Int((model.outputDuration * model.settings.fps).rounded()))")
                summaryRow("Est. size", "~" + formatBytes(model.estimatedBytes))
            }
        }
        .padding(14)
        .panel()
    }

    private var exportArea: some View {
        Button {
            model.startExport()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text("Export GIF")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(GradientButtonStyle(disabled: model.isExporting || !model.hasVideo))
        .disabled(model.isExporting || !model.hasVideo)
        .keyboardShortcut("e", modifiers: .command)
        .help("Export GIF (⌘E)")
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

    private func labeledRow(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            content()
        }
    }

    private func toggleLabel(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
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
