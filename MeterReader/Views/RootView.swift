import SwiftUI
import UIKit

/// Splash → three-tab shell (主页 / 历史 / 设置), mirroring the Flutter app's
/// splash_screen + app_shell and the Android bottom nav.
struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var selectedTab = 0

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if store.showSplash {
                SplashView()
                    .transition(.opacity)
            } else {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem { Label("主页", systemImage: "house.fill") }
                        .tag(0)

                    HistoryView()
                        .tabItem { Label("历史", systemImage: "clock.fill") }
                        .tag(1)

                    SettingsView()
                        .tabItem { Label("设置", systemImage: "gearshape.fill") }
                        .tag(2)
                }
                .accentColor(Theme.accent)
                .onAppear(perform: styleTabBar)
            }

            // Toast overlay
            if let toast = store.toast {
                VStack {
                    Spacer()
                    ToastView(text: toast)
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
                .animation(.easeInOut(duration: 0.2), value: toast)
            }
        }
        .onAppear {
            guard store.showSplash else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.35)) { store.showSplash = false }
            }
        }
    }

    private func styleTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(Theme.card)
        appearance.shadowColor = UIColor(Theme.cardBorder)
        UITabBar.appearance().standardAppearance = appearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = appearance
        }
    }
}

/// Mirrors the Flutter `splash_screen.dart` — app name, icon, version.
struct SplashView: View {
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Theme.primary)
                    .frame(width: 96, height: 96)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(.white)
            }
            .scaleEffect(pulse ? 1.04 : 0.96)

            Text("流量计抄表")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(Theme.textPrimary)

            Text("VM6 蓝牙抄表助手")
                .font(.system(size: 14))
                .foregroundColor(Theme.textSecondary)

            ProgressView()
                .progressViewStyle(.circular)
                .tint(Theme.accent)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background.ignoresSafeArea())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
