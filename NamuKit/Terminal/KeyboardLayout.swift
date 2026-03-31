import Carbon
import Foundation

/// Utility to detect keyboard input source changes during IME composition.
enum KeyboardLayout {
    /// Returns a stable identifier for the current keyboard input source.
    /// Used to detect layout changes mid-composition (e.g., switching from
    /// Korean to English while composing).
    static var id: String {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return ""
        }
        return Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
    }
}
