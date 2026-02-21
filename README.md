# Clipotron

A macOS menu bar clipboard manager with a Control Center-style popup.

## What It Does

**Option+V** — opens a popup below the menu bar with your 4 most recent clipboard items (text and images).

```
Copy "hello"     → [1] hello
Copy "world"     → [1] world  [2] hello
Copy screenshot  → [1] Image 800x600  [2] world  [3] hello
```

Click an item or press **1–4** to paste it into the active app. Press **Escape** to close.

## Features

- Text and image clipboard history (up to 4 items)
- **Cmd+1..4** hotkeys to paste directly when panel is open
- Toggle on/off — disable clipboard tracking without quitting
- Dark theme matching native macOS Control Center panels
- Menu bar icon with active state highlight
- RAM-only — history is cleared on restart, nothing is saved to disk

## Installation

```bash
git clone https://github.com/utkabotron/Clipotron.git
cd Clipotron
swiftc main.swift -o clipotron -framework Carbon -framework AppKit
mkdir -p Clipotron.app/Contents/MacOS
cp clipotron Clipotron.app/Contents/MacOS/clipotron
codesign -s - -f Clipotron.app
open Clipotron.app
```

**Requirements:**
- macOS 12+ (Monterey and newer), Intel or Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`)

After first launch, add `Clipotron.app` to **System Settings → Privacy & Security → Accessibility**.

## Autostart

Create `~/Library/LaunchAgents/com.pavelbrick.clipotron.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pavelbrick.clipotron</string>
    <key>ProgramArguments</key>
    <array>
        <string>/path/to/Clipotron.app/Contents/MacOS/clipotron</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Then:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pavelbrick.clipotron.plist
```

## How It Works

1. Polls `NSPasteboard` every 300ms for new text or image content
2. On **Option+V**, shows a borderless `NSPanel` (non-activating — doesn't steal focus)
3. On item selection: closes panel → copies item to clipboard → simulates Cmd+V
4. Global event tap intercepts Option+V and Cmd+1..4 hotkeys

Single Swift file (~680 LOC), no external dependencies.

## License

MIT
