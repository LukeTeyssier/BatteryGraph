// Built-in help for BatteryGraph: a searchable help window with a topic sidebar.

import SwiftUI

enum HelpBlock {
    case p(String)               // paragraph (inline Markdown allowed: **bold**, *italic*, `code`)
    case h(String)               // sub-heading
    case bullets([String])
    case swatch(Color, String, String)   // colour key, label, explanation
    case tip(String)
}

struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let blocks: [HelpBlock]

    static func == (a: HelpTopic, b: HelpTopic) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    /// All the topic's text, for search.
    var searchText: String {
        ([title] + blocks.flatMap { b -> [String] in
            switch b {
            case .p(let s), .h(let s), .tip(let s): return [s]
            case .bullets(let a): return a
            case .swatch(_, let l, let e): return [l, e]
            }
        }).joined(separator: " ").lowercased()
    }
}

enum HelpContent {
    static let topics: [HelpTopic] = [
        HelpTopic(id: "overview", title: "Getting Started", icon: "battery.75", blocks: [
            .p("Battery Graph records your Mac's battery charge at regular intervals and draws it as a scrolling graph, like the CPU History graph in Activity Monitor."),
            .p("It starts recording as soon as you open it and keeps recording while the window is closed, as long as the app is running (look for the percentage in the menu bar)."),
            .h("The window at a glance"),
            .bullets([
                "**Reading tiles** (top): the current value of each of the three battery readings. Click a tile to show or hide its line on the graph.",
                "**Graph** (middle): charge history over the time range chosen in the toolbar. Hover over it to see exact values.",
                "**Details** (bottom): status, time remaining, cycle count, health, capacity, voltage, current, power and temperature.",
                "**Toolbar**: time range, sample interval, Export CSV, Clear History and Help.",
            ]),
            .tip("To have Battery Graph record all the time, add it in System Settings › General › Login Items."),
        ]),

        HelpTopic(id: "readings", title: "The Three Readings", icon: "chart.line.uptrend.xyaxis", blocks: [
            .p("macOS reports battery charge in more than one place, and the numbers don't always agree. Battery Graph shows all three so you can compare them."),
            .swatch(Series.ui.color, "System Settings",
                    "The percentage in the menu bar and in System Settings › Battery. macOS calculates and rounds it for display. Drawn as the filled green area."),
            .swatch(Series.soc.color, "System Report SoC",
                    "\"State of Charge (%)\" from System Information › Hardware › Power. Battery Graph reads it by running `system_profiler`, the same tool System Information uses, about every 25 seconds. It also appears in the menu bar item."),
            .swatch(Series.raw.color, "Raw Capacity",
                    "The charge currently in the battery divided by its full-charge capacity, both in mAh, straight from the battery controller. It isn't rounded, so it shows small changes the other two hide. Hidden by default."),
            .h("Why the numbers differ"),
            .bullets([
                "macOS may hold the menu bar figure at 100% while the battery tops off or rests just below full.",
                "With **Optimized Battery Charging** or a charge limit, the battery can pause around 80%. The readings then handle this differently.",
                "The raw mAh figures are measured against the battery's *current* full-charge capacity, which shrinks as the battery ages.",
            ]),
        ]),

        HelpTopic(id: "graph", title: "Reading the Graph", icon: "waveform.path.ecg", blocks: [
            .bullets([
                "The vertical axis runs from 0% at the bottom to 100% at the top, with gridlines at 25%, 50% and 75%.",
                "The newest reading is at the right edge (**now**). The left edge shows how far back the graph goes.",
                "**Yellow tint** with a yellow strip along the bottom marks times when the battery was charging.",
                "**Gaps** in a line mean no readings were taken, for example while the Mac was asleep or the app wasn't running.",
                "**Hover** over the graph to see the time, each visible reading and the charging state at that moment.",
            ]),
            .p("For long ranges (such as 7 days), readings that fall on the same pixel are averaged, so very brief changes can be smoothed out. Pick a shorter range to see them."),
        ]),

        HelpTopic(id: "controls", title: "Toolbar Controls", icon: "slider.horizontal.3", blocks: [
            .h("Range"),
            .p("How much history the graph shows: from 10 minutes up to 7 days."),
            .h("Sample"),
            .p("How often Battery Graph takes a reading: every 10 seconds, 30 seconds, 1 minute or 5 minutes. Shorter intervals give a more detailed graph. Battery charge changes slowly, so 30 seconds is usually plenty."),
            .h("Export CSV"),
            .p("Saves all recorded history to a spreadsheet file with columns for the time, each of the three readings, whether it was charging, and whether it was plugged in."),
            .h("Clear History"),
            .p("Permanently deletes all recorded history and starts again. This can't be undone, so export first if you want to keep it."),
        ]),

        HelpTopic(id: "details", title: "Battery Details", icon: "list.bullet.rectangle", blocks: [
            .bullets([
                "**Status**: Charging, Charged, Plugged in (not charging), or On battery.",
                "**Time left / Time to full**: macOS's estimate. Shows — while macOS is still calculating.",
                "**Cycles**: charge cycles so far. One cycle is using 100% of the battery's capacity, possibly spread over several charges.",
                "**Health**: battery condition and Maximum Capacity, as shown in System Settings › Battery › Battery Health.",
                "**Design**: the capacity the battery had when new, in mAh.",
                "**Full charge**: what the battery can hold now, in mAh. Divide it by Design for a rough idea of wear.",
                "**Voltage / Current / Power**: live electrical readings. Negative current and power mean the battery is discharging, positive means it's charging.",
                "**Temp**: battery temperature in °C.",
            ]),
        ]),

        HelpTopic(id: "menubar", title: "Menu Bar Item", icon: "menubar.rectangle", blocks: [
            .p("Battery Graph puts the System Report State of Charge in the menu bar. Click it to see all three readings, open the graph window, or quit the app."),
            .p("Closing the graph window doesn't quit the app. It keeps recording from the menu bar. To stop recording, choose **Quit BatteryGraph** from the menu bar item, or press ⌘Q while the window is in front."),
        ]),

        HelpTopic(id: "data", title: "Your Data", icon: "externaldrive", blocks: [
            .p("History is stored only on your Mac, in:"),
            .p("`~/Library/Application Support/BatteryGraph/history.jsonl`"),
            .p("Battery Graph keeps the last 7 days and discards older readings automatically. Nothing is sent over the network."),
            .p("Your chosen range, sample interval and visible lines are remembered between launches."),
        ]),

        HelpTopic(id: "troubleshooting", title: "Troubleshooting", icon: "wrench.and.screwdriver", blocks: [
            .h("\"No internal battery found\""),
            .p("Your Mac has no built-in battery (for example an iMac, Mac mini or Mac Studio), so there's nothing to record."),
            .h("A reading shows —"),
            .p("That value isn't available on this Mac. Some details only exist on Apple silicon or only on Intel Macs. System Report SoC can take up to half a minute to appear after launch."),
            .h("The graph has gaps"),
            .p("Readings stop while the Mac is asleep or the app isn't running. Add Battery Graph to Login Items to record continuously while the Mac is awake."),
            .h("The graph is empty"),
            .p("The app has only just started, or the chosen range is shorter than the time since the last reading. Wait a moment or choose a longer range."),
            .h("macOS says the app can't be opened"),
            .p("Battery Graph is built and signed on your own Mac by `build.sh`. If you copied it from another Mac, Control-click the app, choose **Open**, then confirm."),
        ]),

        HelpTopic(id: "shortcuts", title: "Keyboard Shortcuts", icon: "keyboard", blocks: [
            .bullets([
                "**⌘?**: Open this help",
                "**⌘N**: Open a new graph window",
                "**⌘W**: Close the window (recording continues)",
                "**⌘Q**: Quit and stop recording",
            ]),
        ]),
    ]
}

