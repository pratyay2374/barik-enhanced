import AppKit
import Carbon

/// Main-thread observation of the frontmost app's native menu bar. HIToolbox
/// broadcasts these documented events across processes. Observe at the
/// dispatcher, before SwiftUI's application event routing can consume them.
final class NativeMenuBarVisibilityObserver {
    private var eventHandler: EventHandlerRef?
    private let onChange: (Bool) -> Void

    init(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        var events = [
            EventTypeSpec(eventClass: OSType(kEventClassMenu), eventKind: UInt32(kEventMenuBarShown)),
            EventTypeSpec(eventClass: OSType(kEventClassMenu), eventKind: UInt32(kEventMenuBarHidden)),
        ]
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                let observer = Unmanaged<NativeMenuBarVisibilityObserver>
                    .fromOpaque(context).takeUnretainedValue()
                switch GetEventKind(event) {
                case UInt32(kEventMenuBarShown): observer.onChange(true)
                case UInt32(kEventMenuBarHidden): observer.onChange(false)
                default: break
                }
                // Keep delivery available to AppKit and other registered handlers.
                return OSStatus(eventNotHandledErr)
            },
            events.count, &events,
            Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        if status != noErr {
            NSLog("Unable to observe native menu-bar visibility (%d)", status)
        }
    }

    deinit {
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
