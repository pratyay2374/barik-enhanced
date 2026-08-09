import SwiftUI

/// Inline "join a secured network" screen (doc section 4) — replaces the
/// primary popup content in place, the same way `AgentUsagePopup` swaps in
/// `ManageAccountsView`, so no new window/sheet is ever created.
struct NetworkPasswordView: View {
    let network: WiFiNetwork
    let joinState: WifiJoinState
    /// Optional explanatory note shown above the password field — e.g. when
    /// a known network's saved password stopped working.
    var hint: String? = nil
    var onCancel: () -> Void
    var onJoin: (_ password: String, _ remember: Bool) -> Void

    @State private var password: String = ""
    @State private var revealPassword: Bool = false
    @State private var remember: Bool = true
    @FocusState private var passwordFieldFocused: Bool

    private var isConnecting: Bool {
        if case .connecting(let ssid) = joinState { return ssid == network.ssid }
        return false
    }

    private var failure: JoinFailureReason? {
        if case .failed(let ssid, let reason) = joinState, ssid == network.ssid { return reason }
        return nil
    }

    private var isSuccess: Bool {
        if case .success(let ssid) = joinState { return ssid == network.ssid }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if isSuccess {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.18)).frame(width: 26, height: 26)
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.green)
                    }
                } else {
                    WifiSignalIcon(strength: network.signalBars, size: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(network.ssid)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(isSuccess ? "Connected" : network.securityLabel)
                        .font(.system(size: 10))
                        .foregroundStyle(isSuccess ? .green : .white.opacity(0.5))
                }
                Spacer()
            }

            if !isSuccess {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Password")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))

                    HStack(spacing: 6) {
                        Group {
                            if revealPassword {
                                TextField("", text: $password)
                            } else {
                                SecureField("", text: $password)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($passwordFieldFocused)
                        .disabled(isConnecting)
                        .onSubmit(attemptJoin)

                        Button {
                            revealPassword.toggle()
                        } label: {
                            Image(systemName: revealPassword ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .pointingHandOnHover()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .networkCard(fill: NetworkStyle.subtleCardFill, cornerRadius: 8)
                }

                Toggle("Remember this network", isOn: $remember)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
                    .disabled(isConnecting)

                if let hint, failure == nil {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let failure {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.yellow.opacity(0.9))
                        Text(failure.message)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .transition(.opacity)
                }

                HStack {
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                        .pointingHandOnHover()
                        .disabled(isConnecting)

                    Button(action: attemptJoin) {
                        HStack(spacing: 5) {
                            if isConnecting {
                                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                            }
                            Text(isConnecting ? "Joining…" : "Join")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(isConnecting || (network.isSecured && password.isEmpty))
                    .pointingHandOnHover()
                }
            }
        }
        .padding(14)
        .networkCard()
        .animation(.easeInOut(duration: 0.15), value: failure)
        .onAppear { passwordFieldFocused = true }
    }

    private func attemptJoin() {
        guard !isConnecting else { return }
        onJoin(password, remember)
    }
}
