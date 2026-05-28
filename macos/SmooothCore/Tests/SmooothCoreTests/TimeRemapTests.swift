import XCTest
@testable import SmooothCore

final class TimeRemapTests: XCTestCase {
    func testMatchesJSReference() throws {
        let v = try TestVectors.load()
        let tr = v.timeRemap
        for s in tr.samples {
            let got = TimeRemap.mapExportTimeToSourceTime(s.exportTime, duration: tr.duration,
                                                          cutRegions: tr.cuts, speedRegions: tr.speeds)
            XCTAssertEqual(got, s.sourceTime, accuracy: 1e-9, "export=\(s.exportTime)")
        }
    }

    func testExportDurationMatches() throws {
        let v = try TestVectors.load()
        let tr = v.timeRemap
        let got = TimeRemap.exportDuration(tr.duration, cutRegions: tr.cuts, speedRegions: tr.speeds)
        XCTAssertEqual(got, tr.exportDuration, accuracy: 1e-9)
    }

    func testPassthroughIsIdentity() throws {
        let v = try TestVectors.load()
        let p = v.timeRemapPassthrough
        for s in p.samples {
            let got = TimeRemap.mapExportTimeToSourceTime(s.exportTime, duration: p.duration,
                                                          cutRegions: [:], speedRegions: [:])
            XCTAssertEqual(got, s.sourceTime, accuracy: 1e-9, "export=\(s.exportTime)")
            XCTAssertEqual(got, s.exportTime, accuracy: 1e-9, "identity export=\(s.exportTime)")
        }
    }
}
