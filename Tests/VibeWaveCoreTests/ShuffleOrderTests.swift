import XCTest
@testable import VibeWaveCore

final class ShuffleOrderTests: XCTestCase {
    private let ids = (0..<6).map { _ in UUID() }

    func testCyclePlaysEveryTrackOnceThenStops() {
        var order = ShuffleOrder()
        order.reset(ids, startingAt: ids[0])
        var played = [ids[0]]
        var current = ids[0]
        while let next = order.advance(from: current, repeatingQueue: false) {
            played.append(next)
            current = next
        }
        XCTAssertEqual(played.count, ids.count)
        XCTAssertEqual(Set(played), Set(ids))
    }

    func testRetreatAndAdvanceReplayHistory() throws {
        var order = ShuffleOrder()
        order.reset(ids, startingAt: ids[0])
        let first = try XCTUnwrap(order.advance(from: ids[0], repeatingQueue: false))
        let second = try XCTUnwrap(order.advance(from: first, repeatingQueue: false))
        XCTAssertEqual(order.retreat(from: second), first)
        XCTAssertEqual(order.retreat(from: first), ids[0])
        XCTAssertNil(order.retreat(from: ids[0]))
        XCTAssertEqual(order.advance(from: ids[0], repeatingQueue: false), first)
        XCTAssertEqual(order.advance(from: first, repeatingQueue: false), second)
    }

    func testRepeatStartsNewCycleWithoutImmediateDuplicate() {
        var order = ShuffleOrder()
        order.reset(ids, startingAt: ids[0])
        var current = ids[0]
        while let next = order.advance(from: current, repeatingQueue: false) { current = next }
        for _ in 0..<20 {
            var copy = order
            XCTAssertNotEqual(copy.advance(from: current, repeatingQueue: true), current)
        }
    }

    func testUpdateDropsRemovedAndSchedulesAddedTracks() {
        var order = ShuffleOrder()
        order.reset(Array(ids.prefix(4)), startingAt: ids[0])
        let updated = [ids[0], ids[1], ids[4], ids[5]]
        order.update(updated, current: ids[0])
        var current = ids[0]
        var played: [UUID] = []
        while let next = order.advance(from: current, repeatingQueue: false) {
            played.append(next)
            current = next
        }
        XCTAssertEqual(Set(played), Set(updated).subtracting([ids[0]]))
    }

    func testCodableKeepsRemainingOrder() throws {
        var order = ShuffleOrder()
        order.reset(ids, startingAt: ids[0])
        _ = order.advance(from: ids[0], repeatingQueue: false)
        var restored = try JSONDecoder().decode(ShuffleOrder.self, from: JSONEncoder().encode(order))
        XCTAssertEqual(restored.next, order.next)
        var current = ids[0]
        while let expected = order.advance(from: current, repeatingQueue: false) {
            XCTAssertEqual(restored.advance(from: current, repeatingQueue: false), expected)
            current = expected
        }
    }
}
