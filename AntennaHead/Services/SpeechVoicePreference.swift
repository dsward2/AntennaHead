import AVFoundation
import Foundation
import SharedLogging

/// The single place that decides which synthesized voice each spoken feature
/// uses, so the Configuration "Speech" section means what it says.
///
/// Every feature resolves its voice the same way:
///
///   1. the feature's own override, if one is chosen and still installed;
///   2. otherwise the **default voice**, if one is chosen and still installed;
///   3. otherwise **Automatic**: the best installed voice for the user's
///      language (Premium, then Enhanced).
///
/// Automatic is chosen explicitly and passed to `PCMSpeechSynth` as `--voice`.
/// Leaving the voice out is not an option worth having: with no `--voice` the
/// synthesizer falls back to its built-in default, which on a typical Mac is
/// the compact (lowest-quality) Samantha voice, not the voice picked in System
/// Settings and not any Premium voice that is installed.
///
/// A voice named inside the spoken text itself overrides all of this: an SSML
/// `<voice name="…">` tag (filler announcement with SSML enabled) wins over
/// `--voice`. The classic `[[…]]` embedded commands are not honored by the
/// modern voices; they are read aloud.
enum SpeechVoicePreference {
    /// App-settings key for the default voice. Empty / absent ⇒ Automatic.
    static let defaultVoiceKey = "AntennaHeadSpeechDefaultVoiceIdentifier"
    /// App-settings key for the Text to Speech page's own voice override.
    static let textToSpeechVoiceKey = "AntennaHeadTextToSpeechVoiceIdentifier"

    /// The installed voice with this identifier, or `nil` when `id` is empty
    /// or the voice is no longer installed (`PCMSpeechSynth` aborts on an
    /// unknown identifier).
    static func installedVoice(_ id: String?) -> AVSpeechSynthesisVoice? {
        guard let id, !id.isEmpty else { return nil }
        return AVSpeechSynthesisVoice(identifier: id)
    }

    /// The best installed voice for the current language, or `nil` when none
    /// better than the built-in default is installed. Premium beats Enhanced,
    /// an exact region match (`en-US`) beats a sibling (`en-GB`), then name
    /// order keeps the choice stable. The novelty voices (Bells, Trinoids, …)
    /// and Eloquence voices are never picked automatically.
    static func automaticVoice() -> AVSpeechSynthesisVoice? {
        let current = AVSpeechSynthesisVoice.currentLanguageCode()
        let language = current.split(separator: "-").first.map(String.init) ?? current
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { voice in
            voice.language.hasPrefix(language)
                && voice.quality != .default
                && !voice.identifier.hasPrefix("com.apple.speech.synthesis.voice.")
                && !voice.identifier.hasPrefix("com.apple.eloquence.")
        }
        func score(_ voice: AVSpeechSynthesisVoice) -> Int {
            (voice.quality == .premium ? 2 : 1) + (voice.language == current ? 10 : 0)
        }
        return candidates.sorted {
            (score($0), $1.name) > (score($1), $0.name)
        }.first
    }

    /// The identifier a feature should pass to `PCMSpeechSynth --voice`.
    /// `overrideKey` is the feature's own setting (`nil` for "no override").
    static func resolvedIdentifier(overrideKey: String?, sqlite: SQLiteController) -> String? {
        func stored(_ key: String) -> String? {
            let value = (try? sqlite.appSettingsValue(forKey: key)) ?? nil
            return (value?.isEmpty ?? true) ? nil : value
        }
        for key in [overrideKey, defaultVoiceKey].compactMap({ $0 }) {
            guard let id = stored(key) else { continue }
            if installedVoice(id) != nil { return id }
            LogStore.shared.log(.info, source: "SpeechVoicePreference",
                                "saved voice '\(id)' (\(key)) is not installed; falling back")
        }
        return automaticVoice()?.identifier
    }

    /// The voice to use right now for a picker's *unsaved* selections — the
    /// Configuration previews speak what the user is looking at, not what was
    /// last stored. `overrideID` and `defaultID` are picker values (`""` ⇒
    /// "same as default" / "Automatic").
    static func effectiveVoice(overrideID: String, defaultID: String) -> AVSpeechSynthesisVoice? {
        installedVoice(overrideID) ?? installedVoice(defaultID) ?? automaticVoice()
    }
}
