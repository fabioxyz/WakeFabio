import XCTest
import AVFoundation
@testable import WakeFabio

final class AlarmSoundTests: XCTestCase {
    func testEverySelectableToneIsBundledPlayableAndShort() throws {
        var fingerprints = Set<Data>()
        for sound in AlarmSoundCatalog.sounds {
            let url = try XCTUnwrap(AlarmSoundCatalog.url(for: sound.name))
            let player = try AVAudioPlayer(contentsOf: url)
            XCTAssertGreaterThan(player.duration, 0.1)
            XCTAssertLessThan(player.duration, 30)
            let audio = try AVAudioFile(forReading: url)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
            try audio.read(into: buffer)
            let channel = try XCTUnwrap(buffer.floatChannelData?[0])
            XCTAssertTrue((0..<Int(buffer.frameLength)).contains { abs(channel[$0]) > 0.01 }, "Tone must not be silent")
            fingerprints.insert(try Data(contentsOf: url))
        }
        XCTAssertEqual(fingerprints.count, AlarmSoundCatalog.sounds.count)
    }

    func testLegacyAndUnknownSoundNamesResolveToBundledTones() {
        for name in ["loud1.mp3", "loud2.mp3", "analog_alarm.mp3", "digital_alarm.mp3", "morning_park.mp3", "rooster.mp3", "siren.mp3", "unknown"] {
            XCTAssertNotNil(AlarmSoundCatalog.url(for: name), name)
        }
        XCTAssertEqual(AlarmSoundCatalog.resolvedName("siren.mp3"), "wake_siren.wav")
        XCTAssertEqual(AlarmSoundCatalog.resolvedName("wake_chime.wav"), "wake_chime.wav")
    }
}
