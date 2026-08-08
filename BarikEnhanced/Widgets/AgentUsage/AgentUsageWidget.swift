import SwiftUI

struct AgentUsageWidget: View {
    @EnvironmentObject var configProvider: ConfigProvider
    @ObservedObject private var coordinator = AgentUsageCoordinator.shared
    @ObservedObject private var claude = ClaudeUsageManager.shared
    @ObservedObject private var codex = CodexUsageManager.shared
    @ObservedObject private var openCode = OpenCodeUsageManager.shared
    @ObservedObject private var cursor = CursorUsageManager.shared

    @State private var widgetFrame: CGRect = .zero

    private var descriptors: [AgentProviderDescriptor] {
        AgentUsageDescriptors.build(config: configProvider.config, claude: claude, codex: codex, openCode: openCode, cursor: cursor)
    }

    /// Prefers the currently-selected agent's ring; falls back to the first
    /// agent with real data so the tray icon isn't blank just because the
    /// user last looked at Cursor's "coming soon" placeholder.
    private var displayed: (descriptor: AgentProviderDescriptor, percentage: Double)? {
        let all = descriptors
        if let selected = all.first(where: { $0.id == coordinator.selectedProviderID }),
           let accountID = selected.selectedAccountID() ?? selected.accounts().first?.id,
           case .available(let snapshot) = selected.usageState(accountID),
           let percentage = snapshot.metrics.first?.percentage {
            return (selected, percentage)
        }
        for descriptor in all {
            guard let accountID = descriptor.selectedAccountID() ?? descriptor.accounts().first?.id else { continue }
            if case .available(let snapshot) = descriptor.usageState(accountID), let percentage = snapshot.metrics.first?.percentage {
                return (descriptor, percentage)
            }
        }
        return nil
    }

    private func thresholdConfiguration(for providerID: String) -> UsageThresholdConfiguration {
        UsageThresholdConfiguration(config: AgentUsageDescriptors.providerConfig(configProvider.config, providerID: providerID))
    }

    var body: some View {
        ZStack {
            if let displayed {
                let ringColor = thresholdConfiguration(for: displayed.descriptor.id).color(for: displayed.percentage)
                Circle()
                    .trim(from: 0.5 - min(displayed.percentage, 1.0) / 2, to: 0.5 + min(displayed.percentage, 1.0) / 2)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(90))
                    .animation(.easeOut(duration: 0.3), value: displayed.percentage)

                AgentIconView(descriptor: displayed.descriptor, size: 16, monochrome: true)
                    .opacity(0.85)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .medium))
                    .opacity(0.5)
            }
        }
        .frame(width: 28, height: 28)
        .foregroundStyle(.foregroundOutside)
        .shadow(color: .foregroundShadowOutside, radius: 3)
        .experimentalConfiguration(cornerRadius: 15)
        .frame(maxHeight: .infinity)
        .background(.black.opacity(0.001))
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { widgetFrame = geometry.frame(in: .global) }
                    .onChange(of: geometry.frame(in: .global)) { _, newFrame in widgetFrame = newFrame }
            }
        )
        .onTapGesture {
            MenuBarPopup.show(rect: widgetFrame, id: "agent-usage") {
                AgentUsagePopup()
                    .environmentObject(configProvider)
            }
        }
        .onAppear {
            let config = configProvider.config
            claude.startUpdating(config: AgentUsageDescriptors.providerConfig(config, providerID: "claude"))
            codex.startUpdating(config: AgentUsageDescriptors.providerConfig(config, providerID: "codex"))
            openCode.startUpdating(config: AgentUsageDescriptors.providerConfig(config, providerID: "opencode"))
            cursor.startUpdating(config: AgentUsageDescriptors.providerConfig(config, providerID: "cursor"))
        }
    }
}
