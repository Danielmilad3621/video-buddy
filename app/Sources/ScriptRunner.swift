// Runs the pipeline scripts so that nothing they start can outlive a Cancel, a Quit or a crash.
import Foundation

let home = NSHomeDirectory()
let toolPATH = "/opt/homebrew/bin:\(home)/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

/// Every subprocess runs under this bash guard. Its fd 3 (the "lifeline") is a pipe whose write end only the
/// app holds. When the app closes it (Cancel/Quit) or the kernel closes it because the app died (crash,
/// kill -9), the watcher wakes up and signals the job's whole process tree, parents first so scripts stop
/// launching new steps: SIGTERM, then SIGKILL after 3 s for anything still alive. The tree is found from the
/// job's own pid with `pgrep -P`, never by name, so unrelated processes are never touched.
/// SIGPIPE is ignored (and inherited by the job): after a crash the output pipe has no reader, and a write must
/// fail with EPIPE so the scripts exit through their cleanup traps instead of being killed before they run.
private let guardScript = #"""
trap '' PIPE
exec 3<&0 0</dev/null
"$@" 3<&- &
child=$!
tree() { echo "$1"; local p; for p in $(pgrep -P "$1"); do tree "$p"; done; }
(
  read -r _ <&3
  trap '' TERM
  pids=$(tree "$child")
  kill -TERM $pids 2>/dev/null
  survivors() { for p in $pids; do kill -0 "$p" 2>/dev/null && echo "$p"; done; }
  wait_gone() { for _ in $(seq "$1"); do [ -z "$(survivors)" ] && exit 0; sleep 0.1; done; }
  wait_gone 30
  # still running after 3 s: force-stop the programs first, so the scripts waiting on them can still run
  # their cleanup traps (temp dirs, .part files); then force-stop whatever is left
  for p in $(survivors); do case "$(ps -p "$p" -o comm= 2>/dev/null)" in */bash|bash|*/sh|sh) ;; *) kill -KILL "$p" 2>/dev/null ;; esac; done
  wait_gone 20
  kill -KILL $(survivors) $(tree "$child") 2>/dev/null
) >/dev/null 2>&1 &
watcher=$!
exec 3<&-
wait "$child"
status=$?
kill "$watcher" 2>/dev/null
exit "$status"
"""#

final class RunningScript {
    private let process = Process()
    private let output = Pipe()
    private let lifeline = Pipe()
    private(set) var cancelled = false

    init(_ command: [String], env extra: [String: String] = [:]) throws {
        // the app's ends must never leak into other children, or a dead app couldn't be noticed
        _ = fcntl(lifeline.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        _ = fcntl(output.fileHandleForReading.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", guardScript, "vs-guard"] + command
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = toolPATH
        env.merge(extra) { $1 }
        process.environment = env
        process.standardInput = lifeline
        process.standardOutput = output
        process.standardError = output
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }

    /// Closing the lifeline makes the guard stop the whole tree; the script's traps clean up temp files.
    func cancel() {
        cancelled = true
        try? lifeline.fileHandleForWriting.close()
    }

    /// Streams merged stdout/stderr line by line on the caller's actor, then returns the exit status.
    func stream(isolation: isolated (any Actor)? = #isolation, _ onLine: (String) -> Void) async -> Int32 {
        do {
            for try await line in output.fileHandleForReading.bytes.lines { onLine(line) }
        } catch {}
        while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        try? lifeline.fileHandleForWriting.close()
        return process.terminationStatus
    }

    func collect(isolation: isolated (any Actor)? = #isolation) async -> (status: Int32, lines: [String]) {
        var lines: [String] = []
        let status = await stream { lines.append($0) }
        return (status, lines)
    }
}
