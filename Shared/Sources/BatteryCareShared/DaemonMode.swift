// Phase 1 uses .normal only. Remaining cases reserved for Phase 2-3.
public enum DaemonMode: String, Codable, Sendable {
    case normal       // standard charge-limit loop
    case discharging  // drain while plugged in (Phase 2)
    case topUp        // one-time charge to 100% then revert (Phase 3)
    case calibrating  // full cycle calibration (Phase 3)
}
