import XCTest
import VibeWaveCore

final class UserEqualizerPresetTests: XCTestCase {
    func testFileRoundTripPreservesPresetAndEnablesEqualizer() throws {
        let gains: [Float] = [-12, -6, 0, 6, 12, 3.25, -4, 0, 1, 2]
        let settings = EqualizerSettings(enabled: false, preamp: -4.5, gains: gains)
        let preset = try UserEqualizerPreset(name: "  Мой EQ  ", settings: settings)
        let decoded = try EqualizerPresetFile.decode(EqualizerPresetFile.encode(preset))

        XCTAssertEqual(decoded, preset)
        XCTAssertEqual(decoded.name, "Мой EQ")
        XCTAssertEqual(decoded.settings, EqualizerSettings(enabled: true, preamp: -4.5, gains: gains))
        XCTAssertEqual(try decoded.renamed("Вечер").id, preset.id)
    }

    func testFileRejectsWrongVersionAndInvalidValues() throws {
        let preset = try UserEqualizerPreset(name: "Тест", settings: .init())
        let encoded = try EqualizerPresetFile.encode(preset)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        document["version"] = 2
        XCTAssertThrowsError(try EqualizerPresetFile.decode(JSONSerialization.data(withJSONObject: document))) {
            XCTAssertEqual($0 as? UserEqualizerPresetError, .unsupportedVersion)
        }

        document["version"] = 1
        var invalidPreset = try XCTUnwrap(document["preset"] as? [String: Any])
        invalidPreset["preamp"] = 12.1
        document["preset"] = invalidPreset
        XCTAssertThrowsError(try EqualizerPresetFile.decode(JSONSerialization.data(withJSONObject: document))) {
            XCTAssertEqual($0 as? UserEqualizerPresetError, .invalidValues)
        }

        invalidPreset["preamp"] = 0
        invalidPreset["gains"] = Array(repeating: 0, count: 9)
        document["preset"] = invalidPreset
        XCTAssertThrowsError(try EqualizerPresetFile.decode(JSONSerialization.data(withJSONObject: document))) {
            XCTAssertEqual($0 as? UserEqualizerPresetError, .invalidValues)
        }
    }

    func testFileRejectsDamagedAndOversizedData() {
        XCTAssertThrowsError(try EqualizerPresetFile.decode(Data("broken".utf8))) {
            XCTAssertEqual($0 as? UserEqualizerPresetError, .invalidFile)
        }
        let oversizedData = Data(count: EqualizerPresetFile.maximumSize + 1)
        XCTAssertThrowsError(try EqualizerPresetFile.decode(oversizedData)) {
            XCTAssertEqual($0 as? UserEqualizerPresetError, .fileTooLarge)
        }
    }

    func testPresetRejectsInvalidNames() {
        let invalidNames = ["  ", "EQ\nPreset", String(repeating: "a", count: 65)]
        for name in invalidNames {
            XCTAssertThrowsError(try UserEqualizerPreset(name: name, settings: .init())) {
                XCTAssertEqual($0 as? UserEqualizerPresetError, .invalidName)
            }
        }
    }
}
