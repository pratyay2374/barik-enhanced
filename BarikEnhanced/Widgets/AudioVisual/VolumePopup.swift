import SwiftUI

// MARK: - Scroll Handler

/// Manages scroll event interception via a local event monitor.
/// Using a monitor means we intercept events BEFORE they reach NSSlider —
/// preventing its built-in "snap to 0/100" scroll behaviour.
/// The monitor is started/stopped on popup appear/disappear.
private class VolumeScrollHandler: ObservableObject {
    private var accumulator: CGFloat = 0
    private var monitor: Any?
    private var lastStepTime: TimeInterval = 0
    
    /// Minimum time between volume steps (seconds).
    /// Prevents continuous trackpad scrolling from racing to the edges.
    private let stepInterval: TimeInterval = 0.05
    
    /// Called with (increase: Bool, fine: Bool) when a scroll step fires.
    var onStep: ((Bool, Bool) -> Void)?
    
    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            
            // Only intercept events targeting a floating panel (our popup).
            // Non-panel windows (e.g. settings) keep normal scroll behaviour.
            guard let window = event.window, window is HidingPanel else { return event }
            
            return self.handle(event: event)
        }
    }
    
    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        accumulator = 0
    }
    
    private func handle(event: NSEvent) -> NSEvent? {
        let isMomentum = !event.momentumPhase.isEmpty
        
        // Block momentum entirely — return nil so NSSlider never sees it
        guard !isMomentum else { return nil }
        
        let delta = event.scrollingDeltaY
        guard abs(delta) > 0.1 else { return nil }
        
        let isShift = event.modifierFlags.contains(.shift)
        // Negate: scroll-up (negative deltaY) = increase volume
        accumulator -= delta
        
        // Time-based throttle: at most one step per stepInterval.
        // This prevents continuous scrolling (finger held on trackpad)
        // from firing dozens of steps per second.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastStepTime >= stepInterval else { return nil }
        
        let threshold: CGFloat = 3.0
        if accumulator > threshold {
            DispatchQueue.main.async { self.onStep?(true, isShift) }
            accumulator = 0
            lastStepTime = now
        } else if accumulator < -threshold {
            DispatchQueue.main.async { self.onStep?(false, isShift) }
            accumulator = 0
            lastStepTime = now
        }
        
        // Return nil — event is consumed, NSSlider never sees it
        return nil
    }
    
    deinit { stop() }
}

// MARK: - VolumePopup

struct VolumePopup: View {
    @ObservedObject private var audioVisualManager = AudioVisualManager.shared
    @StateObject private var scrollHandler = VolumeScrollHandler()
    @State private var iconBounce = false

    var body: some View {
        VStack(spacing: 16) {
            // MARK: - Header
            headerSection
            
            // MARK: - Slider
            sliderSection
            
            // MARK: - Output Device Selector
            deviceSection
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(width: 290)
        .foregroundStyle(.white)
        .onAppear {
            scrollHandler.onStep = { increase, fine in
                audioVisualManager.adjustVolume(by: increase ? 1 : -1, fine: fine)
            }
            scrollHandler.start()
        }
        .onDisappear {
            scrollHandler.stop()
        }
        .onKeyPress(.leftArrow) {
            audioVisualManager.adjustVolume(by: -1, fine: false)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            audioVisualManager.adjustVolume(by: 1, fine: false)
            return .handled
        }
        .onKeyPress(.escape) {
            NotificationCenter.default.post(name: .willHideWindow, object: nil)
            return .handled
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "mM")) { _ in
            audioVisualManager.toggleMute()
            return .handled
        }
        .focusable()
        .focusEffectDisabled()
    }
    
    // MARK: - Header Section
    
