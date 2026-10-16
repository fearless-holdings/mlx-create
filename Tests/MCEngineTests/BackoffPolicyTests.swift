import Testing
@testable import MCEngine

@Suite struct BackoffPolicyTests {
    @Test func firstThreeRestartsUseOneFourSixteenSecondDelays() {
        var budget = RestartBudget()
        #expect(budget.nextRestart(at: 0) == .after(.seconds(1)))
        #expect(budget.nextRestart(at: 10) == .after(.seconds(4)))
        #expect(budget.nextRestart(at: 20) == .after(.seconds(16)))
    }

    @Test func fourthCrashInFiveMinutesExhaustsTheBudget() {
        var budget = RestartBudget()
        _ = budget.nextRestart(at: 0)
        _ = budget.nextRestart(at: 10)
        _ = budget.nextRestart(at: 20)
        #expect(budget.nextRestart(at: 30) == .exhausted)
    }

    @Test func windowSlidesSoOldRestartsStopCounting() {
        var budget = RestartBudget()
        _ = budget.nextRestart(at: 0)
        _ = budget.nextRestart(at: 10)
        _ = budget.nextRestart(at: 20)
        // 0 and 10 are 300+ s old by t=311; only t=20 remains in the window.
        #expect(budget.nextRestart(at: 311) == .after(.seconds(4)))
    }

    @Test func readyForFiveMinutesClearsTheWindow() {
        var budget = RestartBudget()
        _ = budget.nextRestart(at: 0)
        _ = budget.nextRestart(at: 1)
        _ = budget.nextRestart(at: 2)
        budget.noteReady(at: 3)
        // Crash at t=303: ready since t=3, i.e. 300 s of stable running, so the budget is fresh.
        #expect(budget.nextRestart(at: 303) == .after(.seconds(1)))
    }

    @Test func crashWithinFiveMinutesOfReadyDoesNotClearTheWindow() {
        var budget = RestartBudget()
        _ = budget.nextRestart(at: 0)
        _ = budget.nextRestart(at: 1)
        _ = budget.nextRestart(at: 2)
        budget.noteReady(at: 3)
        #expect(budget.nextRestart(at: 10) == .exhausted)
    }

    @Test func userResetClearsTheBudgetImmediately() {
        var budget = RestartBudget()
        _ = budget.nextRestart(at: 0)
        _ = budget.nextRestart(at: 1)
        _ = budget.nextRestart(at: 2)
        #expect(budget.nextRestart(at: 3) == .exhausted)
        budget.reset()
        #expect(budget.nextRestart(at: 4) == .after(.seconds(1)))
    }
}
