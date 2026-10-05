# island4mac plugins

Plugins for [island4mac](https://github.com/nyaaorick/island4mac), the macOS notch "Dynamic Island". Install them in the app under **Settings > Plugins**, then turn a plugin's tab on under **Settings > Tabs**.

A plugin is a small program, in any language, that tells the island what to show. The island draws it in its own look: a plugin says *what* to show, never *how*. It can't set colors, fonts, images or layout, so every plugin looks like the rest of the island.

## How a plugin works

A plugin is a folder:

```text
timer/
  plugin.json
  timer          the program (or a script with its interpreter in plugin.json)
```

```json
{
  "id": "timer",
  "name": "Timer",
  "symbol": "timer",
  "command": ["./timer"],
  "protocol": 1,
  "version": "1.0.0"
}
```

| Field | Meaning |
|---|---|
| `id` | Lowercase letters, digits, `-` and `_`. Must match the folder name |
| `name` | Shown on its tab and in Settings |
| `symbol` | An [SF Symbol](https://developer.apple.com/sf-symbols/) name for its tab |
| `command` | Program and arguments. A relative program is inside the plugin folder (`./timer`). An absolute one is used as is, e.g. `["/usr/bin/python3", "main.py"]` |
| `protocol` | The protocol version it speaks. Currently `1` |
| `version` | Compared with `index.json` to offer updates |

The app runs the command, in the plugin's folder, while the plugin's tab is turned on, and stops it when the tab is turned off.

- **Plugin → island:** one JSON object per line on **stdout**. Flush after every line.
- **Island → plugin:** one JSON object per line on **stdin**.
- **Quitting:** when stdin closes, quit. If the plugin is still running 2 seconds after it's asked to stop, it is killed, along with every process it started.
- **Crashes:** a plugin that exits is restarted. After 6 exits within a minute it is marked stopped, and the user can restart it.
- **Errors:** the last lines written to **stderr** are shown as the reason when a plugin stops.

### Environment

| Variable | Value |
|---|---|
| `ISLAND_PROTOCOL` | Protocol version the app speaks |
| `ISLAND_PLUGIN_ID` | The plugin's id |
| `ISLAND_DATA_DIR` | A folder for anything the plugin keeps. It survives updates and is removed when the plugin is removed. Don't write inside the plugin folder: updates replace it |
| `ISLAND_APP_VERSION` | The app's version |

## Plugin → island

Each message replaces what the plugin showed of that kind before.

| Message | Shows |
|---|---|
| `{"type":"compact","symbol":"timer","text":"04:59","progress":0.98}` | Beside the notch while the island is collapsed. `progress` (0 to 1) draws a ring |
| `{"type":"compact","symbol":"timer","until":1767225600,"total":300}` | A countdown the island runs itself, to `until` (seconds since 1970). `total` (seconds) fills the ring. Send it once, not every second |
| `{"type":"list","rows":[{"id":"r1","title":"5 min","subtitle":"Pomodoro","symbol":"play.circle"}]}` | Rows in the plugin's tab. A row with an `id` can be tapped. Up to 50 rows |
| `{"type":"buttons","buttons":[{"id":"stop","title":"Stop","symbol":"stop.fill","confirm":"Stop the timer?"}]}` | Buttons under the rows. With `confirm`, the island asks first |
| `{"type":"input","id":"minutes","placeholder":"Minutes","text":""}` | One text field above the buttons |
| `{"type":"popup","symbol":"bell.fill","text":"Time's up","seconds":4}` | Beside the notch for 1 to 10 seconds, ahead of music |
| `{"type":"open"}` | Opens the island on the plugin's tab. At most every 10 seconds, only if the user allows it, and never over something they're using |
| `{"type":"clear","target":"compact"}` | Removes `compact`, `list`, `buttons`, `input` or `all` |

- **Text limits:** text is cut at 200 characters; a text field takes up to 1000.
- **Errors:** lines that aren't valid JSON, or have an unknown `type`, are ignored.
- **Beside the notch:** agent sessions come first, then plugin popups, then music while it plays, then plugin compact content.

## Island → plugin

| Message | When |
|---|---|
| `{"type":"action","id":"r1"}` | A row or button with that id was tapped (after confirmation, if it asks for one) |
| `{"type":"submit","id":"minutes","text":"12"}` | Return was pressed in the text field |
| `{"type":"visible","tab":true}` | Its tab opened (`false`: closed). Also sent right after the plugin starts. Update often only while visible |

## Example

[`timer/main.swift`](timer/main.swift) is a complete plugin: presets, a custom duration, pause and resume, a confirmed Stop, and a popup that opens the island when time is up. It keeps the last duration in `ISLAND_DATA_DIR`.

A minimal one in Python:

```python
import json, sys
print(json.dumps({"type": "compact", "symbol": "sun.max", "text": "Hello"}), flush=True)
for line in sys.stdin:          # ends when the app closes stdin
    event = json.loads(line)
```

## Publishing a plugin

1. Open a pull request adding your plugin's folder (source and `plugin.json`) and its entry in `index.json`.
2. After review, its release zip is attached to a GitHub release. The zip holds the plugin folder with the program built universal (arm64 and x86_64) and ad-hoc signed:

```bash
swiftc -O -target arm64-apple-macos13.0 main.swift -o timer-arm64
swiftc -O -target x86_64-apple-macos13.0 main.swift -o timer-x86_64
lipo -create timer-arm64 timer-x86_64 -output timer/timer
codesign -s - -f timer/timer
ditto -c -k --norsrc --noextattr --keepParent timer timer.zip
```

`index.json` lists every plugin:

```json
{"plugins": [{"id": "timer", "name": "Timer", "symbol": "timer", "version": "1.0.0", "protocol": 1,
              "description": "Countdown beside the notch", "archive": "https://github.com/.../timer.zip"}]}
```
