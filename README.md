# island4mac plugins

Plugins for [island4mac](https://github.com/nyaaorick/island4mac), the macOS notch "Dynamic Island". Install them in the app under **Settings > Plugins**, then turn a plugin's tab on under **Settings > Tabs**.

A plugin says *what* to show, never *how*: the island draws everything in its own look, so a plugin can't set colors, fonts or layout (a picture says only where it comes from), and every plugin looks like the rest of the island.

## Writing a plugin with IslandKit

IslandKit is the Swift SDK in this repo. You declare what the plugin shows; IslandKit runs it, shows the new `body` whenever your state changes and sends the island only what changed.

```swift
import IslandKit

@main
struct TimerPlugin: IslandPlugin {
    static let id = "timer"
    static let name = "Timer"
    static let symbol = "timer"
    static let version = "2.0.0"

    @State var end: Date? = nil
    @Stored("last-minutes") var lastMinutes: Int? = nil

    var body: some IslandContent {
        if let end {
            Countdown(to: end, total: 300, symbol: "timer")
            Alarm(at: end) {
                Island.popup("Time's up", symbol: "bell.fill")
                self.end = nil
            }
            Button("Stop", symbol: "stop.fill", confirm: "Stop the timer?") { self.end = nil }
        }
        Row("5 min", symbol: "play.circle") { end = Island.now.addingTimeInterval(300) }
    }
}
```

[`timer/`](timer/Sources/TimerPlugin.swift) is the complete version, with presets, a custom length, and pause and resume.

### Getting started

```bash
git clone https://github.com/nyaaorick/island4mac-plugins && cd island4mac-plugins
swift build -c release --product island-plugin     # the tool: .build/release/island-plugin
.build/release/island-plugin new my-plugin         # a package that builds and runs as it is
cd my-plugin && ../.build/release/island-plugin dev
```

`dev` builds the plugin, installs it into the app and turns it into a live preview. Every time you save, it builds and installs it again, and the app restarts it. Turn its tab on under **Settings > Tabs** to see it.

| Command | What it does |
|---|---|
| `island-plugin new <id> [--name] [--symbol]` | Creates a plugin package in `./<id>` |
| `island-plugin dev [--dev]` | Builds, installs into the app (`--dev`: into the dev app, "island4mac Dev"), and does it again on every change |
| `island-plugin validate [--all]` | Builds and checks the id, name, symbol and version |
| `island-plugin build [--all]` | Builds it universal and signed into `build/<id>/` and `build/<id>.zip` |

You never write `plugin.json`: `build` and `dev` run your program with `--describe` and write it from your code.

### What a plugin can show

| Element | Shows |
|---|---|
| `Compact(symbol:text:progress:image:state:)` | Beside the notch while the island is collapsed. `progress` (0 to 1) draws a ring. One at a time; the last one in `body` wins |
| `Countdown(to:total:symbol:)` | A countdown beside the notch that the island runs itself. In place of a `Compact` |
| `Row(_:subtitle:symbol:image:state:detail:progress:id:actions:action:)` | A row in the plugin's tab. With an action it can be tapped. The subtitle shows up to 3 lines. `actions` are secondary actions (`RowAction("Delete", symbol: "trash", confirm: "Delete it?") { … }`), shown on hover and in its context menu; one with `confirm` asks first. `detail` is short text at the right edge (a time, a count); `progress` (0 to 1) a ring around the symbol. Up to 50 rows |
| `Section(_:symbol:detail:)` | A heading over the rows after it: a caption, never tapped |
| `Toggle(_:subtitle:symbol:isOn:id:set:)` | A row with a switch at its end. A tap on either hands `set` the other value; show it by changing what `isOn` is made from |
| `Card(_:subtitle:symbol:image:preview:file:state:id:actions:action:)` | A card: a row turned on its side, with a large `preview` (`.text(…)` or `.image(…)`). Cards sit in one row above the rows and scroll sideways. With a `file:` it drags out as that file. Up to 50. Older apps show them as rows |
| `Media(_:artist:album:artwork:app:playing:elapsed:at:duration:rate:lyrics:control:seek:)` | What plays, drawn with the island's own player (artwork, lyrics, progress, controls, spectrum) and beside the notch. Say where the track is (`elapsed` as of `at`); the island counts on by itself. `lyrics` are `LyricLine("…", at: seconds)`. Taps come back to `control` (`.playPause`, `.next`, `.previous`) and `seek` |
| `Button(_:symbol:confirm:id:action:)` | A button under the rows. With `confirm`, the island asks first. Buttons alone in a tab show larger, in its middle |
| `TextField(_:text:id:onSubmit:)` | The tab's one text field. Return hands its text to `onSubmit` |
| `Alarm(at:id:perform:)` | Shows nothing. Runs `perform` once when the time comes, as long as it's still in `body` |

`body` can use `if`, `if let`, `switch` and `for`. To reuse a piece, make a struct that conforms to `IslandComponent` and give it a `body`; pass it `$state` to let it change your `@State`.

A state (`state:` on a row, a card or a `Compact`) says what it is up to, and the island draws it: `.working` turns an arc in place of the symbol, `.attention` pulses the symbol (and a row's `detail`) in the island's attention color, `.done` and `.failed` color it. With a state, a row's first subtitle line is its status line, in that color. A plugin never picks a color, so every plugin's "needs you" looks the same. Older apps show the row as it is.

Pictures (`image:`) say only where they come from: `.file(path)` (the island makes a thumbnail), `.app(bundleID)` (that app's icon) or `.url("https://…")`. The island sizes, crops and caches them.

- **Ids:** taps reach the closure of the element that was tapped. Rows and buttons get an id from their place and title; give rows made in a loop an `id:` of their own so a tap still finds them when the list changes.
- **Text limits:** text is cut at 200 characters.

### State and effects

| API | Use |
|---|---|
| `@State var x = …` | A value the plugin changes. Changing it shows the new `body`. It must be `Codable` |
| `@Stored("key") var x = …` | Kept on disk in the plugin's data folder, across runs and updates |
| `Island.popup(_:symbol:seconds:)` | Shown beside the notch for 1 to 10 seconds (3 if you don't say) |
| `Island.open(hold:)` | Opens the island on the plugin's tab, at most every 10 seconds, if the user allows it. With `hold: true` it stays open, without closing on its own, until `Island.close()` (something waiting for an answer) |
| `Island.close()` | Closes the island open on the plugin's tab: one held open, unless the pointer is on it; one the user opened, at once (after a paste) |
| `Island.now` | The time `body` is rendered for. Use it rather than `Date()` |
| `Island.isTabVisible` | Whether the tab is open. Update often only while it is |
| `Island.dataDirectory` | A folder of the plugin's own |
| `Island.log(_:)` | Writes to stderr. If the plugin stops, the island shows the last lines as the reason |
| `await Shell.run("docker", ["ps"])` | Runs a program (found on PATH, or in Homebrew's and the system's folders; `Shell.which` tells) off the main thread and hands back its `status`, `output` and `error`. An on-demand plugin isn't stopped while one runs |
| `Island.refresh()` | Shows `body` again, when something other than @State changed (an object of your own, a server) |
| `func onStart()` | Called once when the plugin starts (not for `--describe`): start servers, timers, subscriptions |
| `static let background = true` | Runs while turned on in Settings, whether or not its tab is one of the user's |
| `static let priority = NotchPriority.high` | Its compact content shows ahead of popups and music |
| `static let acceptsDrops = true` + `func onDrop(paths:urls:)` | Files, text and links can be dropped on its tab. The island opens on it when a drag nears the notch, shows where to drop, and hands over files as paths, text saved as a file in the data folder (`Drops/`), and links |

### Settings

Declare a setting with `@Preference`. It shows in the app under **Settings > Plugins**, drawn like every other setting, and the plugin gets its value. The property's name is its key and its value is the default.

```swift
@Preference("API key", secure: true, required: true) var apiKey = ""   // hidden, kept in the Keychain
@Preference("Refresh every", options: [1, 5, 15]) var minutes = 5      // a menu
@Preference("Keep for", options: [(24, "A day"), (168, "A week")]) var hours = 24   // a menu with labels
@Preference("Days", range: 1...7) var days = 3                         // a slider
@Preference("Celsius") var celsius = true                              // a switch
```

With `required: true`, the island doesn't start the plugin until it's filled in, and the plugin's tab points to Settings.

### Running only when needed

By default a plugin runs while its tab is on. With `static let lifecycle = Lifecycle.onDemand` it runs only when needed:

- its tab opens
- a row or button is tapped
- an `Alarm` or a `@Fetched` refresh is due
- a setting changes

Each time, it shows what it has, hands the island its timeline and quits. The island keeps showing what it left, and `@State` is saved until the next run.

```swift
var timeline: [Date] { [lunch, review] }   // times when body looks different
```

The island switches to `body` as rendered for each time in `timeline` by itself. During that render, `Island.now` is that time. A countdown, a calendar or a reminder therefore uses no process at all between changes. Leave `timeline` out if nothing changes on its own.

### Data from the web

`@Fetched` keeps JSON from the web fresh and cached. Opening the plugin shows the last result at once and refreshes it when it's older than `every`. While it loads with nothing to show, or if it fails, the island shows its standard "loading" or "couldn't load" row.

```swift
@Preference("City") var city = "Paris"
@Fetched(Forecast.self, from: "https://wttr.in/{city}?format=j1", every: .minutes(30)) var forecast

var body: some IslandContent {
    if let forecast { Compact(symbol: "sun.max", text: forecast.summary) }
    Button("Refresh") { $forecast.refresh() }
}
```

`{key}` in the address or a header is replaced by that `@Preference`'s value. `$forecast` gives `isLoading`, `error`, `updated` and `refresh()`. An on-demand plugin is woken for each refresh. [`github-status/`](github-status/Sources/GitHubStatus.swift) is a complete example.

### Which app versions it needs

`build` writes the oldest protocol the plugin needs into its `plugin.json`, and older versions of the app won't install it:

| Protocol | Needed for |
|---|---|
| 1 | Everything else |
| 2 | `@Preference` |
| 3 | `lifecycle = .onDemand` (`@Fetched` works with any version; the loading row needs 3) |
| 4 | `background`, `priority` (pictures and row actions work with any version; older apps leave them out) |
| 5 | `acceptsDrops`, and a `body` that shows `Media` (an older app shows nothing for it). Cards work with any version, as rows on older apps |
| 6 | Nothing: `state` and `detail` work with any version, and show only on 6 |
| 7 | Nothing: `Section`, `Toggle` and `progress` work with any version (as plain rows before 7). A `RowAction` with `confirm` is left out on older apps, rather than run unasked |

### Publishing

Open a pull request that adds your plugin's folder. CI tests IslandKit and builds every plugin. After merging, it builds each new version universal (arm64 and x86_64), ad-hoc signs it, attaches the zip to a GitHub release `<id>-<version>` and updates `index.json` with the archive's address, SHA-256 and size, the author and the plugin's homepage (`island-plugin publish`; the app checks the checksum before it installs). Bump `version` to publish an update; the id can't change once published.

Settings > Plugins in the app lists this index, installs and updates from it, and also takes a plugin's zip or folder from your Mac (Install from File), so a plugin can be tried before it is published.

Outside this repo, depend on IslandKit with `.package(url: "https://github.com/nyaaorick/island4mac-plugins", from: "1.0.0")`; `island-plugin new` sets that up.

## The protocol

IslandKit speaks the island's protocol (JSON lines over the plugin's stdin and stdout) so a Swift plugin doesn't have to. The protocol itself, with every message, field and version, is documented once, in the app's spec: [spec/docs/04-plugin-protocol.md](https://github.com/nyaaorick/island4mac/blob/main/spec/docs/04-plugin-protocol.md). A plugin in any other language speaks it directly.

## A plugin in another language

```python
import json, sys
print(json.dumps({"type": "compact", "symbol": "sun.max", "text": "Hello"}), flush=True)
for line in sys.stdin:          # ends when the app closes stdin
    event = json.loads(line)
```

Install it from its folder or zip with Settings > Plugins > Install from File. To publish one here, its folder needs a `Package.swift` for CI to build, or open an issue to talk about other languages.
