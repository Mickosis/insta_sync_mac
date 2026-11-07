import SwiftUI

/// Progress of the current task, at the bottom of the window. Questions (merge or keep
/// separate?) appear here too.
struct JobPanel: View {
    private var model: AppModel { .shared }
    @Environment(\.openWindow) private var openWindow
    @ViewState private var showLog = true

    var body: some View {
        if let job = model.jobs.shown {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    statusIcon(job)
                    Text(job.title).fontWeight(.semibold)
                    Text(countText(job)).foregroundStyle(.secondary).font(.callout)
                    let waiting = model.jobs.active.filter { $0.status == .queued }.count
                    if waiting > 0 { Text("· \(waiting) more waiting").foregroundStyle(.secondary).font(.callout) }
                    Spacer()
                    Button(showLog ? "Hide details" : "Details") { showLog.toggle() }.buttonStyle(.borderless)
                    if job.isActive {
                        Button("Stop") { job.stop() }
                    } else {
                        Button("Close") { model.jobs.shown = nil }
                    }
                }
                .controlSize(.small)

                if job.isActive {
                    if job.total > 0 {
                        ProgressView(value: Double(job.done), total: Double(max(job.total, 1)))
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }

                if let q = job.question {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(q.text)
                        HStack {
                            ForEach(Array(q.options.enumerated()), id: \.offset) { i, o in
                                if i == 0 {
                                    Button(o) { job.reply(o) }.buttonStyle(.borderedProminent)
                                } else {
                                    Button(o) { job.reply(o) }
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)))
                }

                if job.needsInstagramWindow {
                    HStack {
                        Text(job.error ?? "").foregroundStyle(.red)
                        Button(model.isLoggedIn ? "Open Instagram window" : "Log in to Instagram") { openWindow(id: "instagram") }
                            .buttonStyle(.borderedProminent)
                    }
                } else if let e = job.error {
                    Text(e).foregroundStyle(.red)
                }

                if showLog {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(job.log.suffix(60)) { line in
                                    Text(line.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        .id(line.id)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 96)
                        .onChange(of: job.log.count) {
                            if let last = job.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }
            }
            .padding(12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
            .task(id: job.status) {
                // A finished job's panel goes away by itself after a few seconds.
                if job.status == .done && job.question == nil {
                    try? await Task.sleep(for: .seconds(6))
                    if model.jobs.shown === job && !Task.isCancelled { model.jobs.shown = nil }
                }
            }
        }
    }

    private func countText(_ job: Job) -> String {
        if job.total > 0 { return "\(job.done) of \(job.total)" }
        return job.status == .queued ? "waiting…" : ""
    }

    @ViewBuilder
    private func statusIcon(_ job: Job) -> some View {
        switch job.status {
        case .queued, .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary)
        }
    }
}
