import SwiftUI

/// Renders one account's usage state — the percentage-first metric rows (doc
/// section 6/11) plus honest loading/auth/error/unavailable states (doc
/// section 13). Shared across every provider; only the data differs.
struct AgentUsageDetailView: View {
    let descriptor: AgentProviderDescriptor
    let accountID: String
    let thresholdConfiguration: UsageThresholdConfiguration

    var body: some View {
        switch descriptor.usageState(accountID) {
        case .loading:
            loadingView
        case .authRequired(let message):
            authRequiredView(message)
        case .unavailable(let message):
            messageView(message, icon: "chart.pie", showRefresh: true)
        case .error(let message, let lastUpdated):
            errorView(message, lastUpdated: lastUpdated)
        case .available(let snapshot):
            availableView(snapshot)
        }
    }

    // MARK: - Available

    private func availableView(_ snapshot: AccountUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: AgentUsageStyle.cardSpacing) {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(snapshot.metrics) { metric in
                    metricRow(metric)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .agentUsageCard()

            footer(lastUpdated: snapshot.lastUpdated)
        }
    }

    private func metricRow(_ metric: UsageMetric) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: metric.icon)
                    .font(.system(size: 12))
                    .opacity(0.6)
                Text(metric.title)
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                if let percentage = metric.percentage {
                    // Percentage is the most prominent element (doc section 6);
                    // color-coded so danger reads even at a glance.
                    Text("\(Int(min(percentage, 1.0) * 100))%")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(thresholdConfiguration.color(for: percentage))
                }
            }

            if let subtitle = metric.subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .opacity(0.45)
            }

            if let percentage = metric.percentage {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.gray.opacity(0.3))
                            .frame(height: 6)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(thresholdConfiguration.color(for: percentage))
                            .frame(width: geometry.size.width * min(percentage, 1.0), height: 6)
                            .animation(.easeOut(duration: 0.3), value: percentage)
                    }
                }
                .frame(height: 6)
            }

            if let reset = metric.resetDescription {
                HStack(spacing: 4) {
                    if let percentage = metric.percentage, percentage >= thresholdConfiguration.criticalPercentage {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.red)
                    }
                    Text(reset)
                        .font(.system(size: 11))
                        .opacity(0.5)
                }
            }
        }
    }

    // MARK: - Footer

    private func footer(lastUpdated: Date) -> some View {
        HStack(spacing: 12) {
            Text("Updated \(Self.timeAgoString(lastUpdated))")
                .font(.system(size: 11))
                .opacity(0.4)

            Spacer()

            if let signOut = descriptor.signOut {
                Button("Sign out") { signOut(accountID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .opacity(0.5)
                    .pointingHandOnHover()
            }

            Button(action: { descriptor.refresh(accountID) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
                    .opacity(0.6)
            }
            .buttonStyle(.plain)
            .pointingHandOnHover()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .agentUsageCard(fill: AgentUsageStyle.subtleCardFill)
    }

    // MARK: - Loading / auth / error / unavailable

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(0.8)
            Text("Loading usage data...")
                .font(.system(size: 11))
                .opacity(0.5)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .agentUsageCard()
    }

    private func authRequiredView(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 24))
                .opacity(0.5)
            Text(message)
                .font(.system(size: 11))
                .opacity(0.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let reauth = descriptor.reauthAccount {
                Button(action: { reauth(accountID) }) {
                    Text("Sign in again")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(descriptor.brandColor)
                .pointingHandOnHover()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .agentUsageCard()
    }

    private func errorView(_ message: String, lastUpdated: Date?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .opacity(0.5)
            Text(message)
                .font(.system(size: 11))
                .opacity(0.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let lastUpdated {
                Text("Last updated \(Self.timeAgoString(lastUpdated))")
                    .font(.system(size: 10))
                    .opacity(0.35)
            }
            Button(action: { descriptor.refresh(accountID) }) {
                Text("Retry")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(descriptor.brandColor)
            .pointingHandOnHover()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .agentUsageCard()
    }

    private func messageView(_ message: String, icon: String, showRefresh: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .opacity(0.5)
            Text(message)
                .font(.system(size: 11))
                .opacity(0.5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if showRefresh {
                Button(action: { descriptor.refresh(accountID) }) {
                    Text("Refresh")
                        .font(.system(size: 12, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(descriptor.brandColor)
                .pointingHandOnHover()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 30)
        .agentUsageCard()
    }

    private static func timeAgoString(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds) sec ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        return "\(minutes / 60)h ago"
    }
}
