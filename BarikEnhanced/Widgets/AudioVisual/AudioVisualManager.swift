import Combine
import Foundation
import CoreAudio
import IOKit
import IOKit.graphics
import SwiftUI

// MARK: - Core Audio Listeners

fileprivate let defaultDeviceListener: AudioObjectPropertyListenerProc = { _, _, _, inClientData in
    guard let clientData = inClientData else { return noErr }
    let manager = Unmanaged<AudioVisualManager>.fromOpaque(clientData).takeUnretainedValue()
    manager.handleDefaultDeviceChanged()
    return noErr
}

fileprivate let devicePropertyListener: AudioObjectPropertyListenerProc = { _, _, _, inClientData in
    guard let clientData = inClientData else { return noErr }
    let manager = Unmanaged<AudioVisualManager>.fromOpaque(clientData).takeUnretainedValue()
    
    // Ignore echo notifications caused by local volume/mute updates.
    // 500ms window to account for async scheduling delays.
    let now = ProcessInfo.processInfo.systemUptime
    guard now - manager.lastLocalUpdateTimestamp > 0.5 else { return noErr }
    
    manager.updateVolumeStatus()
    return noErr
}

/// Represents an available audio output device.
struct AudioOutputDevice: Identifiable, Equatable, Hashable {
    let id: AudioDeviceID
    let name: String
    let transportType: UInt32
    
    var isBluetoothDevice: Bool {
        // kAudioDeviceTransportTypeBluetooth = 'blue' = 0x626C7565
        // kAudioDeviceTransportTypeBluetoothLE = 'blea' = 0x626C6561
        transportType == 0x626C7565 || transportType == 0x626C6561
    }
    
    var isHeadphones: Bool {
        // Bluetooth devices or wired headphones via transport type
        // kAudioDeviceTransportTypeUSB = 'usb ' = 0x75736220
        isBluetoothDevice || transportType == 0x75736220
    }
}

/// Central manager for audio and visual system controls.
class AudioVisualManager: ObservableObject {
    static let shared = AudioVisualManager()

    @Published var volumeLevel: Float = 0.0
    @Published var isMuted: Bool = false
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var activeDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published var isBluetoothActive: Bool = false
    
    /// Stores volume before muting so unmute can restore it.
    var preMuteVolume: Float = 0.5
    /// Stores volume before toggling to max (for double-click restore).
    private var preMaxVolume: Float = 0.5

    private var timer: Timer?
    private var audioObjectPropertyAddress: AudioObjectPropertyAddress
    
    private var isSystemListenerRegistered = false
    private var registeredDeviceID: AudioDeviceID = kAudioObjectUnknown
    
    /// Timestamp of the last local volume adjustment, used to suppress listener echo feedback.
    var lastLocalUpdateTimestamp: TimeInterval = 0

    private init() {
        audioObjectPropertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        startMonitoring()
    }
    
    deinit {
        stopMonitoring()
    }
    
    private func startMonitoring() {
        // Update every 10 seconds for optimal energy efficiency
        timer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }
        
        // Add system-level default device listener
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let result = AudioObjectAddPropertyListener(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            defaultDeviceListener,
            selfPtr
        )
        
        if result == noErr {
            isSystemListenerRegistered = true
        }
        
        // Initial setup of listeners on the current default device
        var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let deviceResult = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        
        if deviceResult == noErr && defaultDeviceID != kAudioObjectUnknown {
            setupDeviceListeners(for: defaultDeviceID)
        }
        
