// BatteryGraph — an Activity Monitor–style battery charge history graph for macOS.
//
// It graphs three readings over time:
//   • System Settings %   — the percentage shown in the menu bar / System Settings (IOPowerSources)
//   • System Report SoC % — "State of Charge (%)" from System Information (system_profiler SPPowerDataType)
//   • Raw capacity %      — AppleRawCurrentCapacity / AppleRawMaxCapacity (mAh) from the AppleSmartBattery driver
//
// Build with ./build.sh (requires Xcode or the Command Line Tools, macOS 13+).

import SwiftUI
import AppKit
import IOKit
import IOKit.ps
import UniformTypeIdentifiers

// MARK: - Model

struct BatterySample: Codable, Equatable {
    var t: Date
    var ui: Double?        // System Settings / menu bar %
    var soc: Double?       // System Report "State of Charge (%)"
    var raw: Double?       // raw mAh-based %
    var charging: Bool
    var plugged: Bool
}

struct BatteryDetails {
    var uiPercent: Double?
    var socPercent: Double?
    var rawPercent: Double?
    var isCharging = false
    var externalConnected = false
    var fullyCharged = false
    var cycleCount: Int?
    var designCapacity: Int?      // mAh
    var rawMaxCapacity: Int?      // mAh (full charge capacity)
    var rawCurrentCapacity: Int?  // mAh
    var voltage: Int?             // mV
    var amperage: Int?            // mA (negative = discharging)
    var temperatureC: Double?
    var timeRemaining: Int?       // minutes
    var condition: String?
    var maxCapacityPercent: String?   // "Maximum Capacity" from System Report
    var hasBattery = true
}

enum Series: String, CaseIterable, Identifiable {
    case ui, soc, raw
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ui:  return "System Settings"
        case .soc: return "System Report SoC"
        case .raw: return "Raw Capacity"
        }
    }
    var color: Color {
        switch self {
        case .ui:  return Color(red: 0.20, green: 0.90, blue: 0.30)
        case .soc: return Color(red: 0.30, green: 0.65, blue: 1.00)
        case .raw: return Color(red: 1.00, green: 0.60, blue: 0.15)
        }
    }
    func value(_ s: BatterySample) -> Double? {
        switch self {
        case .ui:  return s.ui
        case .soc: return s.soc
        case .raw: return s.raw
        }
    }
}

// MARK: - Battery reading

