import SwiftUI

enum Theme {
    static let yellow = Color(red: 1, green: 0xE1 / 255, blue: 0x4A / 255)
    static let paleYellow = Color(red: 1, green: 0xF8 / 255, blue: 0xD6 / 255)
    static let languagePill = Color(white: 0xEB / 255)
    static let ink = Color(white: 0x20 / 255)
    static let muted = Color(white: 0x70 / 255)
    static let placeholder = Color(red: 0xF1 / 255, green: 0xEF / 255, blue: 0xE9 / 255)

    /// Font sizes follow the Flutter breakpoints: < 600 phone, < 900 compact tablet.
    static func title(_ width: CGFloat) -> CGFloat { width < 600 ? 34 : width < 900 ? 46 : 64 }
    static func action(_ width: CGFloat) -> CGFloat { width < 600 ? 24 : width < 900 ? 34 : 48 }
    static func body(_ width: CGFloat) -> CGFloat { width < 600 ? 21 : width < 900 ? 27 : 34 }
}

/// Large circular yellow action used for record / like / next.
struct RoundAction: View {
    let label: String
    let systemImage: String
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 44))
                Text(label).font(.system(size: 22, weight: .semibold)).multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.ink)
            .frame(width: 154, height: 154)
            .background(Theme.yellow, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct PillButton: View {
    let label: String
    var disabled = false
    let action: () async -> Void

    var body: some View {
        Button {
            Task { await action() }
        } label: {
            Text(label)
                .font(.system(size: 25, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 36)
                .frame(minWidth: 260, minHeight: 70)
                .background(Theme.yellow, in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }
}

/// Image fitted on a blurred copy of itself, 8:5 with rounded corners.
struct MemoryImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 31

    var body: some View {
        ZStack {
            Theme.placeholder
            if let url, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill().blur(radius: 18).clipped()
                Color.black.opacity(0.13)
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: url == nil ? "photo" : "exclamationmark.triangle")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.muted)
            }
        }
        .aspectRatio(8 / 5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }
}