// MARK: - Views

struct HelpView: View {
    @State private var selection: HelpTopic? = HelpContent.topics.first
    @State private var query = ""

    private var filtered: [HelpTopic] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return HelpContent.topics }
        return HelpContent.topics.filter { $0.searchText.contains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.icon).tag(topic)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .overlay {
                if filtered.isEmpty {
                    Text("No matching topics").foregroundStyle(.secondary)
                }
            }
        } detail: {
            if let topic = selection {
                HelpTopicView(topic: topic)
            } else {
                Text("Select a topic").foregroundStyle(.secondary)
            }
        }
        .searchable(text: $query, placement: .sidebar, prompt: "Search Help")
        .onChange(of: query) { _ in
            if let sel = selection, !filtered.contains(sel) { selection = filtered.first }
        }
        .frame(minWidth: 640, minHeight: 440)
    }
}

struct HelpTopicView: View {
    let topic: HelpTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(topic.title, systemImage: topic.icon)
                    .font(.title.weight(.semibold))
                    .padding(.bottom, 4)
                ForEach(topic.blocks.indices, id: \.self) { i in
                    block(topic.blocks[i])
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .navigationTitle(topic.title)
    }

    @ViewBuilder
    private func block(_ b: HelpBlock) -> some View {
        switch b {
        case .p(let s):
            Text(LocalizedStringKey(s)).fixedSize(horizontal: false, vertical: true)
        case .h(let s):
            Text(LocalizedStringKey(s)).font(.headline).padding(.top, 6)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items.indices, id: \.self) { i in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(LocalizedStringKey(items[i])).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .swatch(let color, let label, let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 14, height: 14).padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.headline).foregroundStyle(color)
                    Text(LocalizedStringKey(text)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        case .tip(let s):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lightbulb").foregroundStyle(.yellow)
                Text(LocalizedStringKey(s)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
        }
    }
}

/// A button that opens the help window; used in the Help menu, the toolbar and the menu bar item.
struct OpenHelpButton: View {
    @Environment(\.openWindow) private var openWindow
    var title = "Battery Graph Help"
    var body: some View {
        Button(title) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "help")
        }
    }
}