enum BatteryReader {
    private static func int(_ v: Any?) -> Int? {
        guard let n = v as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: n.int64Value)
    }

    /// Cache for system_profiler, which is comparatively slow (~0.3–1 s).
    private static var lastProfilerRun = Date.distantPast
    private static var cachedProfiler: (soc: Double?, condition: String?, maxCap: String?) = (nil, nil, nil)
    private static let lock = NSLock()

    static func read() -> BatteryDetails {
        var d = BatteryDetails()

        // 1) IOPowerSources — what System Settings and the menu bar show.
        var foundBattery = false
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for ps in list {
                guard let desc = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                      (desc["Type"] as? String) == "InternalBattery" else { continue }
                foundBattery = true
                if let cur = int(desc["Current Capacity"]), let mx = int(desc["Max Capacity"]), mx > 0 {
                    d.uiPercent = Double(cur) / Double(mx) * 100
                }
                d.isCharging = (desc["Is Charging"] as? Bool) ?? false
                d.externalConnected = (desc["Power Source State"] as? String) == "AC Power"
                d.fullyCharged = (desc["Is Charged"] as? Bool) ?? false
                if let h = desc["BatteryHealth"] as? String { d.condition = h }
                if let ttE = int(desc["Time to Empty"]), ttE > 0, !d.externalConnected { d.timeRemaining = ttE }
                if let ttF = int(desc["Time to Full Charge"]), ttF > 0, d.isCharging { d.timeRemaining = ttF }
            }
        }
        d.hasBattery = foundBattery

        // 2) AppleSmartBattery IORegistry entry — raw mAh numbers and hardware details.
        var registrySoC: Double?
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any] {
                d.cycleCount = int(dict["CycleCount"])
                d.designCapacity = int(dict["DesignCapacity"])
                // Apple Silicon exposes mAh in AppleRaw*; Intel Macs use Max/CurrentCapacity as mAh.
                d.rawMaxCapacity = int(dict["AppleRawMaxCapacity"]) ?? int(dict["MaxCapacity"])
                d.rawCurrentCapacity = int(dict["AppleRawCurrentCapacity"]) ?? int(dict["CurrentCapacity"])
                d.voltage = int(dict["Voltage"])
                if let a = int(dict["InstantAmperage"]) ?? int(dict["Amperage"]) {
                    d.amperage = Int(Int32(truncatingIfNeeded: a))
                }
                if let t = int(dict["Temperature"]) { d.temperatureC = Double(t) / 100.0 }
                if let bd = dict["BatteryData"] as? [String: Any], let s = int(bd["StateOfCharge"]) {
                    registrySoC = Double(s)
                }
                if let rc = d.rawCurrentCapacity, let rm = d.rawMaxCapacity, rm > 0 {
                    d.rawPercent = min(100, Double(rc) / Double(rm) * 100)
                }
                if d.timeRemaining == nil, let tr = int(dict["TimeRemaining"]), tr > 0, tr < 65535 {
                    d.timeRemaining = tr
                }
            }
        }

        // 3) System Report — "State of Charge (%)" exactly as System Information shows it.
        lock.lock()
        let needProfiler = Date().timeIntervalSince(lastProfilerRun) >= 25
        lock.unlock()
        if needProfiler {
            let p = runSystemProfiler()
            lock.lock()
            cachedProfiler = p
            lastProfilerRun = Date()
            lock.unlock()
        }
        lock.lock()
        let prof = cachedProfiler
        lock.unlock()
        d.socPercent = prof.soc ?? registrySoC
        if let c = prof.condition { d.condition = c }
        d.maxCapacityPercent = prof.maxCap
        return d
    }

    private static func runSystemProfiler() -> (soc: Double?, condition: String?, maxCap: String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPPowerDataType", "-json"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (nil, nil, nil) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPPowerDataType"] as? [[String: Any]] else { return (nil, nil, nil) }

        var soc: Double?, cond: String?, maxCap: String?
        for item in items {
            if let ci = item["sppower_battery_charge_info"] as? [String: Any] {
                if let n = ci["sppower_battery_state_of_charge"] as? NSNumber { soc = n.doubleValue }
                else if let s = ci["sppower_battery_state_of_charge"] as? String { soc = Double(s) }
            }
            if let hi = item["sppower_battery_health_info"] as? [String: Any] {
                cond = hi["sppower_battery_health"] as? String
                maxCap = hi["sppower_battery_health_maximum_capacity"] as? String
            }
        }
        return (soc, cond, maxCap)
    }
}

// MARK: - Store (sampling + persistence)

final class BatteryStore: ObservableObject {
    @Published var samples: [BatterySample] = []
    @Published var details = BatteryDetails()
    @Published var interval: Double {
        didSet { UserDefaults.standard.set(interval, forKey: "interval"); restartTimer() }
    }

    static let maxAge: TimeInterval = 7 * 24 * 3600
    private var timer: Timer?
    private var activity: NSObjectProtocol?
    private let queue = DispatchQueue(label: "battery.sampler")
    private let fileURL: URL

    init() {
        let saved = UserDefaults.standard.double(forKey: "interval")
        interval = saved > 0 ? saved : 30

        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BatteryGraph", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.jsonl")

