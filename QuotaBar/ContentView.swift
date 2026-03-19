import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var viewModel: ProviderMonitorViewModel
    
    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if viewModel.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(viewModel.accounts) { account in
                            AccountCardView(
                                account: account,
                                snapshot: viewModel.snapshotsByAccountID[account.id],
                                isLocalAccount: viewModel.isLocalCodexAccount(account),
                                isSwitchingToLocal: viewModel.isSwitchingLocalCodexAccount(account),
                                onSwitchToLocal: {
                                    Task { await viewModel.switchLocalCodexAccount(to: account) }
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
        .padding(12)
        .frame(width: 450, height: 500)
        .task {
            viewModel.panelDidOpen()
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
                Button {
                    Task { await viewModel.refreshAll(reason: "manual") }
                } label: {
                    if viewModel.isRefreshingAll {
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
        VStack(alignment: .leading, spacing: 8) {
            Text("No Codex accounts")
                .font(.headline)
            Text("Add accounts in Settings. QuotaBar stores each account's auth separately and reads usage without touching the default `~/.codex`.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: .rect(cornerRadius: 16))
    }
}

private struct AccountCardView: View {
    let account: ProviderAccountRecord
    let snapshot: CodexUsageSnapshot?
    let isLocalAccount: Bool
    let isSwitchingToLocal: Bool
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
            
            if let error = snapshot?.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 6) {
                PlanTag(text: account.planType.capitalized)
                Spacer()
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
            ZStack {
                if isLocalAccount {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.ultraThinMaterial)
                }
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardBackground)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(borderStyle)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: glowColor.opacity(isHovered ? 0.12 : 0.0), radius: isHovered ? 6 : 0, x: 0, y: 0)
        .shadow(color: glowColor.opacity(isHovered ? 0.06 : 0.0), radius: isHovered ? 10 : 0, x: 0, y: 0)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            guard !isLocalAccount && !isSwitchingToLocal else { return }
            onSwitchToLocal()
        }
    }
    
    private func quotaBarRow(title: String, window: RateLimitWindowSnapshot?, resetText: String) -> some View {
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
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.035), Color.white.opacity(0.09)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(Color.white.opacity(0.06))
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
        let style: (String, Color) = switch account.syncStatus {
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
            .font(.system(size: 8 ))
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
            return LinearGradient(
                colors: [
                    Color(red: 0.24, green: 0.30, blue: 0.38).opacity(0.7),
                    Color(red: 0.18, green: 0.22, blue: 0.29).opacity(0.78),
                    Color(red: 0.28, green: 0.36, blue: 0.46).opacity(0.64)
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
            return LinearGradient(
                colors: [
                    Color.white.opacity(0.16),
                    Color(red: 0.54, green: 0.66, blue: 0.78).opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        
        return LinearGradient(
            colors: [
                Color.white.opacity(isHovered ? 0.18 : 0.075),
                Color.white.opacity(isHovered ? 0.08 : 0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
    
    private var glowColor: Color {
        if isLocalAccount {
            return Color(red: 0.56, green: 0.68, blue: 0.8)
        }
        return Color.white.opacity(0.92)
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
}

private struct PlanTag: View {
    let text: String
    
    var body: some View {
        Text(text)
            .font(.system(size: 8 ))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.blue.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(Color.blue.opacity(0.16))
            }
            .foregroundStyle(Color(red: 0.42, green: 0.74, blue: 1.0))
            .lineLimit(1)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(viewModel: PreviewFactory.makeViewModel())
    }
}
