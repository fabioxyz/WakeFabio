import Foundation

enum AlarmSoundCatalog {
    static let defaultName = "wake_beep.wav"
    static let sounds: [(name: String, title: String)] = [
        ("wake_beep.wav", "Bip rítmico"),
        ("wake_chime.wav", "Melodia suave"),
        ("wake_siren.wav", "Sirene")
    ]

    // Preserve existing alarms without requiring a data migration.
    static func resolvedName(_ storedName: String) -> String {
        if sounds.contains(where: { $0.name == storedName }) { return storedName }
        switch storedName {
        case "siren.mp3", "fire_alarm.mp3": return "wake_siren.wav"
        case "morning_park.mp3", "rooster.mp3", "sunshine.mp3": return "wake_chime.wav"
        default: return defaultName
        }
    }

    static func url(for storedName: String, bundle: Bundle = .main) -> URL? {
        let name = resolvedName(storedName) as NSString
        return bundle.url(forResource: name.deletingPathExtension, withExtension: name.pathExtension)
    }
}
