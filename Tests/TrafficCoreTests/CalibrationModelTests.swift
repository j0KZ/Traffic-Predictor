import XCTest
@testable import TrafficCore

final class CalibrationModelTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_758_000_000)
    private let peak = BandKey(band: .puntaManana, weekend: false)
    private let noon = BandKey(band: .mediodia, weekend: false)

    private func pair(_ p: ProviderID, _ route: String, _ band: BandKey, sample: Int, ref: Int, minute: Double) -> TaggedPair {
        TaggedPair(provider: p, route: route, band: band,
                   pair: .init(sample: sample, reference: ref, at: base.addingTimeInterval(minute * 60)))
    }

    func testNoEvidenceMeansNoCorrection() {
        let model = CalibrationModel(pairs: [])
        XCTAssertEqual(model.factor(provider: .tomtom, route: "x", band: peak), 1, accuracy: 1e-9)
    }

    func testFewPairsCorrectLessThanManyPairs() {
        // TomTom marca el doble que Waze. Con 1 par corrige poco; con 20, casi todo.
        let one = CalibrationModel(pairs: [pair(.tomtom, "tlv", peak, sample: 2000, ref: 1000, minute: 0)])
        let many = CalibrationModel(pairs: (0..<20).map { pair(.tomtom, "tlv", peak, sample: 2000, ref: 1000, minute: Double($0) * 5) })

        let fOne = one.factor(provider: .tomtom, route: "tlv", band: peak)
        let fMany = many.factor(provider: .tomtom, route: "tlv", band: peak)
        XCTAssertGreaterThan(fOne, fMany, "con un par se corrige menos")
        XCTAssertLessThan(fOne, 1)
        XCTAssertEqual(fMany, 0.5, accuracy: 0.1)
    }

    func testOtherCitiesDoNotTransfer() {
        // Lo aprendido en Tel Aviv no se aplica a Estambul: el sesgo es local.
        let model = CalibrationModel(pairs: (0..<12).map { pair(.tomtom, "tlv", peak, sample: 1400, ref: 1000, minute: Double($0) * 5) })
        XCTAssertEqual(model.factor(provider: .tomtom, route: "ist", band: peak), 1, accuracy: 1e-9)
    }

    func testSameRouteOtherBandIsTheFallback() {
        // Sin lecturas de mediodía, la ruta usa su propio factor de la punta.
        let model = CalibrationModel(pairs: (0..<4).map { pair(.mapbox, "cl", peak, sample: 1000, ref: 1100, minute: Double($0) * 5) })
        XCTAssertEqual(model.factor(provider: .mapbox, route: "cl", band: noon), 1.1, accuracy: 0.02)
    }

    func testOneReadingAlreadyCorrectsMost() {
        let model = CalibrationModel(pairs: [pair(.mapbox, "cl", peak, sample: 1000, ref: 1200, minute: 0)])
        XCTAssertEqual(model.factor(provider: .mapbox, route: "cl", band: peak), 1.2, accuracy: 0.05)
    }

    func testBlendFavorsTheSourceThatHasBeenRight() {
        // Mapbox acierta con ruido chico, TomTom falla con ruido grande.
        var pairs: [TaggedPair] = []
        for i in 0..<10 {
            let noise = i.isMultiple(of: 2) ? 1.3 : 0.7
            pairs.append(pair(.tomtom, "r", peak, sample: Int(1000 * noise), ref: 1000, minute: Double(i) * 5))
            pairs.append(pair(.mapbox, "r", peak, sample: 1000 + (i.isMultiple(of: 2) ? 10 : -10), ref: 1000, minute: Double(i) * 5))
        }
        let model = CalibrationModel(pairs: pairs)
        let predicted = model.predict(samples: [.tomtom: 1400, .mapbox: 1000], route: "r", band: peak)
        XCTAssertEqual(Double(predicted ?? 0), 1000, accuracy: 80, "debe quedar cerca de la fuente confiable")
    }

    func testLeaveOneOutBeatsRawWhenBiasIsConsistent() throws {
        // Sesgo estable: TomTom +40%, Mapbox -10%. Calibrar debe ganar.
        var pairs: [TaggedPair] = []
        for i in 0..<12 {
            let ref = 1000 + i * 20
            pairs.append(pair(.tomtom, "r", peak, sample: Int(Double(ref) * 1.4), ref: ref, minute: Double(i) * 5))
            pairs.append(pair(.mapbox, "r", peak, sample: Int(Double(ref) * 0.9), ref: ref, minute: Double(i) * 5))
        }
        let result = try XCTUnwrap(CalibrationEvaluation.leaveOneOut(pairs))
        XCTAssertEqual(result.readings, 12)
        XCTAssertLessThan(result.calibratedError, result.rawMedianError)
        XCTAssertLessThan(result.calibratedError, result.rawError[.mapbox] ?? 1)
    }

    func testLeaveOneOutNeedsTwoReadings() {
        XCTAssertNil(CalibrationEvaluation.leaveOneOut([pair(.tomtom, "r", peak, sample: 1, ref: 1, minute: 0)]))
    }

    func testForwardInTimeUsesOnlyThePast() {
        // Sesgo estable: Mapbox marca 20% menos que Waze. Prediciendo hacia
        // adelante debe aprenderlo y ganarle a la fuente cruda.
        var pairs: [TaggedPair] = []
        for i in 0..<10 {
            pairs.append(pair(.mapbox, "r", peak, sample: 800, ref: 1000, minute: Double(i) * 60))
        }
        let result = try! XCTUnwrap(CalibrationEvaluation.forwardInTime(pairs))
        XCTAssertEqual(result.readings, 9, "la primera no se puede predecir: no hay pasado")
        XCTAssertLessThan(result.calibratedError, result.rawError[.mapbox] ?? 1)
    }

    func testForwardInTimeSkipsRoutesWithoutHistory() {
        // Cada lectura es de otra ruta: nunca hay pasado propio que usar.
        let pairs = (0..<4).map { pair(.mapbox, "r\($0)", peak, sample: 800, ref: 1000, minute: Double($0) * 60) }
        XCTAssertNil(CalibrationEvaluation.forwardInTime(pairs))
    }
}