        // Keep sampling while the window is hidden (prevents App Nap from pausing the timer).
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep], reason: "Recording battery history")

        load()
        sample()
        restartTimer()
    }

    var gapLimit: TimeInterval { max(interval * 3, 120) }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func sample() {
        queue.async { [weak self] in
            let d = BatteryReader.read()
            let s = BatterySample(t: Date(), ui: d.uiPercent, soc: d.socPercent, raw: d.rawPercent,
                                  charging: d.isCharging, plugged: d.externalConnected)
            DispatchQueue.main.async {
                guard let self else { return }
                self.details = d
                guard d.hasBattery else { return }
                self.samples.append(s)
                let cutoff = Date().addingTimeInterval(-Self.maxAge)
                if let first = self.samples.first, first.t < cutoff {
                    self.samples.removeAll { $0.t < cutoff }
                }
                self.append(s)
            }
        }
    }

    // JSON-lines file in ~/Library/Application Support/BatteryGraph/history.jsonl
    private func load() {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        samples = text.split(separator: "\n").compactMap {
            try? dec.decode(BatterySample.self, from: Data($0.utf8))
        }.filter { $0.t >= cutoff }.sorted { $0.t < $1.t }
        rewrite()
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }

    private func rewrite() {
        let e = encoder()
        let lines = samples.compactMap { try? e.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
        try? (lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
            .write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func append(_ s: BatterySample) {
        guard let data = try? encoder().encode(s) else { return }
        let line = data + Data("\n".utf8)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: fileURL)
        }
    }

    func clear() {
        samples.removeAll()
        rewrite()
        sample()
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "battery-history.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let f = ISO8601DateFormatter()
        func v(_ d: Double?) -> String { d.map { String(format: "%.2f", $0) } ?? "" }
        var csv = "timestamp,system_settings_pct,system_report_soc_pct,raw_capacity_pct,charging,plugged_in\n"
        for s in samples {
            csv += "\(f.string(from: s.t)),\(v(s.ui)),\(v(s.soc)),\(v(s.raw)),\(s.charging),\(s.plugged)\n"
        }
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Graph

struct GraphView: View {
    let samples: [BatterySample]
    let window: TimeInterval
    let enabled: Set<Series>
    let gapLimit: TimeInterval
    @State private var hoverX: CGFloat?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { timeline in
            Canvas { ctx, size in draw(&ctx, size: size, now: timeline.date) }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): hoverX = p.x
            case .ended: hoverX = nil
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.gray.opacity(0.5), lineWidth: 1))
    }

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, now: Date) {
        let start = now.addingTimeInterval(-window)
        let w = size.width, h = size.height
        func x(_ t: Date) -> CGFloat { CGFloat(t.timeIntervalSince(start) / window) * w }
        func y(_ v: Double) -> CGFloat { h * (1 - CGFloat(max(0, min(100, v)) / 100)) }

        // Background + grid (Activity Monitor style)
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
        var grid = Path()
        for i in 1..<4 {
            let gy = y(Double(i) * 25)
            grid.move(to: CGPoint(x: 0, y: gy)); grid.addLine(to: CGPoint(x: w, y: gy))
        }
        for i in 1..<6 {
            let gx = w * CGFloat(i) / 6
            grid.move(to: CGPoint(x: gx, y: 0)); grid.addLine(to: CGPoint(x: gx, y: h))
        }
        ctx.stroke(grid, with: .color(Color.white.opacity(0.13)), lineWidth: 1)

        let visible = samples.filter { $0.t >= start.addingTimeInterval(-gapLimit) }

        // Charging periods: faint yellow band + strip along the bottom
        for (a, b) in zip(visible, visible.dropFirst()) where a.charging && b.t.timeIntervalSince(a.t) <= gapLimit {
            let r = CGRect(x: x(a.t), y: 0, width: max(1, x(b.t) - x(a.t)), height: h)
            ctx.fill(Path(r), with: .color(Color.yellow.opacity(0.07)))
            ctx.fill(Path(CGRect(x: r.minX, y: h - 3, width: r.width, height: 3)), with: .color(Color.yellow.opacity(0.8)))
        }

        // Series — drawn back-to-front so System Settings (filled) sits underneath
        for series in [Series.ui, .soc, .raw] where enabled.contains(series) {
            for seg in segments(visible, series: series, x: x, y: y) where !seg.isEmpty {
                var line = Path()
                line.addLines(seg)
                if series == .ui {
                    var area = line
                    area.addLine(to: CGPoint(x: seg.last!.x, y: h))
                    area.addLine(to: CGPoint(x: seg.first!.x, y: h))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [series.color.opacity(0.55), series.color.opacity(0.15)]),
                        startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
                }
                if seg.count == 1 {
                    ctx.fill(Path(ellipseIn: CGRect(x: seg[0].x - 1.5, y: seg[0].y - 1.5, width: 3, height: 3)),
                             with: .color(series.color))
                } else {
                    ctx.stroke(line, with: .color(series.color), lineWidth: series == .ui ? 1.5 : 1.25)
                }
            }
        }

        // Axis labels
        for pct in [25, 50, 75] {
            ctx.draw(Text("\(pct)%").font(.system(size: 9)).foregroundColor(.white.opacity(0.45)),
                     at: CGPoint(x: 4, y: y(Double(pct)) - 2), anchor: .bottomLeading)
        }
        ctx.draw(Text(Self.spanLabel(window)).font(.system(size: 9)).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: 4, y: h - 5), anchor: .bottomLeading)
        ctx.draw(Text("now").font(.system(size: 9)).foregroundColor(.white.opacity(0.45)),
                 at: CGPoint(x: w - 4, y: h - 5), anchor: .bottomTrailing)

        // Hover read-out
        if let hx = hoverX, !visible.isEmpty {
            let t = start.addingTimeInterval(Double(hx / w) * window)
            if let nearest = visible.min(by: { abs($0.t.timeIntervalSince(t)) < abs($1.t.timeIntervalSince(t)) }),
               abs(nearest.t.timeIntervalSince(t)) <= max(gapLimit, window / Double(w) * 4) {
                let nx = x(nearest.t)
                var cursor = Path()
                cursor.move(to: CGPoint(x: nx, y: 0)); cursor.addLine(to: CGPoint(x: nx, y: h))
                ctx.stroke(cursor, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                var lines: [(String, Color)] = [(Self.timeFmt.string(from: nearest.t), .white)]
                for s in Series.allCases where enabled.contains(s) {
                    lines.append(("\(s.label): " + (s.value(nearest).map { String(format: "%.1f%%", $0) } ?? "—"), s.color))
                }
                lines.append((nearest.charging ? "Charging" : (nearest.plugged ? "Plugged in" : "On battery"), .yellow))

                let boxW: CGFloat = 190, lineH: CGFloat = 14
                let boxH = CGFloat(lines.count) * lineH + 8
                let bx = nx + 10 + boxW > w ? nx - 10 - boxW : nx + 10
                let box = CGRect(x: bx, y: 8, width: boxW, height: boxH)
                ctx.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(Color(white: 0.12).opacity(0.92)))
                ctx.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(.white.opacity(0.25)))
                for (i, l) in lines.enumerated() {
                    ctx.draw(Text(l.0).font(.system(size: 10, weight: i == 0 ? .semibold : .regular)).foregroundColor(l.1),
                             at: CGPoint(x: bx + 8, y: 12 + CGFloat(i) * lineH), anchor: .topLeading)
                }
            }
        }
    }

    /// Splits samples into continuous polylines (breaking on gaps/missing values) and averages
    /// samples that fall on the same pixel column so long histories stay fast to draw.
    private func segments(_ samples: [BatterySample], series: Series,
                          x: @escaping (Date) -> CGFloat, y: @escaping (Double) -> CGFloat) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        var bucketCol = Int.min, bucketSum = 0.0, bucketN = 0, bucketX: CGFloat = 0
        var lastT: Date?

        func flushBucket() {
            if bucketN > 0 { current.append(CGPoint(x: bucketX, y: y(bucketSum / Double(bucketN)))) }
            bucketN = 0; bucketSum = 0
        }
        func breakSegment() {
            flushBucket()
            if !current.isEmpty { result.append(current) }
            current = []
            bucketCol = Int.min
        }

        for s in samples {
            guard let v = series.value(s) else { breakSegment(); lastT = nil; continue }
            if let lt = lastT, s.t.timeIntervalSince(lt) > gapLimit { breakSegment() }
            lastT = s.t
            let px = x(s.t)
            let col = Int(px.rounded(.down))
            if col != bucketCol { flushBucket(); bucketCol = col }
            bucketSum += v; bucketN += 1; bucketX = px
        }
        breakSegment()
        return result
    }

    static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    static func spanLabel(_ w: TimeInterval) -> String {
        if w < 3600 { return "−\(Int(w / 60)) min" }
        if w < 86400 { return "−\(Int(w / 3600)) h" }
        return "−\(Int(w / 86400)) d"
    }
}

