import Foundation
import Testing
@testable import FrameCompare

struct SceneTests {
    func scene(_ languages: [String]?) -> RecordingMetadata.Scene {
        .init(appearance: "light", languages: languages, reduceTransparency: false, reduceMotion: false, increaseContrast: false)
    }

    @Test func sameLanguagesDoNotDiffer() {
        #expect(scene(["zh-Hans-US", "en-US"]).differences(from: scene(["zh-Hans-US", "en-US"])).isEmpty)
    }

    @Test func languageOrderMatters() {
        let names = scene(["zh-Hans-US", "en-US"]).differences(from: scene(["en-US", "zh-Hans-US"]))
        #expect(names.count == 1)
        #expect(names[0].hasPrefix("languages"))
    }

    @Test func missingLanguagesDifferFromRecordedOnes() {
        let names = scene(nil).differences(from: scene(["zh-Hans-US", "en-US"]))
        #expect(names == ["languages (not recorded vs zh-Hans-US, en-US)"])
    }

    @Test func metadataWithoutLanguagesDecodes() throws {
        // A sidecar written before the languages field existed.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata(frameTimes: [0, 1.1]))) as! [String: Any]
        var sceneJSON = json["scene"] as! [String: Any]
        sceneJSON.removeValue(forKey: "languages")
        json["scene"] = sceneJSON
        let decoded = try JSONDecoder().decode(RecordingMetadata.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.scene.languages == nil)
        #expect(decoded.scene.languagesDescription == "not recorded")
    }

    @Test func comparisonRefusesDifferentLanguages() throws {
        let a = animation(start: 1.1, levels: [10])
        let b = recording(a.frames, metadata(frameTimes: a.metadata.frameTimes, languages: ["en-US"]))
        let old = recording(a.frames, metadata(frameTimes: a.metadata.frameTimes, languages: nil))
        let loose = CompareParameters(pixelThreshold: 0, maxRatio: 0, masks: [])
        for other in [b, old] {
            #expect(throws: InvalidInput.self) { try Comparison.compare(a, other, parameters: loose) }
            #expect(throws: InvalidInput.self) { try Comparison.still(a, other, parameters: loose) }
        }
    }
}
