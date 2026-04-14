import BatteryCareShared

/// Pure value-type state machine. Thread-safe only when accessed from a single actor (DaemonCore).
/// Mutating methods return whether the state actually changed — caller uses this to decide
/// whether to issue SMC writes.
public struct ChargingStateMachine: Sendable {

    public private(set) var state: ChargingState = .idle

    public init() {}

    // MARK: - Normal evaluation

    /// Re-derive state from a fresh battery reading using hysteresis between sailingLower and limit.
    /// - Returns: `true` if state changed (SMC action needed), `false` if unchanged.
    @discardableResult
    public mutating func evaluate(reading: BatteryReading, limit: Int, sailingLower: Int, isDisabled: Bool) -> Bool {
        let newState = deriveState(reading: reading, limit: limit, sailingLower: sailingLower, isDisabled: isDisabled)
        guard newState != state else { return false }
        state = newState
        return true
    }

    // MARK: - Command-driven overrides

    /// Called when `.disableCharging` command received. Immediately enters `.disabled`.
    public mutating func forceDisable() {
        state = .disabled
    }

    /// Called when `.enableCharging` command received.
    /// Intentionally ignores sailingLower — user explicitly enabling should start charging toward limit.
    public mutating func forceEnable(reading: BatteryReading, limit: Int) {
        if !reading.isPluggedIn {
            state = .idle
        } else if reading.percentage >= limit {
            state = .limitReached
        } else {
            state = .charging
        }
    }

    // MARK: - Private

    private func deriveState(reading: BatteryReading, limit: Int, sailingLower: Int, isDisabled: Bool) -> ChargingState {
        if isDisabled { return .disabled }
        guard reading.isPluggedIn else { return .idle }
        // Hard ceiling: always stop at upper limit
        if reading.percentage >= limit { return .limitReached }
        // Hard floor: always charge below lower bound
        if reading.percentage < sailingLower { return .charging }
        // Sailing zone [sailingLower, limit): hysteresis — stay in current charging direction.
        // If we were charging (heading toward upper), keep going.
        // Otherwise (idle, limitReached, disabled), stay paused.
        return state == .charging ? .charging : .limitReached
    }
}