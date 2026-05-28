import Foundation
import XCTest
@testable import SmooothCore

/// Decodes the golden vectors dumped from the JS reference
/// (macos/scripts/dump-reference-vectors.mjs → Fixtures/vectors.json).
struct Vectors: Decodable {
    struct EasingSample: Decodable { let curve: String; let t: Double; let value: Double }

    struct ZTSample: Decodable {
        let t: Double; let scale: Double; let translateX: Double; let translateY: Double; let transformOrigin: String
    }
    struct ZoomTransformV: Decodable {
        let metadata: [MetaDataItem]
        let geometry: SizeD
        let frame: SizeD
        let regions: [String: ZoomRegion]
        let samples: [ZTSample]
    }

    struct TRSample: Decodable { let exportTime: Double; let sourceTime: Double }
    struct TimeRemapV: Decodable {
        let duration: Double
        let cuts: [String: CutRegion]
        let speeds: [String: SpeedRegion]
        let exportDuration: Double
        let samples: [TRSample]
    }
    struct TimeRemapPassV: Decodable { let duration: Double; let samples: [TRSample] }

    struct ExpectedRegion: Decodable {
        let startTime: Double; let duration: Double; let zoomLevel: Double; let easing: String
        let transitionDuration: Double; let targetX: Double; let targetY: Double; let mode: String
    }
    struct AutoZoomV: Decodable {
        let metadata: [MetaDataItem]; let geometry: SizeD; let duration: Double; let regions: [ExpectedRegion]
    }
    struct AutoZoomSynthV: Decodable {
        let metadata: [MetaDataItem]; let synthesizedClicks: [MetaDataItem]
        let geometry: SizeD; let duration: Double; let regions: [ExpectedRegion]
    }

    struct WebcamRectEntry: Decodable { let pos: WebcamPos; let rect: RectD }
    struct RulerEntry: Decodable { let pps: Double; let major: Double; let minor: Double }
    struct ExportDimEntry: Decodable { let resolution: String; let aspectRatio: AspectRatio; let width: Int; let height: Int }
    struct ColorEntry: Decodable { let input: String; let hex: String; let alpha: Double }
    struct GeometryV: Decodable {
        let webcamRects: [WebcamRectEntry]; let ruler: [RulerEntry]
        let exportDims: [ExportDimEntry]; let colors: [ColorEntry]
    }

    let easing: [EasingSample]
    let zoomTransform: ZoomTransformV
    let timeRemap: TimeRemapV
    let timeRemapPassthrough: TimeRemapPassV
    let autoZoom: AutoZoomV
    let autoZoomSynth: AutoZoomSynthV
    let geometry: GeometryV
}

enum TestVectors {
    static func load() throws -> Vectors {
        guard let url = Bundle.module.url(forResource: "vectors", withExtension: "json") else {
            throw NSError(domain: "TestVectors", code: 1, userInfo: [NSLocalizedDescriptionKey: "vectors.json not found in test bundle"])
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Vectors.self, from: data)
    }
}

/// Parses a JS transform-origin string ("60% 55%") into 0...1 fractions.
func parseTransformOrigin(_ s: String) -> (x: Double, y: Double) {
    let parts = s.split(separator: " ")
    func frac(_ token: Substring) -> Double {
        (Double(token.replacingOccurrences(of: "%", with: "")) ?? 0) / 100
    }
    return (frac(parts[0]), frac(parts[1]))
}
