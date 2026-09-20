import XCTest
@testable import TrafficCore

final class DivergenceTests: XCTestCase {
    private func analyze(_ samples: [ETASample]) -> Divergence {
        DivergenceAnalyzer.analyze(Dictionary(uniqueKeysWithValues: samples.map { ($0.provider, $0) }))
    }

    func testConsensus() {
        let d = analyze([
            makeSample(.google, duration: 7900),
            makeSample(.tomtom, duration: 8040),
            makeSample(.here,   duration: 8080),
        ])
        XCTAssertEqual(d.verdict, .consensus)
        XCTAssertEqual(d.median, 8040)
        XCTAssertEqual(d.spreadSeconds, 180)
        XCTAssertNil(d.outlier, "con consenso no se señala a nadie")
    }

    func testMinorSpread() {
        let d = analyze([
            makeSample(.google, duration: 7200),
            makeSample(.tomtom, duration: 7800),
            makeSample(.here,   duration: 8000),
        ])
        XCTAssertEqual(d.verdict, .minorSpread)
        XCTAssertEqual(d.median, 7800)
    }

    func testMajorSpreadNamesTheOutlier() {
        // Google asume flujo libre donde no tiene datos: ese es el modo de falla.
        let d = analyze([
            makeSample(.google, duration: 6400),
            makeSample(.tomtom, duration: 9000),
            makeSample(.here,   duration: 9200),
        ])
        XCTAssertEqual(d.verdict, .majorSpread)
        XCTAssertEqual(d.median, 9000)
        XCTAssertEqual(d.outlier, .google)
        XCTAssertGreaterThan(d.spreadRatio, 0.20)
    }

    func testTwoSourcesStillProduceAVerdict() {
        let d = analyze([
            makeSample(.tomtom, duration: 8000),
            makeSample(.here,   duration: 8100),
        ])
        XCTAssertEqual(d.verdict, .consensus)
        // Con dos fuentes se toma la baja: la conservadora.
        XCTAssertEqual(d.median, 8000)
    }

    func testOneSourceIsInsufficient() {
        let d = analyze([makeSample(.google, duration: 8000)])
        XCTAssertEqual(d.verdict, .insufficient)
        XCTAssertEqual(d.median, 8000, "se reporta el único dato, pero sin pretender consenso")
    }

    func testZeroSourcesIsInsufficient() {
        let d = DivergenceAnalyzer.analyze([:])
        XCTAssertEqual(d.verdict, .insufficient)
        XCTAssertEqual(d.median, 0)
        XCTAssertNil(d.outlier)
    }

    func testCoastalRouteIsExcludedNotAveraged() {
        // Ruta 68 por la costa: ~120 km contra ~179 km de la Ruta 5.
        let d = analyze([
            makeSample(.google, duration: 6000, distance: 120_000),
            makeSample(.tomtom, duration: 9000, distance: 179_104),
            makeSample(.here,   duration: 9100, distance: 178_432),
        ])
        XCTAssertEqual(d.divergentRoutes, [.google])
        XCTAssertEqual(d.median, 9000, "la mediana no debe contaminarse con la otra ruta")
        XCTAssertEqual(d.verdict, .consensus, "las dos que sí van por Ruta 5 concuerdan")
    }

    func testWithTwoSourcesNobodyIsExcluded() {
        // Sin mayoría no hay forma de saber cuál es el corredor correcto.
        let d = analyze([
            makeSample(.google, duration: 6000, distance: 120_000),
            makeSample(.tomtom, duration: 9000, distance: 179_104),
        ])
        XCTAssertTrue(d.divergentRoutes.isEmpty)
        XCTAssertEqual(d.verdict, .majorSpread)
    }
}
