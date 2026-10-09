import SwiftUI

/// Filmstrip timeline with draggable trim handles and playhead.
struct TimelineView: View {
    @EnvironmentObject var model: AppModel

    private let handleWidth: CGFloat = 12
    private let stripHeight: CGFloat = 52

    var body: some View {
        VStack(spacing: 10) {
            transportBar
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    filmstrip(width: w)
                    trimOverlay(width: w)
                    playhead(width: w)
                }
                .coordinateSpace(name: "strip")
                .contentShape(Rectangle())
                .gesture(scrubGesture(width: w))
            }
            .frame(height: stripHeight)
        }
        .disabled(model.isExporting || model.isLoading)
    }

    // MARK: transport

    private var transportBar: some View {
        HStack(spacing: 14) {
            Text(formatTime(model.currentTime))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 70, alignment: .leading)

            Spacer()

            HStack(spacing: 8) {
                if model.settings.format == .webm {
                    Button {
                        model.isPreviewMuted.toggle()
                    } label: {
                        Image(systemName: model.isPreviewMuted ? "speaker.slash" : "speaker.wave.2")
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.settings.includeAudio)
                    .help(model.isPreviewMuted ? "Unmute preview" : "Mute preview")
                }
                transportButton("previous") { model.stepFrame(-1) }
                Button {
                    model.togglePlayback()
                } label: {
                    HugeIcon(name: model.isPlaying ? "pause" : "play", size: 17)
                        .foregroundStyle(.black)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white))
                }
                .buttonStyle(.plain)
                .help("Play / Pause (Space)")
                transportButton("next") { model.stepFrame(1) }
            }

            Spacer()

            HStack(spacing: 8) {
                trimBadge(label: "IN", time: model.trimStart, key: "I") { model.setTrimIn() }
                trimBadge(label: "OUT", time: model.trimEnd, key: "O") { model.setTrimOut() }
                Text(String(format: "%.2fs selected", model.clipDuration))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func transportButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HugeIcon(name: icon, size: 14)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func trimBadge(label: String, time: Double, key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(formatTime(time))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.07)))
        }
        .buttonStyle(.plain)
        .help("Set \(label.lowercased()) point at playhead (\(key))")
    }

    // MARK: strip layers

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if model.thumbnails.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.05))
            } else {
                ForEach(Array(model.thumbnails.enumerated()), id: \.offset) { _, cg in
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(max(1, model.thumbnails.count)), height: stripHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: stripHeight)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trimOverlay(width: CGFloat) -> some View {
        let x0 = xFor(model.trimStart, width: width)
        let x1 = xFor(model.trimEnd, width: width)
        return ZStack(alignment: .leading) {
            // Dim the excluded ranges.
            Rectangle().fill(.black.opacity(0.65))
                .frame(width: max(0, x0))
            Rectangle().fill(.black.opacity(0.65))
                .frame(width: max(0, width - x1))
                .offset(x: x1)
            // Selection border.
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Theme.accent, lineWidth: 2)
                .frame(width: max(handleWidth * 2, x1 - x0))
                .offset(x: x0)
            // Handles.
            trimHandle(atX: x0 - handleWidth / 2, leading: true, width: width)
            trimHandle(atX: x1 - handleWidth / 2, leading: false, width: width)
        }
        // alignment .leading is load-bearing: a plain .frame would center the
        // composite when its natural width is below `width`, shifting every child.
        .frame(width: width, height: stripHeight, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func trimHandle(atX x: CGFloat, leading: Bool, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Theme.accent)
            .frame(width: handleWidth, height: stripHeight)
            .overlay(
                RoundedRectangle(cornerRadius: 1)
                    .fill(.black.opacity(0.5))
                    .frame(width: 2, height: 22)
            )
            .offset(x: x)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("strip"))
                    .onChanged { v in
                        model.beginSettingsAdjustment()
                        let t = timeFor(v.location.x, width: width)
                        if leading {
                            model.trimStart = min(max(0, t), model.trimEnd - 0.05)
                            model.seek(to: model.trimStart)
                        } else {
                            model.trimEnd = max(min(model.duration, t), model.trimStart + 0.05)
                            model.seek(to: model.trimEnd)
                        }
                    }
                    .onEnded { _ in model.endSettingsAdjustment() }
            )
    }

    private func playhead(width: CGFloat) -> some View {
        let x = xFor(model.currentTime, width: width)
        return VStack(spacing: 0) {
            Circle()
                .fill(.white)
                .frame(width: 9, height: 9)
            Rectangle()
                .fill(.white)
                .frame(width: 2)
        }
        .frame(height: stripHeight)
        .offset(x: x - 1)
        .shadow(color: .black.opacity(0.6), radius: 2)
        .allowsHitTesting(false)
    }

    // MARK: gestures & mapping

    private func scrubGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                model.scrub(to: timeFor(v.location.x, width: width))
            }
    }

    private func xFor(_ time: Double, width: CGFloat) -> CGFloat {
        guard model.duration > 0 else { return 0 }
        return CGFloat(time / model.duration) * width
    }

    private func timeFor(_ x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(0, Double(x / width)), 1) * model.duration
    }
}