// MARK: - Main window

struct ReadoutTile: View {
    let series: Series
    let value: Double?
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(series.color.opacity(isOn ? 1 : 0.25)).frame(width: 10, height: 10)
                    Text(series.label).font(.caption).foregroundStyle(.secondary)
                }
                Text(value.map { String(format: "%.1f%%", $0) } ?? "—")
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(isOn ? series.color : .secondary)
                Text(subtitle).font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(isOn ? series.color.opacity(0.6) : Color.gray.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help("Click to show/hide this line on the graph")
    }
}

struct ContentView: View {
    @EnvironmentObject var store: BatteryStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage("window") private var window: Double = 3600
    @AppStorage("showUI") private var showUI = true
    @AppStorage("showSoC") private var showSoC = true
    @AppStorage("showRaw") private var showRaw = false

    private let windows: [(String, Double)] = [
        ("10 min", 600), ("1 hour", 3600), ("3 hours", 10800), ("6 hours", 21600),
        ("12 hours", 43200), ("24 hours", 86400), ("3 days", 259200), ("7 days", 604800),
    ]

    var enabled: Set<Series> {
        var s = Set<Series>()
        if showUI { s.insert(.ui) }
        if showSoC { s.insert(.soc) }
        if showRaw { s.insert(.raw) }
        return s
    }

