import SwiftUI

/// Compact agent switcher (doc section 4) — a single rounded "island" housing
/// all agents, with the selected one getting its own pill highlight. Replaces
/// the earlier underline+divider treatment with the same grouped-card
/// language used throughout the rest of the widget.
struct AgentSwitcherView: View {
    let descriptors: [AgentProviderDescriptor]
    let selectedID: String
    let onSelect: (String) -> Void

    @Namespace private var pillNamespace
    @State private var hoveredID: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(descriptors) { descriptor in
                let isSelected = descriptor.id == selectedID
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { onSelect(descriptor.id) }
                } label: {
                    HStack(spacing: 4) {
                        AgentIconView(descriptor: descriptor, size: 12, monochrome: !isSelected)
                        Text(descriptor.shortLabel)
                            .font(.system(size: 10.5, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .foregroundStyle(isSelected ? Color.white : Color.white.opacity(hoveredID == descriptor.id ? 0.75 : 0.5))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .background {
                        // Shared geometry so the highlight slides between tabs
                        // instead of just cross-fading in place.
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(descriptor.brandColor.opacity(0.22))
                                .matchedGeometryEffect(id: "selectedPill", in: pillNamespace)
                        } else if hoveredID == descriptor.id {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        }
                    }
                }
                .buttonStyle(.agentCard)
                .onHover { hovering in hoveredID = hovering ? descriptor.id : nil }
                .pointingHandOnHover()
            }
        }
        .padding(4)
        .agentUsageCard(fill: AgentUsageStyle.subtleCardFill, cornerRadius: AgentUsageStyle.cardCornerRadius - 1)
    }
}
