import Foundation
import Observation

/// A long task (sync, link, cleanup…) shown in the progress panel.
@MainActor @Observable
final class Job: Identifiable {
    enum Status { case queued, running, done, failed, stopped }

    struct Line: Identifiable {
        let id = UUID()
        let text: String
    }

    struct Question {
        let text: String
        let options: [String]
    }

    let id = UUID()
    let kind: String
    let title: String
    var status: Status = .queued
    var log: [Line] = []
    var done = 0
    var total = 0
    var question: Question?
    var error: String?
    /// The error was about the Instagram login or a security check: offer to open the Instagram window.
    var needsInstagramWindow = false
    var summary: String?

    fileprivate var answer: CheckedContinuation<String?, Never>?
    fileprivate var task: Task<Void, Never>?

    init(kind: String, title: String) {
        self.kind = kind
        self.title = title
    }

    var isActive: Bool { status == .queued || status == .running }

    func say(_ text: String, done: Int? = nil, total: Int? = nil) {
        log.append(Line(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
        if let done { self.done = done }
        if let total { self.total = total }
    }

    func reply(_ choice: String?) {
        guard let c = answer else { return }
        answer = nil
        question = nil
        if let choice { say("→ \(choice)") }
        c.resume(returning: choice)
    }

    fileprivate var cancelRequested = false

    func stop() {
        cancelRequested = true
        task?.cancel()
        reply(nil)
    }
}

/// What a running job's work function gets: report progress, ask a question. Safe to use
/// from any thread; updates reach the UI in order.
final class JobContext: @unchecked Sendable {
    private let job: Job

    init(_ job: Job) { self.job = job }

    func say(_ text: String, done: Int? = nil, total: Int? = nil) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.job.say(text, done: done, total: total) } }
    }

    func progress(done: Int? = nil, total: Int? = nil) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let done { self.job.done = done }
                if let total { self.job.total = total }
            }
        }
    }

    func summary(_ text: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.job.summary = text } }
    }

    /// Pause until the question is answered in the progress panel (or 30 minutes pass). nil = dismissed.
    func ask(_ text: String, _ options: [String]) async -> String? {
        let job = self.job
        let timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30 * 60))
            if !Task.isCancelled { job.reply(nil) }
        }
        defer { timeout.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if job.cancelRequested { return c.resume(returning: nil) }
                        job.answer = c
                        job.question = Job.Question(text: text, options: options)
                    }
                }
            }
        } onCancel: {
            DispatchQueue.main.async { MainActor.assumeIsolated { job.reply(nil) } }
        }
    }
}

/// Runs jobs one at a time: they all share the one hidden Instagram web view.
@MainActor @Observable
final class JobQueue {
    typealias Work = @Sendable (JobContext) async throws -> Void

    private(set) var all: [Job] = []
    /// The job the progress panel shows.
    var shown: Job?
    private var pending: [(Job, Work)] = []
    private var running = false

    /// Called after every job (contacts may have changed).
    var onFinish: (@MainActor (Job) -> Void)?

    var active: [Job] { all.filter(\.isActive) }
    var isBusy: Bool { running || !pending.isEmpty }

    @discardableResult
    func submit(kind: String, title: String, _ work: @escaping Work) -> Job {
        let job = Job(kind: kind, title: title)
        all.append(job)
        if all.count > 50 { all.removeFirst(all.count - 50) }
        pending.append((job, work))
        shown = job
        pump()
        return job
    }

    private func pump() {
        guard !running, !pending.isEmpty else { return }
        running = true
        let (job, work) = pending.removeFirst()
        job.status = .running
        let ctx = JobContext(job)
        job.task = Task.detached(priority: .userInitiated) {
            let failure: Error?
            do { try await work(ctx); failure = nil } catch { failure = error }
            await MainActor.run { [failure] in self.finish(job, failure) }
        }
    }

    private func finish(_ job: Job, _ failure: Error?) {
        // Let queued progress lines land before the final status.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let failure {
                    if failure is CancellationError || job.task?.isCancelled == true {
                        job.status = .stopped
                        job.say("Stopped.")
                    } else {
                        job.status = .failed
                        job.error = failure.detail
                        if let ie = failure as? InstaError, ie == .loginRequired || ie == .challenge {
                            job.needsInstagramWindow = true
                        }
                        job.say(job.error ?? "Failed")
                    }
                } else {
                    job.status = .done
                }
                job.question = nil
                self.running = false
                if self.pending.isEmpty { InstagramSession.shared.close() }  // keep it open while more jobs wait
                self.onFinish?(job)
                self.pump()
            }
        }
    }
}
