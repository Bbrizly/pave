import XCTest
@testable import PaveKit

final class MockRunner: StepRunner {
    var ran: [Step] = []
    var failAtIndex: Int?

    func run(_ step: Step) throws {
        if case .delay(let ms) = step {
            Thread.sleep(forTimeInterval: Double(ms) / 1000)
        }
        ran.append(step)
        if let f = failAtIndex, ran.count - 1 == f {
            throw RunError("boom")
        }
    }
}

final class ExecutorTests: XCTestCase {
    func testStepsRunInOrder() {
        let runner = MockRunner()
        let macro = Macro(name: "M", steps: [
            .open(target: "a"), .open(target: "b"), .open(target: "c"),
        ])
        let done = expectation(description: "done")
        Executor().run(macro, with: runner) { result in
            if case .failure = result { XCTFail("should succeed") }
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(runner.ran, macro.steps)
    }

    func testFailureStopsAndReportsIndex() {
        let runner = MockRunner()
        runner.failAtIndex = 1
        let macro = Macro(name: "M", steps: [
            .open(target: "a"), .open(target: "b"), .open(target: "c"),
        ])
        let done = expectation(description: "done")
        Executor().run(macro, with: runner) { result in
            guard case .failure(.failed(let i, let reason)) = result else {
                XCTFail("expected failure"); done.fulfill(); return
            }
            XCTAssertEqual(i, 1)
            XCTAssertTrue(reason.contains("boom"))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(runner.ran.count, 2) // stopped, no step 3
    }

    func testUnknownStepFails() {
        let macro = Macro(name: "M", steps: [.unknown(type: "teleport")])
        let done = expectation(description: "done")
        Executor().run(macro, with: MockRunner()) { result in
            guard case .failure(.failed(_, let reason)) = result else {
                XCTFail("expected failure"); done.fulfill(); return
            }
            XCTAssertTrue(reason.contains("teleport"))
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }

    func testBusyRejectsSecondFire() {
        let executor = Executor()
        let slow = Macro(name: "Slow", steps: [.delay(ms: 300)])
        let firstDone = expectation(description: "first")
        executor.run(slow, with: MockRunner()) { _ in firstDone.fulfill() }

        let busyDone = expectation(description: "busy")
        let accepted = executor.run(slow, with: MockRunner()) { result in
            guard case .failure(.busy) = result else {
                XCTFail("expected busy"); busyDone.fulfill(); return
            }
            busyDone.fulfill()
        }
        XCTAssertFalse(accepted)
        wait(for: [busyDone, firstDone], timeout: 2)
    }

    func testRuntimeCapKillsBetweenSteps() {
        let executor = Executor()
        executor.maxRuntime = 0.05
        let macro = Macro(name: "M", steps: [.delay(ms: 120), .delay(ms: 10)])
        let done = expectation(description: "done")
        executor.run(macro, with: MockRunner()) { result in
            guard case .failure(.timedOut(let i)) = result else {
                XCTFail("expected timeout"); done.fulfill(); return
            }
            XCTAssertEqual(i, 1)
            done.fulfill()
        }
        wait(for: [done], timeout: 2)
    }
}
