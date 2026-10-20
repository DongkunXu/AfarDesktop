import Dispatch
import IOSurface
import os

/// Carries a session's events from its own thread to the main actor: plain events, the
/// questions that hold the session thread until answered, and desktop frames, which are
/// coalesced so at most one main-queue hop is pending however fast they arrive.
final class SessionRelay<Owner: RemoteSession>: @unchecked Sendable {
    private weak var owner: Owner?
    private let pendingFrame = OSAllocatedUnfairLock<IOSurface?>(uncheckedState: nil)
    /// Answers the session thread is waiting for, so closing the session can release them.
    private let pendingAnswers = OSAllocatedUnfairLock(initialState: [DispatchSemaphore]())

    init(_ owner: Owner) {
        self.owner = owner
    }

    func onMain(_ body: @escaping @MainActor (Owner) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let owner = self?.owner else { return }
            MainActor.assumeIsolated { body(owner) }
        }
    }

    /// Hands the newest frame to the delegate, replacing one still waiting.
    func frameUpdated(_ surface: IOSurface) {
        let alreadyPending = pendingFrame.withLockUnchecked { pending in
            defer { pending = surface }
            return pending != nil
        }
        guard !alreadyPending else { return }
        onMain { [weak self] owner in
            guard let frame = self?.pendingFrame.withLockUnchecked({ pending in
                defer { pending = nil }
                return pending
            }) else { return }
            owner.delegate?.session(owner, frameUpdated: frame)
        }
    }

    /// Runs `ask` on the main actor and blocks this (session) thread until it answers.
    func waitForAnswer<T: Sendable>(default fallback: T,
                                    _ ask: @escaping @MainActor (Owner, @escaping @Sendable (T) -> Void) -> Void) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let answer = OSAllocatedUnfairLock(initialState: fallback)
        pendingAnswers.withLock { $0.append(semaphore) }
        onMain { owner in
            ask(owner) { value in
                answer.withLock { $0 = value }
                semaphore.signal()
            }
        }
        semaphore.wait()
        pendingAnswers.withLock { $0.removeAll { $0 === semaphore } }
        return answer.withLock { $0 }
    }

    /// Lets every waiting question return its default.
    func releasePendingAnswers() {
        pendingAnswers.withLock { list in
            list.forEach { $0.signal() }
            list.removeAll()
        }
    }

    // MARK: Common questions

    func verifyCertificate(_ info: CertificateInfo) -> CertificateDecision {
        waitForAnswer(default: CertificateDecision.reject) { owner, answer in
            guard let delegate = owner.delegate else { return answer(.reject) }
            delegate.session(owner, verify: info, decide: answer)
        }
    }

    func credentials(for request: CredentialRequest) -> Credentials? {
        waitForAnswer(default: nil) { owner, answer in
            guard let delegate = owner.delegate else { return answer(nil) }
            delegate.session(owner, credentialsFor: request, provide: answer)
        }
    }
}
