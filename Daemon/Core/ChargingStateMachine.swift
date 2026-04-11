import BatteryCareShared

/// Pure value-type state machine. Thread-safe only when accessed from a single actor (DaemonCore).
/// Mutating methods return whether the state actually changed — caller uses this to decide
/// whether to issue SMC writes.
public struct ChargingStateMachine: Sendable {

    public private(set) var state: ChargingState = .idle

    public init() {}

    // MARK: - Normal evaluation

    /// Re-derive state from a fresh battery reading.
    /// - Returns: `true` if state changed (SMC action needed), `false` if unchanged.
    @discardableResult
    public mutating func evaluate(reading: BatteryReading, limit: Int, isDisabled: Bool) -> Bool {
        let newState = deriveState(reading: reading, limit: limit, isDisabled: isDisabled)
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
    /// Derives the correct state from current battery reading (does NOT force `.charging`).
    public mutating func forceEnable(reading: BatteryReading, limit: Int) {
        state = deriveState(reading: reading, limit: limit, isDisabled: false)
    }

    // MARK: - Private

    private func deriveState(reading: BatteryReading, limit: Int, isDisabled: Bool) -> ChargingState {
        if isDisabled { return .disabled }
        guard reading.isPluggedIn else { return .idle }
        return reading.percentage >= limit ? .limitReached : .charging
    }
}
