import AppKit
import Combine
import SwiftUI

struct ContentView<DataSource: ContentViewDataSource>: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var dataSource: DataSource
    private let runsLifecycleTasks: Bool
    private let quickLoginLabel: String
    private let quickLoginInProgressOverride: Bool?
    @State private var presentedCardError: CardErrorPresentation?
    
    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
    ]
    
    init(
        dataSource: DataSource,
        runsLifecycleTasks: Bool = true,
        quickLoginLabel: String = "Quick Login",
        quickLoginInProgressOverride: Bool? = nil
    ) {
        self.dataSource = dataSource
        self.runsLifecycleTasks = runsLifecycleTasks
        self.quickLoginLabel = quickLoginLabel
        self.quickLoginInProgressOverride = quickLoginInProgressOverride
    }
    
    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 12) {
                header
                if shouldShowLoginStatusPanel {
                    loginStatusPanel
                }
                Divider()
                if dataSource.accounts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(dataSource.accounts, id: \.id) { account in
                                AccountCardView(
                                    account: account,
                                    snapshot: dataSource.snapshotsByAccountID[account.id],
                                    isLocalAccount: dataSource.isLocalCodexAccount(account),
                                    isSwitchingToLocal: dataSource.isSwitchingLocalCodexAccount(account),
                                    selectedStyle: .pro,
                                    onShowError: { account, errorText in
                                        presentedCardError = CardErrorPresentation(
                                            accountID: account.id,
                                            accountName: account.displayName,
                                            message: errorText
                                        )
                                    },
                                    onSwitchToLocal: {
                                        Task { await dataSource.switchLocalCodexAccount(to: account) }
                                    }
                                )
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                }
                Divider()
                footer
            }
            
            if let activeCardError = presentedCardError {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        self.presentedCardError = nil
                    }
                
                CardErrorSheet(error: activeCardError) {
                    self.presentedCardError = nil
                } onLogin: {
                    self.presentedCardError = nil
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(180))
                        await dataSource.beginCodexLogin()
                    }
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .padding(12)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.easeOut(duration: 0.18), value: presentedCardError)
        .task {
            guard runsLifecycleTasks else { return }
            dataSource.panelDidOpen()
        }
        .onReceive(dataSource.objectWillChange) { _ in
            synchronizePresentedError()
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("QuotaBar")
                        .font(.title2.weight(.semibold))
                }
                Spacer()
                
                HStack(spacing: 8) {
                    quickLoginButton(style: .borderedProminent)
                    
                    Button {
                        Task { await dataSource.refreshAll(reason: "manual") }
                    } label: {
                        if dataSource.isRefreshingAll {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }
    
    private var footer: some View {
        HStack {
            Button {
                showSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            Spacer()
            Button("Quit") {
                quitApplication()
            }
        }
    }
    
    private func showSettingsWindow() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
        
        DispatchQueue.main.async {
            let targetWindow = NSApp.windows.first {
                $0.identifier?.rawValue == "settings" || $0.title == "QuotaBar Settings"
            }
            targetWindow?.makeKeyAndOrderFront(nil)
            targetWindow?.orderFrontRegardless()
        }
    }
    
    private func quitApplication() {
        for window in NSApp.windows {
            window.close()
        }
        NSApp.terminate(nil)
    }
    
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No Codex accounts")
                    .font(.headline)
                Text(
                    "Add accounts in Settings. QuotaBar stores each account's auth separately and reads usage without touching the default `~/.codex`."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            
            quickLoginButton(style: .borderedProminent)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(panelBorder)
        }
    }
    
    private enum QuickLoginButtonStyle {
        case bordered
        case borderedProminent
    }
    
    @ViewBuilder
    private func quickLoginButton(style: QuickLoginButtonStyle) -> some View {
        if style == .borderedProminent {
            Button(action: handleQuickLoginButtonTap) {
                quickLoginButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .disabled(isQuickLoginInProgress)
        } else {
            Button(action: handleQuickLoginButtonTap) {
                quickLoginButtonLabel
            }
            .buttonStyle(.bordered)
            .disabled(isQuickLoginInProgress)
        }
    }
    
    @ViewBuilder
    private var quickLoginButtonLabel: some View {
        if isQuickLoginInProgress {
            ProgressView()
                .controlSize(.small)
                .frame(minWidth: 18)
        } else if dataSource.loginHasStarted {
            Label("I've Finished Login", systemImage: "checkmark.circle")
        } else {
            Label(quickLoginLabel, systemImage: "person.crop.circle.badge.plus")
        }
    }
    
    private var isQuickLoginInProgress: Bool {
        quickLoginInProgressOverride ?? dataSource.isStartingLogin || dataSource.isFinishingLogin
    }
    
    private var shouldShowLoginStatusPanel: Bool {
        dataSource.loginHasStarted || dataSource.addAccountErrorMessage != nil
    }
    
    private var loginStatusPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dataSource.loginHasStarted {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "safari")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.blue)
                        .frame(width: 24, height: 24)
                        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Login in progress")
                            .font(.subheadline.weight(.semibold))
                        Text("Finish the browser flow, then click \"I've Finished Login\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 8) {
                        if dataSource.activeLoginURL != nil {
                            Button("Open Again") {
                                dataSource.reopenLoginURL()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        
                        Button("Cancel") {
                            dataSource.cancelCodexLogin()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
            
            if let error = dataSource.addAccountErrorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .background(panelBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(panelBorder)
        }
    }
    
    private func handleQuickLoginButtonTap() {
        if dataSource.loginHasStarted {
            finishQuickLogin()
        } else {
            startQuickLogin()
        }
    }
    
    private func startQuickLogin() {
        Task { @MainActor in
            await dataSource.beginCodexLogin()
        }
    }
    
    private func finishQuickLogin() {
        Task { @MainActor in
            _ = await dataSource.finishCodexLogin()
        }
    }
    
    private func synchronizePresentedError() {
        guard let presentedCardError else { return }
        guard
            let account = dataSource.accounts.first(where: { $0.id == presentedCardError.accountID }),
            let message = dataSource.snapshotsByAccountID[presentedCardError.accountID]?.lastError
        else {
            self.presentedCardError = nil
            return
        }
        
        let nextPresentation = CardErrorPresentation(
            accountID: account.id,
            accountName: account.displayName,
            message: message
        )
        if nextPresentation != presentedCardError {
            self.presentedCardError = nextPresentation
        }
    }
    
    private var panelBackground: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.thinMaterial)
        }
        
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.96),
                    Color(red: 0.95, green: 0.97, blue: 1.0).opacity(0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
    
    private var panelBorder: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.08)
    }
}

