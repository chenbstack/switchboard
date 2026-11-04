import AppKit

// 调试：--scan-test 只测一次全量扫描的耗时，不写入任何文件
if CommandLine.arguments.contains("--scan-test") {
    var st = TokenStats()
    let t0 = Date()
    TokenScanner.scan(&st)
    print(String(format: "scan %.1fs, files %d, buckets %d", Date().timeIntervalSince(t0), st.files.count, st.buckets.count))
    for p in Provider.allCases {
        for d in [1, 7] {
            let s = st.summary(provider: p, days: d)
            print(p.rawValue, d, "total", s.total.total, "msgs", s.total.messages, String(format: "cost %.2f hit %.3f", s.total.cost, s.total.hitRate ?? 0))
            for m in s.byModel { print("   ", m.model, m.b.total, m.b.tokPerSec.map { String(Int($0)) } ?? "-") }
        }
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
