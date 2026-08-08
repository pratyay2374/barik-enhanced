import Foundation
import SwiftUI

/// Cursor has no verified local file or public API this widget can read usage
/// from yet. Rather than fake a number, Cursor is wired into the same
/// provider/account architecture as a real, selectable agent whose detail view
/// honestly reports that usage isn't available yet — this proves the
/// `AgentProviderDescriptor` abstraction generalizes without inventing data.
@MainActor
final class CursorUsageManager: ObservableObject {
    static let shared = CursorUsageManager()
    static let placeholderAccountID = "cursor-placeholder"

    private init() {}

    func startUpdating(config: ConfigData) {}
    func reconnectIfNeeded() {}

    func accounts() -> [AgentAccount] {
        [AgentAccount(id: Self.placeholderAccountID, label: "Cursor", subtitle: nil, isRemovable: false)]
    }

    func snapshot(for accountID: String) -> AccountUsageState {
        .unavailable(message: "Cursor usage isn't available yet. This agent is wired in and ready for when a data source is confirmed.")
    }

    func refresh(accountID: String) {}
}