private struct CardErrorPresentation: Identifiable, Equatable {
    let accountID: UUID
    let accountName: String
    let message: String
    
    var id: UUID { accountID }
}

private struct CardErrorSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    let error: CardErrorPresentation
    let onClose: () -> Void
    let onLogin: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 32, height: 32)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sync Error")
                        .font(.headline)
                    Text(error.accountName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
            }
            
            Text(error.message)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            
            HStack(spacing: 10) {
                Spacer()
                Button {
                    onLogin()
                } label: {
                    Label("Login", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                
                Button("Close") {
                    onClose()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(18)
        .frame(width: 340)
        .background(sheetBackground, in: RoundedRectangle(cornerRadius: 22))
        .overlay {
            RoundedRectangle(cornerRadius: 22)
                .strokeBorder(sheetBorderColor)
        }
        .shadow(color: shadowColor, radius: 28, x: 0, y: 18)
    }
    
    private var sheetBackground: AnyShapeStyle {
        if colorScheme == .dark {
            return AnyShapeStyle(.ultraThinMaterial)
        }
        
        return AnyShapeStyle(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.98),
                    Color(red: 0.95, green: 0.96, blue: 0.99).opacity(0.98),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
    
    private var sheetBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10)
    }
    
    private var shadowColor: Color {
        colorScheme == .dark ? .black.opacity(0.22) : .black.opacity(0.12)
    }
}

private struct AccountCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    enum SelectedStyle: String, CaseIterable, Identifiable {
        case pro
        case iridescent
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .pro:
                return "Pro"
            case .iridescent:
                return "Iridescent"
            }
        }
    }
    
    let account: ProviderAccountRecord
    let snapshot: CodexUsageSnapshot?
    let isLocalAccount: Bool
    let isSwitchingToLocal: Bool
    let selectedStyle: SelectedStyle
    let onShowError: (ProviderAccountRecord, String) -> Void
    let onSwitchToLocal: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 4) {
                Text(account.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                statusBadge
                if hasError {
                    errorAffordance
                }
            }
            
            VStack(alignment: .leading, spacing: 10) {
                quotaBarRow(
                    title: "5h",
                    window: snapshot?.preferredRateLimit?.primary,
                    resetText: shortTimeString(snapshot?.preferredRateLimit?.primary?.resetsAt)
                )
                
                quotaBarRow(
                    title: "Week",
                    window: snapshot?.preferredRateLimit?.secondary,
                    resetText: shortDayString(snapshot?.preferredRateLimit?.secondary?.resetsAt)
                )
            }
            
            HStack(spacing: 6) {
                PlanTag(text: account.planType.capitalized)
                Spacer()
                if let expiresAt = account.subscriptionExpiresAt {
                    Text("Expires \(expiresAt.formatted(.dateTime.month(.abbreviated).day().year()))")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(subscriptionExpiryColor(expiresAt))
                }
                if isSwitchingToLocal {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .background {
            RoundedRectangle(cornerRadius: 16)
                .fill(cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderStyle)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: glowColor.opacity(isHovered ? 0.12 : 0.0), radius: isHovered ? 6 : 0, x: 0, y: 0)
        .shadow(
            color: glowColor.opacity(isHovered ? 0.06 : 0.0), radius: isHovered ? 10 : 0, x: 0, y: 0
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            guard !isLocalAccount && !isSwitchingToLocal else { return }
            onSwitchToLocal()
        }
    }
    
    @ViewBuilder
    private var errorAffordance: some View {
        if let errorText = snapshot?.lastError {
            Button {
                onShowError(account, errorText)
            } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(errorAccentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(errorAccentColor)
                    .overlay {
                        Capsule()
                            .strokeBorder(errorAccentColor.opacity(0.16))
                    }
            }
            .buttonStyle(.plain)
            .help("Show error details")
            .accessibilityLabel("Show error details")
        }
    }
    
    private func quotaBarRow(title: String, window: RateLimitWindowSnapshot?, resetText: String)
    -> some View
    {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                Text(remainingString(window))
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(resetText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            
            GeometryReader { proxy in
                let height = CGFloat(4)
                let width = proxy.size.width
                let progress = CGFloat(progressValue(window))
                let fillWidth = max(height * 1.4, width * progress)
                let tint = barColor(window)
                
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(trackBackground)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(trackBorderColor)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.78), tint.opacity(0.96)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(tint.opacity(0.35))
                        .frame(width: fillWidth)
                }
            }
            .frame(height: 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    @ViewBuilder
    private var statusBadge: some View {
        let style: (String, Color) =
        switch account.syncStatus {
        case .healthy:
            ("Healthy", .green)
        case .unauthorized:
            ("Auth", .orange)
        case .failed, .degraded:
            ("Error", .red)
        case .refreshing:
            ("Syncing", .blue)
        case .disabled:
            ("Off", .secondary)
        case .idle:
            ("Idle", .secondary)
        }
        
        Text(style.0)
            .font(.system(size: 8))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(style.1.opacity(0.14), in: Capsule())
            .foregroundStyle(style.1)
            .overlay {
                Capsule()
                    .strokeBorder(style.1.opacity(0.16))
            }
            .lineLimit(1)
    }
    
    private var cardBackground: LinearGradient {
        if isLocalAccount {
            switch selectedStyle {
            case .pro:
                if colorScheme == .light {
                    return LinearGradient(
                        colors: [
                            Color(red: 0.90, green: 0.96, blue: 1.0),
                            Color(red: 0.72, green: 0.87, blue: 0.98),
                            Color(red: 0.58, green: 0.79, blue: 0.95),
                            Color(red: 0.82, green: 0.91, blue: 0.98),
                        ],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.92, y: 1.0)
                    )
                }
                return LinearGradient(
                    colors: [
                        Color(red: 0.12, green: 0.14, blue: 0.19).opacity(0.98),
                        Color(red: 0.16, green: 0.20, blue: 0.28).opacity(0.96),
                        Color(red: 0.10, green: 0.24, blue: 0.36).opacity(0.92),
                        Color(red: 0.08, green: 0.11, blue: 0.17).opacity(0.98),
                    ],
                    startPoint: .topLeading,
                    endPoint: UnitPoint(x: 0.92, y: 1.0)
                )
            case .iridescent:
                if colorScheme == .light {
                    return LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.93, blue: 0.97),
                            Color(red: 0.94, green: 0.84, blue: 0.95),
                            Color(red: 0.82, green: 0.90, blue: 0.99),
                            Color(red: 0.90, green: 0.85, blue: 0.98),
                        ],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.92, y: 1.0)
                    )
                }
                return LinearGradient(
                    colors: [
                        Color(red: 0.09, green: 0.10, blue: 0.16).opacity(0.98),
                        Color(red: 0.35, green: 0.14, blue: 0.24).opacity(0.94),
                        Color(red: 0.52, green: 0.30, blue: 0.12).opacity(0.82),
                        Color(red: 0.11, green: 0.40, blue: 0.28).opacity(0.80),
                        Color(red: 0.10, green: 0.26, blue: 0.52).opacity(0.90),
                        Color(red: 0.24, green: 0.14, blue: 0.44).opacity(0.96),
                    ],
                    startPoint: .topLeading,
                    endPoint: UnitPoint(x: 0.92, y: 1.0)
                )
            }
        }
        
        if colorScheme == .light {
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.92),
                    Color(red: 0.95, green: 0.96, blue: 0.98).opacity(0.96),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        
        return LinearGradient(
            colors: [
                Color.white.opacity(0.055),
                Color.white.opacity(0.02),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var borderStyle: some ShapeStyle {
        if isLocalAccount {
            switch selectedStyle {
            case .pro:
                if colorScheme == .light {
                    return LinearGradient(
                        colors: [
                            Color.white.opacity(0.88),
                            Color(red: 0.36, green: 0.63, blue: 0.96).opacity(0.32),
                            Color(red: 0.56, green: 0.77, blue: 0.97).opacity(0.18),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                return LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color(red: 0.42, green: 0.74, blue: 1.0).opacity(0.22),
                        Color(red: 0.62, green: 0.82, blue: 1.0).opacity(0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .iridescent:
                if colorScheme == .light {
                    return LinearGradient(
                        colors: [
                            Color.white.opacity(0.90),
                            Color(red: 0.95, green: 0.54, blue: 0.66).opacity(0.28),
                            Color(red: 0.42, green: 0.66, blue: 0.98).opacity(0.24),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
                return LinearGradient(
                    colors: [
                        Color.white.opacity(0.18),
                        Color(red: 0.96, green: 0.46, blue: 0.54).opacity(0.22),
                        Color(red: 0.34, green: 0.60, blue: 0.98).opacity(0.18),
                        Color.white.opacity(0.10),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        
        if colorScheme == .light {
            return LinearGradient(
                colors: [
                    Color.black.opacity(isHovered ? 0.12 : 0.07),
                    Color.black.opacity(isHovered ? 0.05 : 0.03),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        
        return LinearGradient(
            colors: [
                Color.white.opacity(isHovered ? 0.18 : 0.075),
                Color.white.opacity(isHovered ? 0.08 : 0.04),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var glowColor: Color {
        if isLocalAccount {
            switch selectedStyle {
            case .pro:
                return colorScheme == .dark
                    ? Color(red: 0.42, green: 0.74, blue: 1.0)
                    : Color(red: 0.34, green: 0.60, blue: 0.94)
            case .iridescent:
                return colorScheme == .dark
                    ? Color(red: 0.74, green: 0.50, blue: 0.96)
                    : Color(red: 0.84, green: 0.52, blue: 0.86)
            }
        }
        return colorScheme == .dark ? Color.white.opacity(0.92) : Color.black.opacity(0.28)
    }
    
    private var hasError: Bool {
        snapshot?.lastError != nil
    }
    
    private var errorAccentColor: Color {
        switch account.syncStatus {
        case .unauthorized:
            return .orange
        case .failed, .degraded:
            return .red
        default:
            return .secondary
        }
    }

    private func subscriptionExpiryColor(_ expiresAt: Date) -> Color {
        let remainingSeconds = expiresAt.timeIntervalSinceNow
        if remainingSeconds < 2 * 24 * 60 * 60 {
            return .red
        }
        if remainingSeconds < 4 * 24 * 60 * 60 {
            return .yellow
        }
        return .secondary
    }

    private func remainingString(_ window: RateLimitWindowSnapshot?) -> String {
        guard let window else { return "N/A" }
        return "\(window.percentLeft)% left"
    }
    
    private func progressValue(_ window: RateLimitWindowSnapshot?) -> Double {
        guard let window else { return 0.08 }
        return min(max(Double(window.percentLeft) / 100, 0.04), 1)
    }
    
    private func barColor(_ window: RateLimitWindowSnapshot?) -> Color {
        guard let percentLeft = window?.percentLeft else { return .secondary }
        switch percentLeft {
        case 70...:
            return Color(red: 0.19, green: 0.78, blue: 0.42)
        case 40..<70:
            return Color(red: 0.93, green: 0.72, blue: 0.19)
        case 20..<40:
            return Color(red: 0.96, green: 0.48, blue: 0.23)
        default:
            return Color(red: 0.88, green: 0.24, blue: 0.23)
        }
    }
    
    private func shortTimeString(_ date: Date?) -> String {
        guard let date else { return "--:--" }
        return date.formatted(date: .omitted, time: .shortened)
    }
    
    private func shortDayString(_ date: Date?) -> String {
        guard let date else { return "--- --" }
        
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
    
    private var trackBackground: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                colors: [Color.white.opacity(0.035), Color.white.opacity(0.09)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        
        return LinearGradient(
            colors: [
                Color.black.opacity(0.03),
                Color.black.opacity(0.06),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
    
    private var trackBorderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }
}

struct PlanTag: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 8))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tagBackground, in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tagBorder)
            }
            .foregroundStyle(tagForeground)
            .lineLimit(1)
    }
    
    private var tagBackground: Color {
        colorScheme == .dark ? Color.blue.opacity(0.12) : Color.blue.opacity(0.10)
    }
    
    private var tagBorder: Color {
        colorScheme == .dark ? Color.blue.opacity(0.16) : Color.blue.opacity(0.22)
    }
    
    private var tagForeground: Color {
        colorScheme == .dark
            ? Color(red: 0.42, green: 0.74, blue: 1.0)
            : Color(red: 0.16, green: 0.44, blue: 0.84)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView(dataSource: PreviewDataSource(scenario: .empty), runsLifecycleTasks: false)
                .previewDisplayName("Empty")
            
            ContentView(dataSource: PreviewDataSource(scenario: .mixed), runsLifecycleTasks: false)
                .previewDisplayName("Mixed")
            
            ContentView(
                dataSource: PreviewDataSource(scenario: .loginInProgress),
                runsLifecycleTasks: false,
                quickLoginInProgressOverride: true
            )
            .previewDisplayName("Login In Progress")
            
            SelectedAccountCardStylePreview()
                .previewDisplayName("Selected Card Styles")
        }
    }
}

private struct SelectedAccountCardStylePreview: View {
    private let account = PreviewFactory.makeSampleAccounts().first!
    private let snapshot: CodexUsageSnapshot?
    
    init() {
        snapshot = PreviewFactory.makeSnapshot(for: account)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected Account Card Styles")
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 12) {
                ForEach(AccountCardView.SelectedStyle.allCases) { style in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(style.displayName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        
                        AccountCardView(
                            account: account,
                            snapshot: snapshot,
                            isLocalAccount: true,
                            isSwitchingToLocal: false,
                            selectedStyle: style,
                            onShowError: { _, _ in },
                            onSwitchToLocal: {}
                        )
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
