import AppKit
import Testing
@testable import Browser

/// A page edge with a short wait, whose snapshots are counted and all find `painted`.
@MainActor private final class Fixture {
    let painted = NSColor(srgbRed: 0, green: 0, blue: 0.25, alpha: 1)
    var snapshots = 0
    var isLoading = false
    private(set) lazy var edge = PageEdge(
        delay: 0.03, isLoading: { [unowned self] in isLoading }, isShown: { true },
        snapshot: { [unowned self] done in
            snapshots += 1; done(painted)
        }, onChange: {})

    func wait(_ seconds: Double = 0.15) async { try? await Task.sleep(for: .seconds(seconds)) }
}

@MainActor @Test func aColorFromStylesIsShownAndCallsOffTheSnapshot() async {
    let fixture = Fixture()
    fixture.edge.report("unknown:1")
    fixture.edge.report("10,20,30")
    await fixture.wait()
    #expect(fixture.snapshots == 0)
    #expect(fixture.edge.color == NSColor(srgbRed: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1))
}

@MainActor @Test func aPaintedElementIsSnapshottedOnceAndRememberedWhenItReturns() async {
    let fixture = Fixture()
    fixture.edge.report("unknown:1")
    await fixture.wait()
    fixture.edge.report("page")
    #expect(fixture.edge.color == nil)

    fixture.edge.report("unknown:1")
    #expect(fixture.edge.color == fixture.painted)
    await fixture.wait()
    #expect(fixture.snapshots == 1)
}

@MainActor @Test func repeatedReportsDoNotPostponeTheSnapshot() async {
    let fixture = Fixture()
    for _ in 0..<20 {
        fixture.edge.report("unknown:1")
        await fixture.wait(0.01)
    }
    #expect(fixture.snapshots == 1)
}

@MainActor @Test func noSnapshotIsTakenWhileThePageLoads() async {
    let fixture = Fixture()
    fixture.isLoading = true
    fixture.edge.report("unknown:1")
    await fixture.wait()
    #expect(fixture.snapshots == 0)

    fixture.isLoading = false
    await fixture.wait()
    #expect(fixture.snapshots == 1)
}

@MainActor @Test func aNewLookOfTheSameElementIsSnapshottedAgain() async {
    let fixture = Fixture()
    fixture.edge.report("unknown:1:clear")
    await fixture.wait()
    fixture.edge.report("unknown:1:solid")
    await fixture.wait()
    #expect(fixture.snapshots == 2)
}

@MainActor @Test func snapshotsPerPageAreCapped() async {
    let fixture = Fixture()
    for look in 0..<(PageEdge.maxSnapshots + 3) {
        fixture.edge.report("unknown:1:\(look)")
        await fixture.wait(0.08)
    }
    #expect(fixture.snapshots == PageEdge.maxSnapshots)
}

@MainActor @Test func aNewPageHoldsTheLastColorUntilItReportsOrTheHoldRunsOut() async {
    let fixture = Fixture()
    fixture.edge.report("10,20,30")
    fixture.edge.reset(holding: 2)
    #expect(fixture.edge.isWaiting && fixture.edge.color != nil)
    fixture.edge.report("page")
    #expect(!fixture.edge.isWaiting && fixture.edge.color == nil)

    fixture.edge.report("10,20,30")
    fixture.edge.reset(holding: 0.03)
    await fixture.wait()
    #expect(!fixture.edge.isWaiting && fixture.edge.color == nil)
}

@MainActor @Test func aFadingHeaderReportsTheFadeItMakes() {
    let fixture = Fixture()
    fixture.edge.report("0,0,0~300,cubic-bezier(0.4, 0, 0.2, 1)")
    #expect(fixture.edge.color == NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    #expect(fixture.edge.fade?.duration == 0.3)
    var first: [Float] = [0, 0]
    fixture.edge.fade?.curve.getControlPoint(at: 1, values: &first)
    #expect(first == [0.4, 0])
    #expect(fixture.edge.isFromStyles)

    fixture.edge.report("255,255,255")
    #expect(fixture.edge.fade == nil)
    fixture.edge.report("unknown:1:look")
    #expect(!fixture.edge.isFromStyles)
}
