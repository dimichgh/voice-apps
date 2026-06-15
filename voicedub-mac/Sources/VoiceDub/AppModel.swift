import Foundation
import SwiftUI

/// Shared, long-lived services for the whole app: the omlx client and a simple
/// WAV player. Held once at the root and passed into the tabs.
@MainActor
final class AppModel: ObservableObject {
    let client = OmlxClient()
    let player = AudioPlayer()

    /// Human-readable target languages offered for translation. "Off" means
    /// transcribe-and-redub in the original language (no translation hop).
    static let languages = [
        "Off (keep original)",
        "English", "Spanish", "French", "German", "Italian", "Portuguese",
        "Russian", "Japanese", "Korean", "Chinese (Mandarin)", "Hindi", "Arabic",
    ]
}