    var body: some View {
        let d = store.details
        VStack(spacing: 12) {
            if !d.hasBattery {
                Text("No internal battery found on this Mac.").foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                ReadoutTile(series: .ui, value: d.uiPercent, subtitle: "Menu bar / System Settings", isOn: $showUI)
                ReadoutTile(series: .soc, value: d.socPercent, subtitle: "System Information › Power", isOn: $showSoC)
                ReadoutTile(series: .raw, value: d.rawPercent,
                            subtitle: d.rawCurrentCapacity.flatMap { c in d.rawMaxCapacity.map { "\(c) / \($0) mAh" } } ?? "mAh-based",
                            isOn: $showRaw)
            }

            GraphView(samples: store.samples, window: window, enabled: enabled, gapLimit: store.gapLimit)
                .frame(minHeight: 220)

            HStack(spacing: 18) {
                LegendItem(color: .yellow, text: "Charging")
                Spacer()
                stat("Status", d.isCharging ? "Charging" : (d.fullyCharged ? "Charged" : (d.externalConnected ? "Plugged in (not charging)" : "On battery")))
                stat(d.isCharging ? "Time to full" : "Time left", d.timeRemaining.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "—")
                stat("Cycles", d.cycleCount.map(String.init) ?? "—")
                stat("Health", [d.condition, d.maxCapacityPercent].compactMap { $0 }.joined(separator: " · ").nilIfEmpty ?? "—")
            }
            HStack(spacing: 18) {
                Spacer()
                stat("Design", d.designCapacity.map { "\($0) mAh" } ?? "—")
                stat("Full charge", d.rawMaxCapacity.map { "\($0) mAh" } ?? "—")
                stat("Voltage", d.voltage.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—")
                stat("Current", d.amperage.map { "\($0) mA" } ?? "—")
                stat("Power", (d.voltage.flatMap { v in d.amperage.map { String(format: "%.1f W", Double(v) * Double($0) / 1e6) } }) ?? "—")
                stat("Temp", d.temperatureC.map { String(format: "%.1f °C", $0) } ?? "—")
            }
        }
        .padding(14)
        .frame(minWidth: 720, minHeight: 440)
        .toolbar {
            ToolbarItemGroup {
                Picker("Range", selection: $window) {
                    ForEach(windows.indices, id: \.self) { i in Text(windows[i].0).tag(windows[i].1) }
                }
                .help("Time span shown on the graph")
                Picker("Sample", selection: $store.interval) {
                    Text("Every 10 s").tag(10.0)
                    Text("Every 30 s").tag(30.0)
                    Text("Every 1 min").tag(60.0)
                    Text("Every 5 min").tag(300.0)
                }
                .help("How often the battery is sampled")
                Button { store.exportCSV() } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { store.clear() } label: { Label("Clear History", systemImage: "trash") }
                Button { openWindow(id: "help") } label: { Label("Help", systemImage: "questionmark.circle") }
                    .help("Battery Graph Help (⌘?)")
            }
        }
        .navigationTitle("Battery History")
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }
}

struct LegendItem: View {
    let color: Color; let text: String
    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(color).frame(width: 14, height: 3)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - App

@main
struct BatteryGraphApp: App {
    @StateObject private var store = BatteryStore()

    var body: some Scene {
        WindowGroup("Battery History") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 860, height: 520)
        .commands {
            CommandGroup(replacing: .help) {
                OpenHelpButton().keyboardShortcut("?", modifiers: .command)
            }
        }

        Window("Battery Graph Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 780, height: 540)

        MenuBarExtra {
            let d = store.details
            Text("System Settings: " + (d.uiPercent.map { String(format: "%.0f%%", $0) } ?? "—"))
            Text("System Report SoC: " + (d.socPercent.map { String(format: "%.0f%%", $0) } ?? "—"))
            Text("Raw capacity: " + (d.rawPercent.map { String(format: "%.1f%%", $0) } ?? "—"))
            Divider()
            Button("Show Graph") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
            }
            OpenHelpButton(title: "Help")
            Button("Quit BatteryGraph") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Text(store.details.socPercent.map { String(format: "%.0f%%", $0) } ?? "🔋")
        }
    }
}
