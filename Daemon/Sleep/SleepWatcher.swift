import Foundation
import IOKit
import IOKit.pwr_mgt

// MARK: - Events

public enum SleepEvent: Sendable {
    case willSleep
    case hasPoweredOn
}

// MARK: - Protocol

public protocol SleepWatcherProtocol: Sendable {
    func events() -> AsyncStream<SleepEvent>
}

// MARK: - Context (heap-allocated, passed as refcon)

/// Holds mutable state that the C callback writes to. Accessed only from the IOKit run-loop
/// notification thread, so no extra locking is needed for `continuation`.
private final class SleepWatcherContext: @unchecked Sendable {
    var continuation: AsyncStream<SleepEvent>.Continuation?
    var rootPort: io_connect_t = 0
    var notifierObject: io_object_t = IO_OBJECT_NULL
    var notifyPort: IONotificationPortRef?
}

// MARK: - C callback (must be a plain C function pointer — use @convention(c))

/// IOKit calls this on the run-loop registered with the notification port.
/// `IOAllowPowerChange` MUST be called synchronously before returning for
/// kIOMessageCanSystemSleep and kIOMessageSystemWillSleep.
private let sleepNotificationCallback: IOServiceInterestCallback = {
    refcon, _, messageType, messageArgument in

    guard let refcon else { return }
    let ctx = Unmanaged<SleepWatcherContext>.fromOpaque(refcon).takeUnretainedValue()

    switch messageType {
    case UInt32(kIOMessageCanSystemSleep):
        // Allow sleep immediately; we don't need to delay it.
        IOAllowPowerChange(ctx.rootPort, Int(bitPattern: messageArgument))

    case UInt32(kIOMessageSystemWillSleep):
        ctx.continuation?.yield(.willSleep)
        // Must ack before returning or the system will hang for 30 s then force-sleep.
        IOAllowPowerChange(ctx.rootPort, Int(bitPattern: messageArgument))

    case UInt32(kIOMessageSystemHasPoweredOn):
        ctx.continuation?.yield(.hasPoweredOn)

    default:
        break
    }
}

// MARK: - Implementation

public final class SleepWatcher: SleepWatcherProtocol, @unchecked Sendable {

    private let ctx = SleepWatcherContext()

    public init() {}

    /// Returns an `AsyncStream` that yields `.willSleep` / `.hasPoweredOn` events.
    /// Calling this more than once replaces the previous stream (only one active at a time).
    public func events() -> AsyncStream<SleepEvent> {
        AsyncStream { continuation in
            self.ctx.continuation = continuation
            self.registerNotifications()
            continuation.onTermination = { [weak self] _ in
                self?.unregisterNotifications()
            }
        }
    }

    // MARK: - Private

    private func registerNotifications() {
        var rootPort: io_connect_t = 0
        let notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort else { return }

        let refcon = Unmanaged.passUnretained(ctx).toOpaque()
        var notifierObject: io_object_t = IO_OBJECT_NULL

        rootPort = IORegisterForSystemPower(
            refcon,
            notifyPort,
            sleepNotificationCallback,
            &notifierObject
        )
        guard rootPort != 0 else {
            IONotificationPortDestroy(notifyPort)
            return
        }

        ctx.rootPort = rootPort
        ctx.notifierObject = notifierObject
        ctx.notifyPort = notifyPort

        // Add the notification port's run-loop source to the current run loop.
        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort)!.takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
    }

    private func unregisterNotifications() {
        if ctx.notifierObject != IO_OBJECT_NULL {
            IODeregisterForSystemPower(&ctx.notifierObject)
        }
        if let port = ctx.notifyPort {
            if let source = IONotificationPortGetRunLoopSource(port) {
                CFRunLoopRemoveSource(
                    CFRunLoopGetCurrent(),
                    source.takeUnretainedValue(),
                    .defaultMode
                )
            }
            IONotificationPortDestroy(port)
            ctx.notifyPort = nil
        }
        ctx.rootPort = 0
        ctx.continuation?.finish()
        ctx.continuation = nil
    }
}
