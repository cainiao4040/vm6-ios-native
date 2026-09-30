import SwiftUI
import UIKit

/// Palette lifted from the Android resources so the iOS build looks like the
/// same product (`page_home.xml`, `card_dark.xml`, `btn_orange.xml`, …).
enum Theme {
    static let background = Color(hex: 0x1A1B1F)
    static let card = Color(hex: 0x26272B)
    static let cardBorder = Color(hex: 0x3A3B41)
    static let field = Color(hex: 0x1E1F23)
    static let fieldBorder = Color(hex: 0x4A4B52)
    static let divider = Color(hex: 0x34353B)

    static let accent = Color(hex: 0xE8821E)      // orange buttons / eyebrows
    static let primary = Color(hex: 0x1A5FB4)     // app primary blue
    static let primaryDark = Color(hex: 0x15509B)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0xB9BAC2)
    static let textMuted = Color(hex: 0x8A8B93)

    static let bleConnected = Color(hex: 0xFF9A9B)
    static let syncGreen = Color(hex: 0x8FE3B1)
    static let dotGreen = Color(hex: 0x34C759)
    static let dotGray = Color(hex: 0xB8BEC9)
    static let danger = Color(hex: 0xFF6B6B)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: 1.0)
    }
}

// MARK: - Reusable pieces

/// Dark rounded card with the same radius/border as `card_dark.xml`.
/// `content` is built eagerly by an explicit `@ViewBuilder` init so the type
/// does not depend on result-builder propagation to a stored property.
struct Card<Content: View>: View {
    var padding: CGFloat
    let content: Content

    init(padding: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
    }
}

/// The small orange section headings ("实时数据", "执行抄表", …).
struct SectionEyebrow: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .bold))
            .foregroundColor(Theme.accent)
            .padding(.top, 6)
    }
}

/// Primary action button styled after `btn_orange.xml`.
struct AccentButton: View {
    let title: String
    var systemImage: String?
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage = systemImage {
                    Image(systemName: systemImage)
                }
                Text(title).font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundColor(.white)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(enabled ? Theme.accent : Theme.accent.opacity(0.4))
            )
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage = systemImage { Image(systemName: systemImage) }
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundColor(Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.fieldBorder, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Label/value row used inside the live-data and snapshot cards.
struct KeyValueRow: View {
    let label: String
    let value: String
    var unit: String = ""
    var valueColor: Color = Theme.textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 20, weight: .bold))
                .foregroundColor(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textMuted)
            }
        }
    }
}

struct StatusDot: View {
    let connected: Bool
    var body: some View {
        Circle()
            .fill(connected ? Theme.dotGreen : Theme.dotGray)
            .frame(width: 12, height: 12)
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(height: 1)
            .padding(.vertical, 10)
    }
}

struct EmptyStateCard: View {
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundColor(Theme.textMuted)
            Text(message)
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }
}

/// Dark text field matching `edit_dark.xml`.
struct DarkTextField: View {
    let placeholder: String
    @Binding var text: String
    var keyboard: UIKeyboardType = .default

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundColor(Theme.textMuted))
            .keyboardType(keyboard)
            .foregroundColor(Theme.textPrimary)
            .font(.system(size: 15))
            .padding(.horizontal, 12)
            .frame(minHeight: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.field)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.fieldBorder, lineWidth: 1)
            )
            .autocapitalization(.none)
            .disableAutocorrection(true)
    }
}

/// Transient message banner (stand-in for Android `Toast`).
struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.cardBorder, lineWidth: 1)
            )
            .padding(.horizontal, 20)
            .shadow(radius: 8)
    }
}
