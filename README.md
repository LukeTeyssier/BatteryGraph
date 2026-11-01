# Battery Graph

A small macOS app, styled like Activity Monitor's CPU history graph, that records your battery's charge and plots it over time.

It tracks three readings, and you can turn each line on or off by clicking its tile:

| Line | Source | Matches |
|---|---|---|
| **System Settings** (green, filled) | IOPowerSources API | The % in the menu bar and System Settings › Battery |
| **System Report SoC** (blue) | `system_profiler SPPowerDataType` | System Information › Hardware › Power › "State of Charge (%)" |
| **Raw Capacity** (orange) | AppleSmartBattery driver, `AppleRawCurrentCapacity / AppleRawMaxCapacity` | The actual mAh in the battery, unrounded |

Other features:
- Ranges from 10 minutes to 7 days, and a sample interval from 10 s to 5 min
- Hover over the graph to see the exact values at any moment
- Charging periods are tinted yellow
- Details: time remaining, cycle count, health, design and full-charge mAh, voltage, current, watts, temperature
- A menu bar item that shows the State of Charge
- History is saved to `~/Library/Application Support/BatteryGraph/history.jsonl` (the last 7 days) and keeps recording while the window is closed
- Export to CSV

## Build

You need macOS 13 (Ventura) or later, plus Xcode or the Command Line Tools (`xcode-select --install`).

```bash
cd BatteryGraph
./build.sh
open BatteryGraph.app
```

You can drag `BatteryGraph.app` into /Applications. To start it at login, go to System Settings › General › Login Items and add it.

Quit it from the menu bar item, or with ⌘Q while the window is in front. Closing the window leaves it recording in the menu bar.
