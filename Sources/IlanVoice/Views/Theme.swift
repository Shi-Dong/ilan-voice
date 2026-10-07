import SwiftUI

/// Colours lifted from the Ilan icon: its mint background and orange lanyard,
/// set on a deep green-black.
enum Theme {
    static let mint = Color(red: 0.663, green: 0.863, blue: 0.796)       // #A9DCCB
    static let mintDeep = Color(red: 0.302, green: 0.659, blue: 0.561)   // #4DA88F
    static let orange = Color(red: 0.949, green: 0.549, blue: 0.165)     // #F28C2A
    static let ink = Color(red: 0.055, green: 0.071, blue: 0.075)        // #0E1213
    static let inkRaised = Color(red: 0.086, green: 0.114, blue: 0.110)  // #161D1C
    static let card = Color.white.opacity(0.055)
    static let hairline = Color.white.opacity(0.08)
    static let textDim = Color.white.opacity(0.55)

    static let background = LinearGradient(
        colors: [Color(red: 0.067, green: 0.098, blue: 0.094), ink],
        startPoint: .top, endPoint: .bottom)

    static func color(for phase: VoiceSession.Phase) -> Color {
        switch phase {
        case .offline: .gray
        case .connecting: .yellow
        case .ready: mint
        case .recording: Color(red: 1, green: 0.42, blue: 0.42)
        case .thinking, .working: Color(red: 0.69, green: 0.84, blue: 1)
        case .speaking: orange
        }
    }
}

struct AppIcon: View {
    var size: CGFloat
    var body: some View {
        Image(nsImage: NSApplication.shared.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).stroke(Theme.hairline))
    }
}

func formatDuration(_ seconds: Double?) -> String {
    guard let s = seconds else { return "" }
    let total = Int(s.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// View-local state. Stands in for `@State`, whose macro plugin ships with
/// Xcode but not with the Command Line Tools this project builds with.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    final class Box: ObservableObject {
        @Published var value: Value
        init(_ value: Value) { self.value = value }
    }

    @StateObject private var box: Box

    init(wrappedValue: Value) {
        _box = StateObject(wrappedValue: Box(wrappedValue))
    }

    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }

    var projectedValue: Binding<Value> { $box.value }
}
