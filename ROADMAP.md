# AutoPilot Roadmap

## Architecture

AutoPilot is a layered system. The CLI and protocol are platform-agnostic. Each platform has its own backend. Features are built on top of both.

```
┌──────────────────────────────────────────────────┐
│          CLI + Protocol                          │
│    (commands, scripting, output formats)          │
├────────────────────────┬─────────────────────────┤
│    Backend: iOS        │    Backend: Android      │
│    AXUIElement         │    ADB                   │
│    CGEvent             │    UIAutomator           │
│    xcrun simctl        │    adb shell input       │
│    AppleScript         │                          │
│    CoreMediaIO (cam)   │                          │
├────────────────────────┴─────────────────────────┤
│          Features                                │
│    interaction, inspection, hardware simulation,  │
│    scripting, assertions, reporting              │
└──────────────────────────────────────────────────┘
```

---

## Completed -- v0.1

### iOS Backend: Core

| Feature | How it works |
|---|---|
| AXUIElement bridge | `AXUIElementCreateApplication(pid)` on Simulator.app, recursive tree traversal |
| Element matching | Three-pass: exact all depths > contains all depths, with `kAXValueAttribute` for SwiftUI |
| CGEvent keyboard | Virtual key codes + shift modifiers, `postToPid()`, 30ms inter-key delay |
| CGEvent mouse | Click, drag, long press via `CGEvent` mouse events |
| Global event posting | `.cghidEventTap` for system UIs (photo picker, alerts, share sheets) |
| AppleScript menus | Face ID via System Events > Simulator process > menu bar |

### Device Management

- [x] `list` -- `simctl list devices -j`, parsed, grouped by state
- [x] `boot` -- `simctl boot` with name-to-UDID resolution
- [x] `shutdown` -- `simctl shutdown` with name-to-UDID resolution
- [x] `install` -- `simctl install` for .app bundles

### UI Interaction

- [x] `tap` -- AXPressAction with CGEvent click fallback
- [x] `doubleTap` -- two AXPressAction calls, 100ms apart
- [x] `longPress` -- CGEvent mouseDown, hold N seconds, mouseUp
- [x] `type` -- CGEvent keyboard, optional target element (tap first)
- [x] `clear` -- tap + Cmd+A + Delete
- [x] `swipe` -- 20-step CGEvent mouse drag on window center
- [x] `scroll` -- 20-step CGEvent mouse drag on element center (distance = 40% element height, max 200px)
- [x] `tapAt` -- global CGEvent at absolute coordinates

### UI Inspection

- [x] `tree` -- full AX tree, pretty-printed with role/title/label/id/value/frame
- [x] `tree -s` -- recursive search on role/title/label/id/value (case-insensitive)
- [x] `exists` -- boolean check (YES/NO)
- [x] `elementAt` -- coordinate-based lookup, smallest-area element wins
- [x] `waitFor` -- polling every 500ms, configurable timeout (default 10s)

### Hardware & Data

- [x] `faceid` -- enroll/match/fail/status via AppleScript menu automation
- [x] `media` -- `simctl addmedia` for photos/videos
- [x] `paste` -- `simctl pbcopy/pbpaste` for clipboard
- [x] `openurl` -- `simctl openurl` for deep links
- [x] `screenshot` -- `simctl io screenshot`

### Scripting

- [x] `.auto` script format -- line-based, comments with `#`
- [x] Tokenizer with quoted string support (single and double quotes)
- [x] Step numbering and per-step timing
- [x] Fail-fast with line number and error reporting
- [x] Total elapsed time summary

---

## Phase 2 -- iOS Hardening

### Virtual Camera

The iOS Simulator uses the Mac's webcam for camera access. In CI/CD there is no webcam. AutoPilot will create a virtual camera that feeds static images as a live camera feed.

**Technical approach:** CoreMediaIO DAL (Device Abstraction Layer) plugin.

- A `.plugin` bundle placed in `/Library/CoreMediaIO/Plug-Ins/DAL/`
- macOS loads it automatically as a camera device
- The Simulator (and any app using AVCaptureSession) sees it as a real webcam
- The plugin reads from a known file path and serves it as continuous frames
- `auto camera feed photo.jpg` updates the file, the camera feed changes

**Commands:**
- [ ] `auto camera install` -- copy DAL plugin to system directory
- [ ] `auto camera feed <image>` -- set the image to broadcast as camera
- [ ] `auto camera stop` -- stop broadcasting

**Use cases:** QR code scanning, AR features, document capture, selfie verification -- all testable in CI/CD.

### Permissions

Grant or revoke app permissions without user interaction.

**Technical approach:** `xcrun simctl privacy`

- [ ] `auto permissions <bundleId> camera grant`
- [ ] `auto permissions <bundleId> location grant`
- [ ] `auto permissions <bundleId> photos grant`
- [ ] `auto permissions <bundleId> notifications grant`
- [ ] `auto permissions <bundleId> all reset`

Supported services: `camera`, `photos`, `location`, `contacts`, `calendar`, `microphone`, `notifications`, `homekit`, `health`, `siri`, `speech-recognition`.

