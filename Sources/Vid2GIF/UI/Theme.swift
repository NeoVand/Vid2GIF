import SwiftUI

/// Dark, cloudy, desaturated palette — slate grays with a muted steel accent.
enum Theme {
    static let bg = Color(red: 0.039, green: 0.047, blue: 0.063)          // #0A0C10
    static let panel = Color(red: 0.071, green: 0.082, blue: 0.106)       // #12151B
    static let panelBorder = Color.white.opacity(0.06)

    /// Muted steel blue — the single accent used everywhere.
    static let accent = Color(red: 0.55, green: 0.62, blue: 0.72)         // #8C9EB8
    /// Fill for selected chips/segments.
    static let selection = Color(red: 0.184, green: 0.212, blue: 0.259)   // #2F3642
    /// Slightly lifted surface for control tracks.
    static let track = Color.white.opacity(0.08)

    static let textPrimary = Color(red: 0.88, green: 0.90, blue: 0.93)
    static let textSecondary = Color.white.opacity(0.52)
    static let textTertiary = Color.white.opacity(0.30)

    /// Subtle slate gradient for the primary action.
    static let accentGradient = LinearGradient(
        colors: [
            Color(red: 0.29, green: 0.34, blue: 0.42),                    // #4A5769
            Color(red: 0.18, green: 0.21, blue: 0.26),                    // #2E3542
        ],
        startPoint: .top, endPoint: .bottom
    )
}

struct PanelBackground: ViewModifier {
    var cornerRadius: CGFloat = 14
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(Theme.panelBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    func panel(cornerRadius: CGFloat = 14) -> some View {
        modifier(PanelBackground(cornerRadius: cornerRadius))
    }
}

/// Primary action button: soft slate gradient with a hairline highlight.
struct GradientButtonStyle: ButtonStyle {
    var disabled = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.accentGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .opacity(disabled ? 0.35 : (configuration.isPressed ? 0.75 : 1))
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SubtleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.16 : 0.08))
            )
    }
}

/// App-styled segmented control — replaces the system picker so every control
/// shares the same muted palette.
struct SegmentedControl<T: Hashable>: View {
    let options: [(label: String, value: T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selected ? Theme.selection : .clear)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }
}
