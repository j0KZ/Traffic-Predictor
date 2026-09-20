import XCTest
@testable import TrafficCore

final class RouteFilterTests: XCTestCase {
    /// Tramo recto de ~11 km sobre la Ruta 5, suficiente para medir ratios.
    private let route: String = {
        let points = (0...100).map { i in
            Coordinate(lat: -32.7870 + Double(i) * 0.001, lon: -71.1890)
        }
        return Polyline.encode(points)
    }()

    private func incident(_ id: String, lat: Double, lon: Double) -> TrafficIncident {
        TrafficIncident(id: id, category: .accident, description: "x",
                        location: Coordinate(lat: lat, lon: lon))
    }

    func testIncidentNearRouteIsKept() {
        // ~100 m al costado del trazado.
        let kept = RouteIncidentFilter.filter([incident("near", lat: -32.7420, lon: -71.1890)], onRoute: route)
        XCTAssertEqual(kept.count, 1)
        XCTAssertNotNil(kept[0].routeRatio)
    }

    func testIncidentFarFromRouteIsDiscarded() {
        // Valparaíso: en el bbox, pero no en tu camino.
        let kept = RouteIncidentFilter.filter([incident("far", lat: -33.0472, lon: -71.6127)], onRoute: route)
        XCTAssertTrue(kept.isEmpty)
    }

    func testRatioLocatesTheIncidentAlongTheRoute() {
        let atStart = incident("start", lat: -32.7870, lon: -71.1890)
        let atMiddle = incident("middle", lat: -32.7370, lon: -71.1890)
        let atEnd = incident("end", lat: -32.6870, lon: -71.1890)

        let kept = RouteIncidentFilter.filter([atEnd, atStart, atMiddle], onRoute: route)
        XCTAssertEqual(kept.map(\.id), ["start", "middle", "end"], "debe venir ordenado por posición")
        XCTAssertEqual(kept[0].routeRatio ?? -1, 0.0, accuracy: 0.05)
        XCTAssertEqual(kept[1].routeRatio ?? -1, 0.5, accuracy: 0.05)
        XCTAssertEqual(kept[2].routeRatio ?? -1, 1.0, accuracy: 0.05)
    }

    func testIncidentWithoutLocationIsDiscarded() {
        // Sin coordenadas no podemos afirmar que te afecte.
        let blind = TrafficIncident(id: "blind", category: .accident, description: "sin ubicación")
        XCTAssertTrue(RouteIncidentFilter.filter([blind], onRoute: route).isEmpty)
    }

    func testNilAndEmptyPolylineKeepNothing() {
        let some = [incident("a", lat: -32.7870, lon: -71.1890)]
        XCTAssertTrue(RouteIncidentFilter.filter(some, onRoute: nil).isEmpty)
        XCTAssertTrue(RouteIncidentFilter.filter(some, onRoute: "").isEmpty)
    }

    func testSubsampleKeepsEndpoints() {
        let points = (0...100).map { Coordinate(lat: -32.787 + Double($0) * 0.001, lon: -71.189) }
        let sampled = RouteIncidentFilter.subsample(points, spacingMeters: 500)
        XCTAssertLessThan(sampled.count, points.count)
        XCTAssertEqual(sampled.first, points.first)
        XCTAssertEqual(sampled.last, points.last, "el destino no se puede perder en el submuestreo")
    }

    func testHaversineAgainstAKnownDistance() {
        // Maitencillo a Las Condes en línea recta: ~105 km.
        let d = Geo.haversineMeters(
            Coordinate(lat: -32.6558, lon: -71.4390),
            Coordinate(lat: -33.4089, lon: -70.5680)
        )
        XCTAssertEqual(d, 110_000, accuracy: 8_000)
    }
}
