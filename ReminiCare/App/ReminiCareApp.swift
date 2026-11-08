import ReminiCareKit
import SwiftUI

enum Route: Hashable {
    case life, history, ttsCache
}

@main
struct ReminiCareApp: App {
    init() {
        AppLog.shared.record(.app, .started)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.light)
                .tint(Theme.ink)
        }
    }
}

struct RootView: View {
    @State private var path: [Route] = []
    @State private var showLog = false

    var body: some View {
        NavigationStack(path: $path) {
            HomeView(path: $path)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .life: LifeView(onDone: { path.removeAll() })
                    case .history: HistoryView()
                    case .ttsCache: TtsCacheView()
                    }
                }
        }
        // A cover keeps the conversation underneath alive, unlike a pushed page.
        .fullScreenCover(isPresented: $showLog) {
            NavigationStack { AppLogView() }
        }
        .environment(\.showLog, { showLog = true })
    }
}

// Written out instead of `@Entry`: that macro ships only with Xcode, and the
// app is also built with xtool on Linux.
private struct ShowLogKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var showLog: @MainActor @Sendable () -> Void {
        get { self[ShowLogKey.self] }
        set { self[ShowLogKey.self] = newValue }
    }
}

/// Adds the App Log entry to a screen's toolbar.
struct LogToolbar: ViewModifier {
    @Environment(\.showLog) private var showLog
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Log", action: showLog)
                    .font(.system(size: 18))
                    .accessibilityLabel("執行紀錄")
            }
        }
    }
}

extension View {
    func logToolbar() -> some View { modifier(LogToolbar()) }
}
