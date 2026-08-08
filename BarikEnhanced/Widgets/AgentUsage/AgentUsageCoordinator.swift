import Foundation

/// Remembers which agent/overview state the unified widget was last showing,
/// so reopening the popup returns to where the user left it (doc section 15).
@MainActor
final class AgentUsageCoordinator: ObservableObject {
    static let shared = AgentUsageCoordinator()

    @Published var selectedProviderID: String {
        didSet { UserDefaults.standard.set(selectedProviderID, forKey: Self.selectedProviderKey) }
    }
    @Published var showOverview: Bool = false

    private static let selectedProviderKey = "agent-usage-selected-provider"

    private init() {
        selectedProviderID = UserDefaults.standard.string(forKey: Self.selectedProviderKey) ?? "claude"
    }
}
