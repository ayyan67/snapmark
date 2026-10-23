// Launch-time and memory harness used for the comparison table in README.md.
//
// Build: swiftc -O bench/launchbench.swift -o /tmp/launchbench
// Usage: /tmp/launchbench <executable> <runs> <settle_seconds>
//
// For each run:
//   1. Record which com.apple.WebKit.* helper processes already exist.
//   2. Spawn the executable and poll CGWindowListCopyWindowInfo every 1 ms until an
//      on-screen, layer-0 window owned by the child appears (launch_to_window_ms).
//      This is when the native window is on screen, not when web content has painted.
//   3. Wait settle_seconds, then read RSS (ps -o rss) of the child and of any WebKit
//      helper processes that appeared after the launch. WKWebView runs its content,
//      networking, and GPU work in those separate XPC processes, which are not children
//      of the app, so they have to be found this way.
//   4. SIGTERM the child and wait 2 s before the next run.
//
// Caveats: RSS counts shared framework pages, so absolute numbers overstate private
// memory for both apps. Helper attribution assumes no other WebKit client launches
// during the run.
import CoreGraphics
import Foundation

setvbuf(stdout, nil, _IONBF, 0)

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func psList() -> [(pid: Int32, rss: Int, comm: String)] {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/ps")
    p.arguments = ["-axo", "pid=,rss=,comm="]
    let pipe = Pipe()
    p.standardOutput = pipe
    try! p.run()
    // Drain before waiting; ps output can exceed the pipe buffer.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let out = String(data: data, encoding: .utf8)!
    return out.split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3, let pid = Int32(parts[0]), let rss = Int(parts[1]) else { return nil }
        return (pid, rss, String(parts[2]))
    }
}

func webkitPids() -> Set<Int32> {
    Set(psList().filter { $0.comm.contains("com.apple.WebKit") }.map { $0.pid })
}

func hasWindow(_ pid: Int32) -> Bool {
    guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
    else { return false }
    for w in info {
        let owner = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? -1
        let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
        if owner == pid && layer == 0 { return true }
    }
    return false
}

let args = CommandLine.arguments
guard args.count == 4, let runs = Int(args[2]), let settle = Double(args[3]) else {
    print("usage: launchbench <executable> <runs> <settle_seconds>")
    exit(2)
}
let exe = args[1]

for i in 1...runs {
    let before = webkitPids()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    let t0 = now()
    try! p.run()
    let pid = p.processIdentifier
    var launchMs = -1.0
    while now() - t0 < 15000 {
        if hasWindow(pid) { launchMs = now() - t0; break }
        usleep(1000)
    }
    Thread.sleep(forTimeInterval: settle)
    let ps = psList()
    let mainRss = ps.first { $0.pid == pid }?.rss ?? -1
    let helpers = ps.filter { $0.comm.contains("com.apple.WebKit") && !before.contains($0.pid) }
    let helperRss = helpers.reduce(0) { $0 + $1.rss }
    print(String(format: "run=%d launch_to_window_ms=%.1f main_rss_kb=%d helper_count=%d helper_rss_kb=%d",
                 i, launchMs, mainRss, helpers.count, helperRss))
    p.terminate()
    p.waitUntilExit()
    Thread.sleep(forTimeInterval: 2.0)
}
