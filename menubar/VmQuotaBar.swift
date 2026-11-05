// VmQuotaBar.swift — a native macOS menu-bar app (single file, no Xcode project)
// showing vm2api gateway quota at a glance.
//
//   Menu bar : "89 18"   (5h usage then optional 7d usage, severity colors —
//                         red means close to the limit; 7d toggleable in settings)
//   Click    : compact popover — usage cards (bar fill = USAGE), billing with
//              hierarchy, collapsible quality-of-service details, pool only
//              when there is more than one account.
//
// Data (read-only GETs, same endpoints as the vm2api-quota plugin):
//   GET {base}/v1/usage?unit=percent_used                       (API key)
//   GET {base}/api/panel/vms                                    (panel credential)
//   GET {base}/api/panel/usage                                  (panel credential)
//   GET {base}/api/panel/request-logs/stats?bucket=hour&since=… (panel credential)
//
// Config — the app's OWN config file, editable from the settings form in the
// popover (this app does not read the plugin's config):
//   ~/.config/vm2api-quota/menubar.json
//   { base_url, api_key, panel_token, show_7d }
//
// Build:  menubar/build.sh        Run:  menubar/bin/VmQuotaBar  (or build.sh --app)

import AppKit
import Combine
import SwiftUI

// MARK: - JSON helpers

private func asDict(_ x: Any?) -> [String: Any]? { x as? [String: Any] }
private func asArr(_ x: Any?) -> [Any]? { x as? [Any] }
private func asNum(_ x: Any?) -> Double? {
    if let n = x as? NSNumber { return n.doubleValue }
    if let s = x as? String { return Double(s) }
    return nil
}
private func asStr(_ x: Any?) -> String? { x as? String }
private func dig(_ d: [String: Any]?, _ path: String...) -> Any? {
    var cur: Any? = d
    for k in path {
        cur = asDict(cur)?[k]
        if cur == nil { return nil }
    }
    return cur
}

// MARK: - Config (the app's own file, edited via the in-app settings form)

struct GatewayConfig {
    var baseURL: String
    var apiKey: String
    var panelToken: String
    var show7d: Bool
    var configPath: String

    static var path: String { NSHomeDirectory() + "/.config/vm2api-quota/menubar.json" }

    static func load() -> GatewayConfig {
        var cfg: [String: Any] = [:]
        if let data = FileManager.default.contents(atPath: path) {
            cfg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        var base = asStr(cfg["base_url"]) ?? ""
        if base.hasSuffix("/") { base = String(base.dropLast()) }
        return GatewayConfig(baseURL: base,
                             apiKey: asStr(cfg["api_key"]) ?? "",
                             panelToken: asStr(cfg["panel_token"]) ?? "",
                             show7d: cfg["show_7d"] as? Bool ?? true,
                             configPath: path)
    }

    static func save(baseURL: String, apiKey: String, panelToken: String, show7d: Bool) -> Bool {
        let trimmed = { (s: String) in s.trimmingCharacters(in: .whitespacesAndNewlines) }
        var base = trimmed(baseURL)
        while base.hasSuffix("/") { base = String(base.dropLast()) }
        let obj: [String: Any] = ["base_url": base,
                                  "api_key": trimmed(apiKey),
                                  "panel_token": trimmed(panelToken),
                                  "show_7d": show7d]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return FileManager.default.createFile(atPath: path, contents: data,
                                              attributes: [.posixPermissions: 0o600])
    }
}

// MARK: - Snapshot models

struct WindowInfo {
    var pct = 0                 // usage percent
    var status = "unknown"
    var resetsAt: Double?
    var resetsText = "n/a"      // "MM-dd HH:mm (in 44m)"

    mutating func parse(_ d: [String: Any]?) {
        guard let d = d else { return }
        pct = Int(asNum(d["utilization"]) ?? 0)
        status = asStr(d["status"]) ?? "unknown"
        if let r = asNum(d["resets_at"]) { resetsAt = r }
        resetsText = Self.resetText(resetsAt)
    }

