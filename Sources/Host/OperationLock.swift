import Darwin
import Foundation

struct OperationLockBusy: Error {}

func acquireOperationLock(_ descriptor: Int32, waitingUpTo timeout: TimeInterval) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
        let failure = errno
        if failure == EINTR { continue }
        guard failure == EWOULDBLOCK else { throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO) }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw OperationLockBusy() }
        Thread.sleep(forTimeInterval: min(remaining, 0.05))
    }
}