        updateStatus()
    }
    
    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        
        if isSystemListenerRegistered {
            var defaultDeviceAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            AudioObjectRemovePropertyListener(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultDeviceAddress,
                defaultDeviceListener,
                selfPtr
            )
            isSystemListenerRegistered = false
        }
        
        removeDeviceListeners()
    }
    
    /// Called when the default system output device changes
    func handleDefaultDeviceChanged() {
        var defaultDeviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let deviceResult = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultDeviceAddress,
            0,
            nil,
            &propertySize,
            &defaultDeviceID
        )
        
        if deviceResult == noErr && defaultDeviceID != kAudioObjectUnknown {
            setupDeviceListeners(for: defaultDeviceID)
        }
        
        updateStatus()
    }
    
    private func setupDeviceListeners(for deviceID: AudioDeviceID) {
        removeDeviceListeners()
        
        registeredDeviceID = deviceID
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        // Volume listener
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListener(deviceID, &volumeAddress, devicePropertyListener, selfPtr)
        
        // Mute listener
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectAddPropertyListener(deviceID, &muteAddress, devicePropertyListener, selfPtr)
    }
    
    private func removeDeviceListeners() {
        guard registeredDeviceID != kAudioObjectUnknown else { return }
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListener(registeredDeviceID, &volumeAddress, devicePropertyListener, selfPtr)
        
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        _ = AudioObjectRemovePropertyListener(registeredDeviceID, &muteAddress, devicePropertyListener, selfPtr)
        
        registeredDeviceID = kAudioObjectUnknown
    }
    
    /// Updates all audio and visual status properties
    private func updateStatus() {
        self.updateVolumeStatus()
        self.updateOutputDevices()
    }
    
    /// Updates volume level and mute status
    func updateVolumeStatus() {
        // Run audio API calls on background queue to avoid blocking
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            // Skip if a local update happened recently — the local state is
            // authoritative and we don't want the system readback to overwrite it.
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastLocalUpdateTimestamp > 0.5 else { return }
            
            var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
            var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
            
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            let result = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &outputDeviceID
            )
            
            guard result == noErr && outputDeviceID != kAudioObjectUnknown else { 
                DispatchQueue.main.async {
                    self.volumeLevel = 0.0
                    self.isMuted = false
                }
                return 
            }
            
            // Get volume level - using master volume property
            var volume: Float32 = 0.0
            propertySize = UInt32(MemoryLayout<Float32>.size)
            propertyAddress.mSelector = kAudioDevicePropertyVolumeScalar
            propertyAddress.mScope = kAudioObjectPropertyScopeOutput
            propertyAddress.mElement = kAudioObjectPropertyElementMain
            
            let volumeResult = AudioObjectGetPropertyData(
                outputDeviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &volume
            )
            
            // Get mute status
            var muteValue: UInt32 = 0
            propertySize = UInt32(MemoryLayout<UInt32>.size)
            propertyAddress.mSelector = kAudioDevicePropertyMute
            propertyAddress.mScope = kAudioObjectPropertyScopeOutput
            propertyAddress.mElement = kAudioObjectPropertyElementMain
            
            let muteResult = AudioObjectGetPropertyData(
                outputDeviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &muteValue
            )
            
            // Get transport type for Bluetooth detection
            var transportType: UInt32 = 0
            propertySize = UInt32(MemoryLayout<UInt32>.size)
            propertyAddress.mSelector = kAudioDevicePropertyTransportType
            propertyAddress.mScope = kAudioObjectPropertyScopeGlobal
            
            let transportResult = AudioObjectGetPropertyData(
                outputDeviceID,
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &transportType
            )
            
            // Final check before updating UI — another local update may have
            // happened while we were reading from the system.
            guard now - self.lastLocalUpdateTimestamp > 0.5 else { return }
            
            // Update UI on main queue
            DispatchQueue.main.async {
                self.activeDeviceID = outputDeviceID
                
                if volumeResult == noErr {
                    let newVolume = max(0.0, min(1.0, volume))
                    if self.volumeLevel != newVolume { 
                        withAnimation(.easeOut(duration: 0.1)) {
                            self.volumeLevel = newVolume 
                        }
                    }
                } else if self.volumeLevel == 0.0 {
                    withAnimation(.easeOut(duration: 0.1)) {
                        self.volumeLevel = 0.5
                    }
                }

                if muteResult == noErr {
                    let newMuted = muteValue != 0
                    if self.isMuted != newMuted { self.isMuted = newMuted }
                }
                
                if transportResult == noErr {
                    // Bluetooth: 0x626C7565, BluetoothLE: 0x626C6561
                    let isBT = transportType == 0x626C7565 || transportType == 0x626C6561
                    if self.isBluetoothActive != isBT { self.isBluetoothActive = isBT }
                }
            }
        }
    }
    
    /// Fetches all available output audio devices
    private func updateOutputDevices() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var propertySize: UInt32 = 0
            var result = AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &propertySize
            )
            
            guard result == noErr else { return }
            
            let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
            var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: deviceCount)
            
            result = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                0,
                nil,
                &propertySize,
                &deviceIDs
            )
            
            guard result == noErr else { return }
            
            var devices: [AudioOutputDevice] = []
            
            for deviceID in deviceIDs {
                // Check if device has output channels
                var streamPropertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: kAudioObjectPropertyScopeOutput,
                    mElement: kAudioObjectPropertyElementMain
                )
                
                var streamSize: UInt32 = 0
                let streamResult = AudioObjectGetPropertyDataSize(
                    deviceID,
                    &streamPropertyAddress,
                    0,
                    nil,
                    &streamSize
                )
                
                // Skip devices with no output streams
                guard streamResult == noErr && streamSize > 0 else { continue }
                
                // Get device name
                var namePropertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioObjectPropertyName,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                
                var nameRef: CFString = "" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                
                let nameResult = AudioObjectGetPropertyData(
                    deviceID,
                    &namePropertyAddress,
                    0,
                    nil,
                    &nameSize,
                    &nameRef
                )
                
                let name = nameResult == noErr ? nameRef as String : "Unknown Device"
                
                // Get transport type
                var transportPropertyAddress = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyTransportType,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                
                var transportType: UInt32 = 0
                var transportSize = UInt32(MemoryLayout<UInt32>.size)
                
                AudioObjectGetPropertyData(
                    deviceID,
                    &transportPropertyAddress,
                    0,
                    nil,
                    &transportSize,
                    &transportType
                )
                
                devices.append(AudioOutputDevice(
                    id: deviceID,
                    name: name,
                    transportType: transportType
                ))
            }
            
            DispatchQueue.main.async {
                self.outputDevices = devices
            }
        }
    }

    
    // MARK: - Control Methods
    
    /// Sets the system volume level.
    /// Also unmutes the system if currently muted and setting volume > 0,
    /// ensuring the widget and system stay in sync.
    func setVolume(level: Float) {
        lastLocalUpdateTimestamp = ProcessInfo.processInfo.systemUptime
        let clampedLevel = max(0.0, min(1.0, level))
        
        // Update local state immediately (we're always on the main thread)
        // to prevent stale reads during rapid slider/scroll changes.
        self.volumeLevel = clampedLevel
        
        var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &outputDeviceID
        )
        
        guard result == noErr else { return }
        
        var volume = Float32(clampedLevel)
        propertySize = UInt32(MemoryLayout<Float32>.size)
        propertyAddress.mSelector = kAudioDevicePropertyVolumeScalar
        propertyAddress.mScope = kAudioObjectPropertyScopeOutput
        propertyAddress.mElement = kAudioObjectPropertyElementMain
        
        AudioObjectSetPropertyData(
            outputDeviceID,
            &propertyAddress,
            0,
            nil,
            propertySize,
            &volume
        )
        
        // If we're setting volume > 0 and the system is muted, unmute it.
        // This keeps the widget and system in sync — adjusting volume
        // should always result in audible output.
        if clampedLevel > 0 && isMuted {
            setMuteState(muted: false, deviceID: outputDeviceID)
        }
    }
    
    /// Adjusts volume by a delta (positive = increase, negative = decrease).
    /// Pass `fine: true` for 1% increments (Shift held).
    func adjustVolume(by delta: Float, fine: Bool = false) {
        let step: Float = fine ? 0.01 : 0.05
        let newLevel = max(0.0, min(1.0, volumeLevel + (delta > 0 ? step : -step)))
        withAnimation(.easeOut(duration: 0.1)) {
            setVolume(level: newLevel)
        }
    }
    
    /// Toggles the mute status, remembering/restoring pre-mute volume.
    func toggleMute() {
        lastLocalUpdateTimestamp = ProcessInfo.processInfo.systemUptime
        
        let wasMuted = isMuted
        
        if !wasMuted {
            // Save current volume before muting
            preMuteVolume = volumeLevel
        }
        
        // Update local state IMMEDIATELY (synchronous) so that no
        // listener/timer readback can overwrite it before the UI reacts.
        self.isMuted = !wasMuted
        
        var outputDeviceID: AudioDeviceID = kAudioObjectUnknown
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &outputDeviceID
        )
        
        guard result == noErr else { return }
        
        // Set system mute state
        setMuteState(muted: !wasMuted, deviceID: outputDeviceID)
        
        // Restore volume when unmuting
        if wasMuted && preMuteVolume > 0 {
            withAnimation(.easeOut(duration: 0.2)) {
                setVolume(level: preMuteVolume)
            }
        }
    }
    
    /// Toggles between current volume and 100% (for double-click).
    func toggleMaxVolume() {
        if volumeLevel < 1.0 {
            preMaxVolume = volumeLevel
            withAnimation(.spring(duration: 0.3)) {
                setVolume(level: 1.0)
            }
            if isMuted {
                toggleMute()
            }
        } else {
            withAnimation(.spring(duration: 0.3)) {
                setVolume(level: preMaxVolume)
            }
        }
    }
    
    /// Sets the default output device to the given device ID.
    func setOutputDevice(_ deviceID: AudioDeviceID) {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var mutableDeviceID = deviceID
        let propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let result = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            propertySize,
            &mutableDeviceID
        )
        
        if result == noErr {
            DispatchQueue.main.async {
                self.activeDeviceID = deviceID
            }
            // Refresh state after device switch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.updateStatus()
            }
        }
    }
    
    /// Helper to set mute state on a specific device
    private func setMuteState(muted: Bool, deviceID: AudioDeviceID) {
        lastLocalUpdateTimestamp = ProcessInfo.processInfo.systemUptime
        self.isMuted = muted
        
        var muteValue: UInt32 = muted ? 1 : 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        
        AudioObjectSetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            propertySize,
            &muteValue
        )
    }
    
    /// Returns the name of the currently active output device
    var activeDeviceName: String {
        outputDevices.first(where: { $0.id == activeDeviceID })?.name ?? "System Output"
    }
    
    /// Returns whether the active device is Bluetooth
    var activeDeviceIsBluetooth: Bool {
        outputDevices.first(where: { $0.id == activeDeviceID })?.isBluetoothDevice ?? false
    }

} 