### Location

Simulate GPS coordinates and routes.

**Technical approach:** `xcrun simctl location`

- [ ] `auto location <lat> <lon>` -- set fixed location
- [ ] `auto location route <file.gpx>` -- play a GPX route
- [ ] `auto location clear` -- reset to none

### Push Notifications

Send push notifications to the simulator.

**Technical approach:** `xcrun simctl push`

- [ ] `auto push <bundleId> <payload.json>` -- send from JSON file
- [ ] `auto push <bundleId> --title "Title" --body "Body"` -- inline notification

### Advanced Gestures

- [ ] Drag and drop between two elements
- [ ] Pinch in/out (zoom) -- requires two-finger simulation via CGEvent
- [ ] Rotate gesture

---

## Phase 3 -- Output & Reporting

### JSON Output

- [ ] `--json` flag on all commands
- [ ] `auto tree --json` -- full tree as JSON (for structural comparison, CI assertions)
- [ ] `auto list --json` -- device list as JSON
- [ ] Machine-readable output for pipeline integration (`jq`, scripts, dashboards)

### Assertions

Exit code-based assertions for CI/CD gating:

- [ ] `auto assert exists "Login"` -- exit 0 if found, exit 1 if not
- [ ] `auto assert text "Welcome" "Hello, User"` -- exit 0 if text matches
- [ ] `auto assert count "Cell" 5` -- exit 0 if exactly 5 elements match

### Script Reports

- [ ] `auto run --screenshots <dir> script.auto` -- screenshot after each step
- [ ] HTML report with screenshot per step, pass/fail status, timing
- [ ] JUnit XML output for CI integration (Jenkins, GitHub Actions)

---

## Phase 4 -- Scripting Language

Extend `.auto` scripts beyond simple command sequences:

### Variables

```bash
set $username "test@example.com"
set $password "secret123"
type "Email" $username
type "Password" $password
```

### Conditionals

```bash
if exists "Cookie Banner"
    tap "Accept"
endif

if not exists "Error"
    screenshot success.png
endif
```

### Loops

```bash
repeat 3
    swipe down
endrepeat
```

### Includes

```bash
include shared/login.auto
# continues with current script
```

---

## Phase 5 -- Android Backend

Same CLI, same commands, different backend. The user should not need to know whether the device is iOS or Android.

### ADB Bridge

**Technical approach:** `adb` for device management, `adb shell input` for interaction, `uiautomator dump` for UI inspection.

- [ ] `auto --platform android list` -- `adb devices`
- [ ] `auto --platform android launch <package>` -- `adb shell am start`
- [ ] `auto --platform android terminate <package>` -- `adb shell am force-stop`
- [ ] `auto --platform android install <apk>` -- `adb install`

### UI Inspection

- [ ] `auto --platform android tree` -- `uiautomator dump` parsed to same tree format
- [ ] `auto --platform android search "Login"` -- same matching algorithm on UIAutomator XML

### Input

- [ ] `auto --platform android tap "Login"` -- coordinates from uiautomator + `adb shell input tap`
- [ ] `auto --platform android type "text"` -- `adb shell input text`
- [ ] `auto --platform android swipe up` -- `adb shell input swipe`

### Platform Auto-Detection

- [ ] Auto-detect: if iOS Simulator is running, use iOS. If ADB device is connected, use Android.
- [ ] Explicit: `--platform ios` / `--platform android`
- [ ] The `protocol/commands.json` serves as the shared contract for both backends

---

## Phase 6 -- Distribution

### Build System

- [ ] Makefile with `build`, `install`, `clean`, `test` targets
- [ ] Universal binary: `swift build --arch arm64 --arch x86_64`
- [ ] `make install` copies to `/usr/local/bin/auto`

### Homebrew

- [ ] Homebrew tap repository (`homebrew-autopilot`)
- [ ] `brew tap user/autopilot && brew install autopilot`
- [ ] Bottle builds for fast installation

### GitHub Releases

- [ ] Prebuilt universal binaries per release
- [ ] SHA256 checksums
- [ ] Changelog per version
- [ ] GitHub Actions workflow: build + test + release

---

## Phase 7 -- Network & Environment

### Network Conditioning

- [ ] Simulate slow network, packet loss, disconnection
- [ ] Integration with macOS Network Link Conditioner or `simctl` APIs if available

### Keychain

- [ ] Read/write keychain items on simulator
- [ ] Reset keychain for clean test state

### Environment Variables

- [ ] Pass environment variables to app on launch
- [ ] `auto launch com.example.app --env API_URL=https://staging.api.com`

---

## Future Vision

- **Web API** -- HTTP/WebSocket wrapper around AutoPilot for remote control from any language
- **VS Code Extension** -- inspector panel, tree view, step-through scripts
- **Visual Regression** -- structural tree comparison between runs (not pixel-based, structure-based)
- **Parallel Execution** -- multiple simulators, same script, concurrent
- **Recorder** -- `CGEventTap` to intercept clicks/taps and generate `.auto` scripts
