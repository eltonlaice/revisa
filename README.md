<p align="center">
  <img src="Brand/appicon.png" width="128" alt="Revisa icon">
</p>

<h1 align="center">Revisa</h1>

<p align="center">A native macOS grammar and spelling checker that works in any app, powered by <a href="https://languagetool.org">LanguageTool</a>.</p>

---

Revisa lives in your menu bar. While you type in any text field (Notes, Mail, TextEdit, Pages…), it checks the text with LanguageTool and underlines issues right on top of it. Click an underlined word to see suggestions and apply a fix in place.

- 🔴 Spelling · 🟠 Grammar · 🔵 Style
- Runs against a **local** LanguageTool server by default. Your text never leaves your Mac.
- Skips password fields.
- A single Swift file with no dependencies.

## Requirements

- macOS 13 or later
- Swift 5.10+ (Xcode or the Command Line Tools)
- [Homebrew](https://brew.sh) to install LanguageTool

## Install

```bash
# 1. Install and start LanguageTool (listens on localhost:8081)
brew install languagetool
brew services start languagetool

# 2. Build and open Revisa
git clone https://github.com/eltonlaice/revisa.git
cd revisa
./build.sh
open build/Revisa.app
```

3. When macOS asks, grant **Accessibility** permission in *System Settings › Privacy & Security › Accessibility*. Revisa needs it to read and edit the focused text field.

Revisa registers itself to **open at login** the first time it runs. Use the menu bar item to turn that off.

> **Note:** The build is ad-hoc signed, so macOS treats each rebuild as a new app. After rebuilding, turn Revisa off and on again in the Accessibility settings.

## Configuration

```bash
# Language (default: auto-detect)
defaults write com.revisa.app language en-US

# LanguageTool server (default: http://localhost:8081)
defaults write com.revisa.app server http://localhost:8081
```

You can point `server` at `https://api.languagetool.org` to skip the local install. Be aware that everything you type in any app is then sent to that server.

## How it works

1. **Read.** Every 0.3 s, Revisa asks the macOS Accessibility API for the focused UI element. If it is a text area or text field (not a password field), it reads the field's value.
2. **Check.** After 0.7 s without changes, it sends the text to LanguageTool's `/v2/check` endpoint.
3. **Draw.** For each match, it reads the on-screen bounds of that text range (`AXBoundsForRange`) and draws an underline on a transparent, non-activating overlay panel.
4. **Fix.** Clicking an underline opens a menu of replacements. Revisa selects the range in the target app and replaces it through the Accessibility API.

## Known limitations

- Works best in native Cocoa apps. Browsers and Electron apps (Chrome, Slack, VS Code) expose only part of their text to the Accessibility API, so underlines or fixes may not work there yet.
- Underlines don't follow display changes (adding or removing a monitor) until you restart the app.
- An issue that wraps across lines gets one combined rectangle.
- The ignore list is kept in memory only.

## Development

```bash
swift build                      # debug build
.build/debug/Revisa --selftest   # quick self-check
```

The brand assets live in [`Brand/`](Brand). To regenerate a PNG from an SVG:

```bash
swift scripts/render-svg.swift Brand/appicon.svg Brand/appicon.png 512
```

## License

[MIT](LICENSE). LanguageTool is a separate project with its own license and is not bundled.