    static func resetText(_ epoch: Double?) -> String {
        guard let epoch = epoch else { return "n/a" }
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return "\(df.string(from: Date(timeIntervalSince1970: epoch))) (\(resetShort(epoch)))"
    }

    /// Short countdown like "2h 47m", "44m", "6d 3h", "active".
    static func resetShort(_ epoch: Double?) -> String {
        guard let epoch = epoch else { return "—" }
        let rel = Int(epoch - Date().timeIntervalSince1970)
        if rel <= 0 { return "active" }
        let d = rel / 86400, h = (rel % 86400) / 3600, m = (rel % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

struct PoolAccount {
    var id = "", name = "", status5 = "unknown", status7 = "unknown"
    var u5 = 0, u7 = 0
    var r5: Double?, r7: Double?
    var est5 = "", est7 = ""
}

struct BillingInfo {
    var source = "", currency = "USD"
    var today = "", todayReq = "", todaySince = ""
    var w5 = "", w5Req = ""
    var total = "", totalReq = ""
}

struct QoSInfo {
    var samples = 0
    var successPct = 0.0, errorPct = 0.0
    var c429 = 0, c503 = 0, c529 = 0
    var ttft = "", duration = "", qps = "", tps = "", cache = "", sticky = ""
    var models: [(name: String, req: String, err: String, ttft: String, dur: String)] = []
}

struct Snapshot {
    var ok = false
    var error = ""
    var note = ""            // e.g. "window numbers from the pool (429)"
    var platform = "", source = ""
    var w5 = WindowInfo(), w7 = WindowInfo()
    var pool: [PoolAccount] = []
    var billing = BillingInfo()
    var qos = QoSInfo()
    var hasPanel = false
    var updatedAt = Date.distantPast
}

// MARK: - Fetcher (read-only GETs, no system proxy)

enum Fetcher {
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.connectionProxyDictionary = [:] // direct connection (internal hostnames)
        return URLSession(configuration: c)
    }()

    private static func getJSON(_ url: String, token: String) async -> (Int, [String: Any]?) {
        guard let u = URL(string: url) else { return (-1, nil) }
        var req = URLRequest(url: u)
        req.httpMethod = "GET"
        if !token.isEmpty { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            return (code, (try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
        } catch {
            return (-2, nil)
        }
    }

    static func fetchAll(cfg: GatewayConfig) async -> Snapshot {
        var s = Snapshot()
        guard !cfg.baseURL.isEmpty else {
            s.error = "Not configured yet — open settings (⚙) and enter the gateway URL."
            return s
        }
        guard !cfg.apiKey.isEmpty else {
            s.error = "No API key — open settings (⚙) and paste your key."
            return s
        }

        // 1. current account
        // When every pool account is rate-limited the gateway 429s /v1/usage
        // itself; the panel endpoints still serve the real numbers, so fall
        // back to them (first pool account) and note it.
        let (code, usage) = await getJSON(cfg.baseURL + "/v1/usage?unit=percent_used", token: cfg.apiKey)
        let usageOK = (code == 200)
        if usageOK, let usage = usage {
            s.platform = asStr(usage["platform"]) ?? ""
            s.source = asStr(usage["source"]) ?? ""
            s.w5.parse(asDict(usage["five_hour"]))
            s.w7.parse(asDict(usage["seven_day"]))
        } else if code == 429 {
            s.note = "upstream rate-limited (429) — window numbers from the pool"
            s.platform = "gateway"
            s.source = "pool"
        } else {
            s.error = "/v1/usage failed (HTTP \(code)). Check the gateway URL / key."
            return s
        }
        s.hasPanel = !cfg.panelToken.isEmpty

        guard s.hasPanel else {
            if usageOK {
                s.ok = true; s.updatedAt = Date()
            } else {
                s.error = "Quota exhausted — /v1/usage is rate-limited (429). Add a panel credential (the gateway master key) in settings ⚙ to keep showing pool-based numbers."
            }
            return s
        }

        // 2. pool
        let (_, vms) = await getJSON(cfg.baseURL + "/api/panel/vms", token: cfg.panelToken)
        if let items = asArr(dig(vms, "data", "items")) {
            for it in items {
                guard let v = asDict(it) else { continue }
                var a = PoolAccount()
                a.id = asStr(v["id"]) ?? "-"
                a.name = asStr(v["name"]) ?? "-"
                a.u5 = Int((asNum(v["utilization_5h"]) ?? 0) * 100)
                a.u7 = Int((asNum(v["utilization_7d"]) ?? 0) * 100)
                a.status5 = asStr(v["status_5h"]) ?? "unknown"
                a.status7 = asStr(v["status_7d"]) ?? "unknown"
                a.r5 = asNum(v["reset_5h"])
                a.r7 = asNum(v["reset_7d"])
                a.est5 = est(v, "estimate_5h"); a.est7 = est(v, "estimate_7d")
                s.pool.append(a)
            }
        }
        if !usageOK, let f = s.pool.first {
            s.w5.pct = f.u5; s.w5.status = f.status5; s.w5.resetsAt = f.r5
            s.w5.resetsText = WindowInfo.resetText(f.r5)
            s.w7.pct = f.u7; s.w7.status = f.status7; s.w7.resetsAt = f.r7
            s.w7.resetsText = WindowInfo.resetText(f.r7)
        }

        // 3. billing
        let (_, bill) = await getJSON(cfg.baseURL + "/api/panel/usage", token: cfg.panelToken)
        if let b = dig(bill, "data", "billing") as? [String: Any] {
            s.billing.source = asStr(b["source"]) ?? ""
            s.billing.currency = asStr(b["currency"]) ?? "USD"
            let today = asDict(b["today"]), w5 = asDict(b["window_5h"]), total = asDict(b["total"])
            s.billing.today = usd(asNum(today?["total_cost"]))
            s.billing.todayReq = intStr(asNum(today?["requests"]))
            s.billing.w5 = usd(asNum(w5?["total_cost"]))
            s.billing.w5Req = intStr(asNum(w5?["requests"]))
            s.billing.total = usd(asNum(total?["total_cost"]))
            s.billing.totalReq = intStr(asNum(total?["requests"]))
            if let billingRoot = asDict(bill) {
                s.billing.todaySince = asStr(billingRoot["today_start"]) ?? ""
            }
        }

        // 4. quality of service (last hour, same call as the console overview)
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = df.string(from: Date().addingTimeInterval(-3600))
        let sinceEnc = since.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? since
        let (_, stats) = await getJSON(cfg.baseURL + "/api/panel/request-logs/stats?bucket=hour&since=" + sinceEnc,
                                       token: cfg.panelToken)
        if let w = asDict(stats?["window"]) { s.qos = parseQoS(w) }

        s.ok = true
        s.updatedAt = Date()
        return s
    }

    private static func est(_ v: [String: Any], _ key: String) -> String {
        guard let e = asDict(v[key]),
              let sp = asNum(e["spent_usd"]), let t = asNum(e["total_usd"]) else { return "" }
        return String(format: "$%.2f/%.2f", sp, t)
    }
    private static func usd(_ n: Double?) -> String { n.map { String(format: "$%.2f", $0) } ?? "—" }
    private static func intStr(_ n: Double?) -> String { n.map { String(Int($0)) } ?? "?" }
    private static func ms(_ n: Double?) -> String {
        guard let n = n else { return "—" }
        return n >= 1000 ? String(format: "%.1fs", n / 1000) : String(format: "%.0fms", n)
    }

    private static func parseQoS(_ w: [String: Any]) -> QoSInfo {
        var q = QoSInfo()
        let ttft = asDict(w["ttft"]), dur = asDict(w["duration"])
        q.samples = Int(asNum(ttft?["samples"]) ?? 0)
        q.successPct = (asNum(w["sla"]) ?? 1) * 100
        q.errorPct = (asNum(w["error_rate"]) ?? 0) * 100
        q.c429 = Int(asNum(w["status_429"]) ?? 0)
        q.c503 = Int(asNum(w["status_503"]) ?? 0)
        q.c529 = Int(asNum(w["status_529"]) ?? 0)
        q.ttft = "p50 \(ms(asNum(ttft?["p50_ms"]))) · p95 \(ms(asNum(ttft?["p95_ms"]))) · p99 \(ms(asNum(ttft?["p99_ms"]))) · avg \(ms(asNum(ttft?["avg_ms"])))"
        q.duration = "p50 \(ms(asNum(dur?["p50_ms"]))) · p95 \(ms(asNum(dur?["p95_ms"]))) · avg \(ms(asNum(dur?["avg_ms"])))"
        let qps = asDict(w["qps"]), tps = asDict(w["tps"])
        q.qps = "cur \(String(format: "%.3f", asNum(qps?["current"]) ?? 0)) · peak \(String(format: "%.3f", asNum(qps?["peak"]) ?? 0))"
        q.tps = "cur \(String(format: "%.1f", asNum(tps?["current"]) ?? 0)) · peak \(String(format: "%.1f", asNum(tps?["peak"]) ?? 0))"
        if let c = asNum(w["cache_hit_rate"]) { q.cache = String(format: "%.1f%%", c * 100) }
        if let st = asDict(w["sticky"]) {
            let hits = Int(asNum(st["hits"]) ?? 0), sel = Int(asNum(st["selections"]) ?? 0)
            q.sticky = "\(hits)/\(sel)" + (asNum(st["rate"]).map { String(format: " (%.0f%%)", $0 * 100) } ?? "")
        }
        for m in asArr(w["by_model"]) ?? [] {
            guard let md = asDict(m) else { continue }
            let name = asStr(md["model"]) ?? asStr(md["family"]) ?? asStr(md["name"]) ?? "-"
            let req = intStr(asNum(md["requests"]))
            let err = intStr(asNum(md["errors"]))
            let mttft = asDict(md["ttft"])
            let tt = ms(asNum(mttft?["avg_ms"]) ?? asNum(md["ttft_avg_ms"]))
            let mdur = asDict(md["duration"])
            let du = ms(asNum(mdur?["avg_ms"]) ?? asNum(md["duration_avg_ms"]))
            q.models.append((name, req, err, tt, du))
        }
        return q
    }
}

// MARK: - Severity (usage semantics: high usage = bad)

enum Severity {
    static func color(forPct pct: Int, status: String) -> NSColor {
        if isBlocked(status) { return .systemRed }
        if pct >= 100 { return .systemRed }
        if pct >= 90 { return .systemOrange }
        if pct >= 70 { return .systemYellow }
        return .systemGreen
    }
    static func isBlocked(_ status: String) -> Bool {
        status == "blocked" || status == "throttled" || status == "rejected"
    }
    static func tag(_ status: String) -> String {
        switch status {
        case "allowed", "active": return "OK"
        case "allowed_warning": return "WARN"
        case "blocked", "rejected": return "BLOCKED"
        case "throttled": return "THROTTLED"
        default: return status.uppercased()
        }
    }
    static func isWarn(_ status: String) -> Bool {
        status == "allowed_warning" || isBlocked(status)
    }
}

// MARK: - State

final class AppState: ObservableObject {
    @Published var snap = Snapshot()
    @Published var refreshing = false
    var cfg = GatewayConfig.load()
    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    /// Save the settings form, reload config, and refresh immediately.
    func saveConfig(baseURL: String, apiKey: String, panelToken: String, show7d: Bool) -> Bool {
        guard GatewayConfig.save(baseURL: baseURL, apiKey: apiKey, panelToken: panelToken, show7d: show7d) else { return false }
        cfg = GatewayConfig.load()
        refresh()
        return true
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let cfg = self.cfg
        Task {
            let snap = await Fetcher.fetchAll(cfg: cfg)
            await MainActor.run {
                self.snap = snap
                self.refreshing = false
            }
        }
    }
}

// MARK: - Menu bar title (numbers only, severity colors; 7d toggleable)

enum BarTitle {
    static func attributed(_ snap: Snapshot, show7d: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let baseColor = NSColor.labelColor

        func add(_ s: String, _ c: NSColor) {
            out.append(NSAttributedString(string: s, attributes: [.font: mono, .foregroundColor: c]))
        }

        guard snap.ok else {
            if snap.error.isEmpty {
                add("…", baseColor) // initial load in progress
            } else {
                add("⚠", .systemRed)
            }
            return out
        }
        // "98 58" — 5h first, then 7d (optional); which-is-which lives in the tooltip
        let windows = show7d ? [snap.w5, snap.w7] : [snap.w5]
        for (i, w) in windows.enumerated() {
            let c = Severity.color(forPct: w.pct, status: w.status)
            add("\(w.pct)", c)
            if i < windows.count - 1 { add(" ", baseColor) }
        }
        if Severity.isWarn(snap.w5.status) || (show7d && Severity.isWarn(snap.w7.status)) {
            add(" ⚠", .systemOrange)
        }
        return out
    }
}

// MARK: - Popover UI

/// Big usage card: the number and the bar fill both mean USAGE (red = close to the limit).
struct QuotaCard: View {
    let title: String
    let usedPct: Int
    let status: String
    let resetText: String
    var est: String = ""

    private var color: Color { Color(Severity.color(forPct: usedPct, status: status)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("resets " + resetText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("\(usedPct)%")
                    .font(.system(size: 26, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(color)
                Text("used")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(100 - usedPct)% left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color)
                        .frame(width: geo.size.width * min(max(Double(usedPct), 0), 100) / 100)
                }
            }
            .frame(height: 7)
            if !est.isEmpty {
                Text("est " + est)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct SettingsForm: View {
    @EnvironmentObject var state: AppState
    @State private var base = ""
    @State private var key = ""
    @State private var panel = ""
    @State private var show7d = true
    @State private var saved = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SETTINGS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Gateway URL (e.g. http://192.0.2.10:8787)", text: $base)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
                .autocorrectionDisabled()
            SecureField("API key (sk-vm-… or the gateway master key)", text: $key)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            SecureField("Panel token (optional — a master key already covers it)", text: $panel)
                .textFieldStyle(.roundedBorder)
                .font(.system(.callout, design: .monospaced))
            Toggle("Show 7d in the menu bar", isOn: $show7d)
                .font(.system(size: 11))
            HStack {
                Button("Save & Refresh") {
                    if state.saveConfig(baseURL: base, apiKey: key, panelToken: panel, show7d: show7d) {
                        saved = true; failed = false
                    } else {
                        failed = true; saved = false
                    }
                }
                if saved { Text("saved ✓").font(.caption).foregroundStyle(.green) }
                if failed { Text("save failed").font(.caption).foregroundStyle(.red) }
                Spacer()
                Text(state.cfg.configPath).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .onAppear {
            base = state.cfg.baseURL
            key = state.cfg.apiKey
            panel = state.cfg.panelToken
            show7d = state.cfg.show7d
        }
    }
}

struct DetailRow: View {
    let label: String, value: String
    var body: some View {
        HStack(alignment: .top) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 100, alignment: .leading)
            Text(value).font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 0)
        }
    }
}

struct SectionLabel: View {
    let title: String
    var trailing: String = ""
    var body: some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .semibold))
            Spacer()
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct PanelView: View {
    @EnvironmentObject var state: AppState
    @State private var showSettings = false
    private let width: CGFloat = 440

    private var s: Snapshot { state.snap }
    private var configured: Bool { !state.cfg.baseURL.isEmpty }

    private var health: (String, Color) {
        guard s.ok else { return ("Error", .red) }
        if Severity.isBlocked(s.w5.status) || Severity.isBlocked(s.w7.status) { return ("Blocked", .red) }
        if Severity.isWarn(s.w5.status) || Severity.isWarn(s.w7.status) { return ("Warning", .orange) }
        return ("Healthy", .green)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                if showSettings || !configured { SettingsForm().padding(.top, 10) }
                if !s.ok {
                    Text(configured ? s.error : "Enter your gateway URL and API key above, then Save.")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                } else {
                    Divider().padding(.vertical, 12)
                    cards
                    if s.pool.count > 1 {
                        Divider().padding(.vertical, 12)
                        poolSection
                    }
                    Divider().padding(.vertical, 12)
                    billingSection
                    Divider().padding(.vertical, 12)
                    qosSection
                }
                footer
            }
            .padding(16)
            .frame(width: width)
        }
        .frame(width: width, height: 470)
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("VM2API QUOTA")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(s.platform.isEmpty ? "gateway" : s.platform.capitalized)
                    .font(.system(size: 18, weight: .bold))
            }
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(health.1).frame(width: 6, height: 6)
                Text(health.0).font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(health.1.opacity(0.10))
            .clipShape(Capsule())

            if state.refreshing { ProgressView().controlSize(.small) }
            Button { state.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Settings")
        }
    }

    // MARK: usage cards

    private var cards: some View {
        VStack(spacing: 10) {
            // pool of one: that account IS the current account — surface its estimates
            let single = s.pool.count == 1 ? s.pool[0] : nil
            QuotaCard(title: "5-hour usage",
                      usedPct: s.w5.pct,
                      status: s.w5.status,
                      resetText: WindowInfo.resetShort(s.w5.resetsAt),
                      est: single?.est5 ?? "")
            QuotaCard(title: "7-day usage",
                      usedPct: s.w7.pct,
                      status: s.w7.status,
                      resetText: WindowInfo.resetShort(s.w7.resetsAt),
                      est: single?.est7 ?? "")
            if !s.note.isEmpty {
                Text(s.note)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            if !s.hasPanel {
                Text("pool · billing · QoS need a panel credential — add one in settings ⚙")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: pool (only when more than one account)

    private var poolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "Pool", trailing: "\(s.pool.count) accounts")
            ForEach(s.pool.indices, id: \.self) { i in
                let a = s.pool[i]
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("\(a.id) (\(a.name))").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("5h \(a.u5)%")
                            .font(.system(size: 12, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color(Severity.color(forPct: a.u5, status: a.status5)))
                        Text("7d \(a.u7)%")
                            .font(.system(size: 12, design: .monospaced).weight(.semibold))
                            .foregroundStyle(Color(Severity.color(forPct: a.u7, status: a.status7)))
                        Text(Severity.tag(a.status5))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(Severity.color(forPct: a.u5, status: a.status5)))
                    }
                    Text("resets \(WindowInfo.resetShort(a.r5)) / \(WindowInfo.resetShort(a.r7))"
                         + (a.est5.isEmpty ? "" : " · est \(a.est5) / \(a.est7)"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: billing

    private var billingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "Billing",
                         trailing: "\(s.billing.source) · \(s.billing.currency)".uppercased())
            HStack(alignment: .firstTextBaseline) {
                Text("Today").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("\(s.billing.todayReq) req")
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                Text(s.billing.today)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
            }
            billingRow(title: "5h window", amount: s.billing.w5, requests: s.billing.w5Req)
            billingRow(title: "7d window", amount: s.billing.total, requests: s.billing.totalReq)
        }
    }

    private func billingRow(title: String, amount: String, requests: String) -> some View {
        HStack {
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(amount).font(.system(size: 11)).monospacedDigit()
            Text("·").font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(requests + " req").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    // MARK: quality of service

    private var qosSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quality of Service").font(.system(size: 12, weight: .semibold))
                    Text(s.qos.samples == 0 ? "No samples in the last hour" : "last 1 hour")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if s.qos.samples > 0 {
                    Text(String(format: "%.1f%% ok", s.qos.successPct))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(s.qos.successPct >= 99 ? .green : .orange)
                }
            }
            if s.qos.samples > 0 {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 4) {
                        DetailRow(label: "error rate", value: String(format: "%.1f%% · 429:%d 503:%d 529:%d", s.qos.errorPct, s.qos.c429, s.qos.c503, s.qos.c529))
                        DetailRow(label: "first byte", value: s.qos.ttft)
                        DetailRow(label: "duration", value: s.qos.duration)
                        DetailRow(label: "qps", value: s.qos.qps)
                        DetailRow(label: "tps", value: s.qos.tps)
                        if !s.qos.cache.isEmpty { DetailRow(label: "cache hit", value: s.qos.cache) }
                        if !s.qos.sticky.isEmpty { DetailRow(label: "sticky sessions", value: s.qos.sticky) }
                        if !s.qos.models.isEmpty {
                            VStack(spacing: 1) {
                                HStack {
                                    Text("model").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
                                    Text("req").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                                    Text("err").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                                    Text("ttft").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                                    Text("dur").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).frame(width: 58, alignment: .trailing)
                                    Spacer(minLength: 0)
                                }
                                ForEach(s.qos.models.indices, id: \.self) { j in
                                    let m = s.qos.models[j]
                                    HStack {
                                        Text(m.name).font(.system(size: 10, design: .monospaced)).frame(width: 76, alignment: .leading)
                                        Text(m.req).font(.system(size: 10, design: .monospaced)).frame(width: 48, alignment: .trailing)
                                        Text(m.err).font(.system(size: 10, design: .monospaced)).frame(width: 34, alignment: .trailing)
                                        Text(m.ttft).font(.system(size: 10, design: .monospaced)).frame(width: 58, alignment: .trailing)
                                        Text(m.dur).font(.system(size: 10, design: .monospaced)).frame(width: 58, alignment: .trailing)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }.padding(.top, 4)
                        }
                    }
                }
                .font(.system(size: 11))
            }
        }
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Text("vm2api-quota").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
            Text("updated " + timeStr(s.updatedAt))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.top, 16)
    }

    private func timeStr(_ d: Date) -> String {
        d == .distantPast ? "—" : {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
        }()
    }
}

// MARK: - App lifecycle

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = AppState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var monitor: Any?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.action = #selector(toggle)
        statusItem.button?.target = self
        statusItem.button?.toolTip = "vm2api quota"

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 440, height: 470)
        popover.contentViewController = NSHostingController(
            rootView: PanelView().environmentObject(state))

        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.close()
        }

        state.$snap
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderTitle() }
            .store(in: &cancellables)
        renderTitle()
        state.start()
    }

    private func renderTitle() {
        statusItem.button?.attributedTitle = BarTitle.attributed(state.snap, show7d: state.cfg.show7d)
        let s = state.snap
        statusItem.button?.toolTip = s.ok
            ? "vm2api quota — 5h \(s.w5.pct)% · 7d \(s.w7.pct)%"
            : "vm2api quota — not configured / error"
        if ProcessInfo.processInfo.environment["VMQUOTA_DEBUG_TITLE"] == "1" {
            let plain = s.ok
                ? "ok: \(s.w5.pct) \(state.cfg.show7d ? "\(s.w7.pct)" : "(7d hidden)") · pool \(s.pool.count) · qos \(s.qos.samples) samples"
                : "not ok: \(s.error.isEmpty ? "loading" : s.error)"
            fputs("[VmQuotaBar title] " + plain + "\n", stderr)
        }
    }

    @objc private func toggle() {
        if popover.isShown {
            popover.close()
        } else {
            popover.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            state.refresh()
        }
    }
}

// main
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
