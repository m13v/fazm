import Foundation
import NaturalLanguage

/// Routes TTS output to a language-appropriate voice.
///
/// Deepgram Aura is preferred for en, es, fr, de, it, nl, ja (cheaper, faster).
/// Everything else (Russian, Chinese, Korean, Portuguese, Arabic, Hindi,
/// Polish, Ukrainian, etc.) routes to ElevenLabs `eleven_multilingual_v2`,
/// which handles 29 languages with a single voice ID. Languages outside
/// both providers resolve to `.unsupported` and the speak tool stays silent;
/// macOS system TTS is intentionally not used as a fallback.
///
/// Anti-thrash: a "sticky" detected language is held in UserDefaults across
/// utterances. The voice only flips when the new utterance is both long
/// (>=30 chars after stripping code/URLs) and detected with confidence >=0.85.
/// Short or ambiguous utterances reuse the sticky language, so a one-word
/// reply ("OK") never changes the voice mid-conversation.
enum VoiceLanguageRouter {
    enum Mode: String {
        case auto
        case manual
    }

    enum Resolution {
        case deepgram(model: String, languageCode: String)
        case elevenlabs(voiceId: String, languageCode: String)
        case unsupported(languageCode: String)
    }

    static let stickyLangKey = "voiceResponseStickyLang"
    static let modeKey = "voiceResponseLanguageMode"
    static let overrideKey = "voiceResponseLanguageOverride"

    /// Deepgram Aura model selected per language (one warm female-leaning voice each
    /// to stay close to the existing Luna character).
    static let deepgramVoices: [String: String] = [
        "en": "aura-luna-en",
        "es": "aura-2-estrella-es",
        "fr": "aura-2-agathe-fr",
        "de": "aura-2-viktoria-de",
        "it": "aura-2-livia-it",
        "nl": "aura-2-rhea-nl",
        "ja": "aura-2-izanami-ja",
    ]

    /// Default ElevenLabs voice. Used across every supported language so users
    /// hear the same character no matter what language the response is in.
    /// User-selected from the ElevenLabs voice library on 2026-04-30.
    static let elevenLabsDefaultVoiceId = "EST9Ui6982FZPSi7gCHi"
    static let elevenLabsModelId = "eleven_multilingual_v2"

    /// Languages eleven_multilingual_v2 covers natively. Anything outside this
    /// set falls back to AVSpeechSynthesizer.
    static let elevenLabsLanguages: Set<String> = [
        "en", "es", "fr", "de", "it", "nl", "ja",
        "ru", "zh", "ko", "pt", "ar", "hi", "tr", "pl", "uk",
        "th", "vi", "id", "he", "sv", "da", "fi", "no", "cs",
        "el", "ro", "hu", "sk", "ms", "bg", "hr", "ta", "fil",
    ]

    /// Languages exposed in the Settings picker. All listed languages are
    /// high-quality TTS (Deepgram or ElevenLabs); the system fallback is
    /// transparent and never user-facing.
    static let pickerLanguages: [(code: String, label: String)] = [
        ("en", "English"),
        ("es", "Spanish"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("nl", "Dutch"),
        ("ja", "Japanese"),
        ("ru", "Russian"),
        ("zh", "Chinese"),
        ("ko", "Korean"),
        ("pt", "Portuguese"),
        ("ar", "Arabic"),
        ("hi", "Hindi"),
        ("tr", "Turkish"),
        ("pl", "Polish"),
        ("uk", "Ukrainian"),
    ]

    /// Resolve the best voice for the given text. Updates sticky state as a side effect.
    static func resolve(forText text: String) -> Resolution {
        let mode = UserDefaults.standard.string(forKey: modeKey).flatMap(Mode.init(rawValue:)) ?? .auto
        let code: String
        switch mode {
        case .manual:
            code = UserDefaults.standard.string(forKey: overrideKey) ?? "en"
        case .auto:
            code = autoDetect(text)
        }
        return mapToVoice(languageCode: code)
    }

    /// Reset sticky lang. Called when the user starts a new chat so the first
    /// utterance of the next chat redetects fresh instead of carrying over.
    static func resetSticky() {
        UserDefaults.standard.removeObject(forKey: stickyLangKey)
    }

    // MARK: - Detection

    private static func autoDetect(_ text: String) -> String {
        let sticky = UserDefaults.standard.string(forKey: stickyLangKey) ?? "en"
        let prose = strippedProse(text)
        // Short text is unreliable — keep current voice.
        guard prose.count >= 30 else { return sticky }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let dominant = recognizer.dominantLanguage else { return sticky }

        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        let confidence = hypotheses[dominant] ?? 0
        guard confidence >= 0.85 else { return sticky }

        let normalized = normalize(dominant.rawValue)
        if normalized != sticky {
            UserDefaults.standard.set(normalized, forKey: stickyLangKey)
        }
        return normalized
    }

    /// Strip code fences, inline code, and URLs so detection runs on prose only.
    private static func strippedProse(_ text: String) -> String {
        var t = text
        let patterns = [
            "```[\\s\\S]*?```",
            "`[^`]*`",
            "https?://\\S+",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            t = regex.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: " ")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// NLLanguage codes can include script/region tags ("zh-Hans", "pt-BR").
    /// We key our maps on the primary subtag.
    private static func normalize(_ code: String) -> String {
        let primary = code.split(separator: "-").first.map(String.init) ?? code
        return primary.lowercased()
    }

    // MARK: - Voice selection

    private static func mapToVoice(languageCode: String) -> Resolution {
        if elevenLabsLanguages.contains(languageCode) {
            return .elevenlabs(voiceId: elevenLabsDefaultVoiceId, languageCode: languageCode)
        }
        if let model = deepgramVoices[languageCode] {
            return .deepgram(model: model, languageCode: languageCode)
        }
        return .unsupported(languageCode: languageCode)
    }
}
