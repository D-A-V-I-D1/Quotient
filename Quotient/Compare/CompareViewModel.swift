//
//  CompareViewModel.swift
//  Quotient
//
//  Runs the paired Monte Carlo off the main thread and exposes the report.
//

import Foundation
import Observation
import QuotientCore

@Observable
final class CompareViewModel {
    var presetName: String = "Baseline"
    var trials: Int = 100
    var gamma: Double = 0.01
    private(set) var progress: Double = 0
    private(set) var isRunning = false
    private(set) var report: MonteCarloReport?
    private(set) var markdown: String = ""
    private(set) var lastRunSummary: String = ""

    func presets(base: SimulationParameters) -> [ScenarioPreset] { ScenarioPreset.all(base: base) }

    func run(base: SimulationParameters) {
        guard !isRunning else { return }
        let preset = presets(base: base).first { $0.name == presetName } ?? ScenarioPreset.baseline(base)
        let cfg = MonteCarloConfiguration(parameters: preset.parameters, trials: trials)
        let gamma = self.gamma
        isRunning = true
        progress = 0
        report = nil
        Task.detached(priority: .userInitiated) { [weak self] in
            let strategies = MonteCarloRunner.standardLadder(parameters: preset.parameters, gamma: gamma)
            let rep = await MonteCarloRunner.run(cfg, strategies: strategies) { f in
                Task { @MainActor [weak self] in self?.progress = f }
            }
            let md = ReportGenerator.markdown(rep, title: "\(preset.name) — \(cfg.parameters.instrument.symbol)", scenarioSummary: preset.summary)
            await MainActor.run { [weak self] in
                self?.report = rep
                self?.markdown = md
                self?.lastRunSummary = preset.summary
                self?.isRunning = false
                self?.progress = 1
            }
        }
    }
}