    private var headerSection: some View {
        HStack(spacing: 12) {
            // Clickable volume icon — toggles mute
            Button(action: {
                withAnimation(.spring(duration: 0.3)) {
                    audioVisualManager.toggleMute()
                    iconBounce.toggle()
                }
            }) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(volumeIconColor)
                    .frame(width: 32, height: 32)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: iconBounce)
            }
            .buttonStyle(PlainButtonStyle())
            .onTapGesture(count: 2) {
                withAnimation(.spring(duration: 0.3)) {
                    audioVisualManager.toggleMaxVolume()
                }
            }
            .accessibilityLabel(audioVisualManager.isMuted ? "Unmute" : "Mute")
            .accessibilityHint("Click to toggle mute. Double-click to toggle max volume.")
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Volume")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                
                Text(volumeStatusText)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.2), value: volumeStatusText)
            }
            
            Spacer()
            
            // Volume percentage badge
            Text(volumePercentageText)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.2), value: volumePercentageText)
        }
    }
    
    // MARK: - Slider Section
    
    private var sliderSection: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
            
            Slider(
                value: Binding(
                    get: { audioVisualManager.volumeLevel },
                    set: { audioVisualManager.setVolume(level: $0) }
                ),
                in: 0...1
            )
            .tint(sliderColor)
            .disabled(audioVisualManager.isMuted)
            .accessibilityLabel("Volume slider")
            .accessibilityValue("\(Int(audioVisualManager.volumeLevel * 100)) percent")
            
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.vertical, 4)
        .opacity(audioVisualManager.isMuted ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: audioVisualManager.isMuted)
    }
    
    // MARK: - Device Section
    
    private var deviceSection: some View {
        VStack(spacing: 0) {
            Divider()
                .background(.white.opacity(0.1))
                .padding(.bottom, 10)
            
            Menu {
                ForEach(audioVisualManager.outputDevices) { device in
                    Button(action: {
                        audioVisualManager.setOutputDevice(device.id)
                    }) {
                        HStack {
                            Image(systemName: deviceIcon(for: device))
                            Text(device.name)
                            if device.id == audioVisualManager.activeDeviceID {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: activeDeviceIcon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                    
                    Text(audioVisualManager.activeDeviceName)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.06))
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Output device: \(audioVisualManager.activeDeviceName)")
        }
    }
    
    // MARK: - Computed Properties
    
    private var volumeIcon: String {
        if audioVisualManager.isMuted {
            return "speaker.slash.fill"
        }
        if audioVisualManager.isBluetoothActive {
            return "headphones"
        }
        if audioVisualManager.volumeLevel < 0.01 {
            return "speaker.fill"
        } else if audioVisualManager.volumeLevel < 0.33 {
            return "speaker.wave.1.fill"
        } else if audioVisualManager.volumeLevel < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
    
    private var volumeIconColor: Color {
        audioVisualManager.isMuted ? .red.opacity(0.8) : .white
    }
    
    /// Slider tint color based on volume threshold
    private var sliderColor: Color {
        if audioVisualManager.isMuted { return .gray.opacity(0.5) }
        let level = audioVisualManager.volumeLevel
        if level < 0.01 {
            return .gray.opacity(0.5)
        } else if level < 0.50 {
            return Color(hue: 0.58, saturation: 0.5, brightness: 0.85) // Subtle blue
        } else if level < 0.90 {
            return Color(hue: 0.13, saturation: 0.6, brightness: 0.95) // Subtle yellow
        } else {
            return Color(hue: 0.0, saturation: 0.6, brightness: 0.9) // Subtle red
        }
    }

    private var volumeStatusText: String {
        if audioVisualManager.isMuted { return "Muted" }
        let level = audioVisualManager.volumeLevel
        if level < 0.01 { return "Silent" }
        else if level < 0.34 { return "Low" }
        else if level < 0.67 { return "Medium" }
        else { return "High" }
    }
    
    private var volumePercentageText: String {
        audioVisualManager.isMuted ? "—" : "\(Int(audioVisualManager.volumeLevel * 100))%"
    }
    
    private var activeDeviceIcon: String {
        if let device = audioVisualManager.outputDevices.first(where: { $0.id == audioVisualManager.activeDeviceID }) {
            return deviceIcon(for: device)
        }
        return "hifispeaker.fill"
    }
    
    private func deviceIcon(for device: AudioOutputDevice) -> String {
        if device.isBluetoothDevice { return "headphones" }
        if device.transportType == 0x75736220 { return "headphones" }  // USB
        if device.transportType == 0x626C7464 { return "laptopcomputer" } // Built-in
        return "hifispeaker.fill"
    }
}

// MARK: - Preview

struct VolumePopup_Previews: PreviewProvider {
    static var previews: some View {
        VolumePopup()
            .background(Color.black)
            .previewLayout(.sizeThatFits)
    }
}