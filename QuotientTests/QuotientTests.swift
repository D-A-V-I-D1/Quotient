//
//  QuotientTests.swift
//  QuotientTests
//
//  App-level integration tests: the view models drive QuotientCore correctly.
//  Algorithm tests live in QuotientCore/Tests and run with `swift test`.
//

import Testing
import QuotientCore
@testable import Quotient

struct QuotientTests {

    @Test func appModelLoadsBundledSnapshotAndCalibrates() async throws {
        let model = AppModel()
        await model.load()
        #expect(model.loadError == nil)
        #expect(model.snapshot != nil)
        #expect(model.selectedInstrument?.symbol == "SPY")
        let p = model.calibratedParameters
        #expect(p.instrument.symbol == "SPY")
        #expect(p.fundamentalVolatilityTicks > 0)
    }

    @Test func terminalViewModelStepsAndSwitchesStrategies() {
        let vm = TerminalViewModel(parameters: .example)
        vm.step(200)
        #expect(vm.simulator.step == 200)
        #expect(vm.pnlSeries.count == 201)
        #expect(vm.strategyName == "Avellaneda-Stoikov")
        vm.strategyChoice = .fixed
        #expect(vm.strategyName == "Fixed Spread")
        vm.strategyChoice = .manual
        vm.manualSkew = 2
        #expect(vm.strategyName == "Manual")
        vm.step(50)
        #expect(vm.simulator.book.checkInvariants() == nil)
        vm.applyPreset(ScenarioPreset.trending())
        #expect(vm.parameters.fundamentalDriftTicks > 0)
        #expect(vm.simulator.step == 0)
    }

    @Test func compareViewModelProducesReport() async {
        let vm = CompareViewModel()
        vm.trials = 20
        var p = SimulationParameters.example
        p.steps = 300
        vm.run(base: p)
        for _ in 0..<200 where vm.report == nil { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(vm.report?.outcomes.count == 3)
        #expect(vm.markdown.contains("Paired differences"))
        #expect(vm.isRunning == false)
    }
}
