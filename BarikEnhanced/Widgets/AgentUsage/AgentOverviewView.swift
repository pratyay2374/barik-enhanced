import SwiftUI

/// Compact "all agents at a glance" summary (doc section 10) — answers "am I
/// close to hitting any limit?" without opening every provider individually.
/// Each agent is its own rounded "island" row; tapping one jumps straight to
/// that agent's detail view.
struct AgentOverviewView: View {
    let descriptors: [AgentProviderDescriptor]
    let onSelect: (String) -> Void

    @State private var hoveredID: String?

    private var nearLimitRows: [AgentOverviewRow] {
        descriptors.compactMap { $0.overviewRow() }.filter { $0.isNearLimit }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AgentUsageStyle.cardSpacing) {
            ForEach(descriptors) { descriptor in
                Button {
                    onSelect(descriptor.id)
                } label: {
                    row(for: descriptor)
                }
                .buttonStyle(.agentCard)
                .onHover { hovering in hoveredID = hovering ? descriptor.id : nil }
                .pointingHandOnHover()
            }

            if let firstWarning = nearLimitRows.first {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("\(descriptors.first { $0.id == firstWarning.providerID }?.displayName ?? "An agent") is approaching its limit")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .agentUsageCard(fill: Color.orange.opacity(0.12))
            }
        }
    }

    private func row(for descriptor: AgentProviderDescriptor) -> some View {
        let overview = descriptor.overviewRow()
        // Providers with nothing to show yet (not signed in, coming soon) read
        // as visually secondary to ones actively reporting real usage.
        let isLive = overview?.headlinePercentage != nil
        return HStack(spacing: 10) {
            AgentIconView(descriptor: descriptor, size: 16, monochrome: !isLive)
                .opacity(isLive ? 1 : 0.6)

            VStack(alignment: .leading, spacing: 1) {
                Text(descriptor.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isLive ? Color.white : Color.white.opacity(0.7))
                Text(overview?.statusMessage ?? overview?.accountLabel ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }

            Spacer()

            if let percentage = overview?.headlinePercentage {
                UsageRing(percentage: percentage, color: (overview?.isNearLimit ?? false) ? .orange : .white)
            } else {
                Text("—")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.25))
                    .frame(width: 26, height: 26)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(hoveredID == descriptor.id ? 0.5 : 0.25))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .agentUsageCard(fill: rowFill(isLive: isLive, isHovered: hoveredID == descriptor.id))
        .animation(.easeOut(duration: 0.12), value: hoveredID)
    }

    private func rowFill(isLive: Bool, isHovered: Bool) -> Color {
        if isHovered { return Color.white.opacity(isLive ? 0.1 : 0.07) }
        return isLive ? AgentUsageStyle.cardFill : AgentUsageStyle.subtleCardFill
    }
}
