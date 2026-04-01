# AutoPilot

> Control iOS Simulator directly from the command line. No XCUITest. No server. No dependencies. One binary.

AutoPilot talks to the iOS Simulator through macOS Accessibility APIs (`AXUIElement`), `CGEvent` for input simulation, and `xcrun simctl` for device lifecycle. It is a single Swift binary with zero external dependencies.

```bash
auto launch com.example.app
auto tap "Login"
auto type "Username" "user@test.com"
auto screenshot result.png
```

## Why AutoPilot Exists

Testing iOS apps in automation requires tools like XCUITest (needs xcodebuild, a test target, compilation per run) or Appium/WebDriverAgent (needs a Node.js server, a running XCUITest runner, HTTP overhead). Both require heavyweight setup, slow compilation, and complex infrastructure.

AutoPilot replaces all of that with a single CLI call. It reads the Simulator's accessibility tree directly from macOS, sends input events through the kernel, and manages devices via simctl. No server. No compilation. No runner process. Open the Simulator, run a command, done.

Built for CI/CD headless environments where there is no screen, no webcam, no human interaction.

## Quick Start

### Prerequisites

- macOS 13+ (Ventura or later)
- Xcode with iOS Simulator
- Accessibility permissions granted (System Settings > Privacy & Security > Accessibility)

### Build

```bash
cd cli
swift build -c release
cp .build/release/auto /usr/local/bin/auto
```

### First Run

```bash
# Open Simulator with any app
open -a Simulator

# Check connection
auto ping

# Print the full accessibility tree
auto tree

# Tap a button
auto tap "General"

# Run a script
auto run test-flow.auto
```

---

## Architecture

AutoPilot operates at four distinct layers of the macOS system. Everything below is documented so the community can understand, contribute, and build on top of it.

### Layer 1: AXUIElement -- Reading the UI

macOS exposes every running application's UI through the Accessibility API. The iOS Simulator is a macOS app (`com.apple.iphonesimulator`) that renders iOS views as native macOS accessibility elements. This is the key insight that makes the entire approach work.

**How it connects:**

```
NSWorkspace.shared.runningApplications
  -> find app with bundleIdentifier == "com.apple.iphonesimulator"
  -> get processIdentifier (pid_t)
  -> AXUIElementCreateApplication(pid) 
  -> AXUIElementCopyAttributeValue(app, kAXWindowsAttribute)
  -> first window -> kAXChildrenAttribute -> recursive tree
```

**What each element exposes:**

| AX Attribute | Maps to | Example |
|---|---|---|
| `kAXRoleAttribute` | Element type | `AXButton`, `AXStaticText`, `AXTextField` |
| `kAXTitleAttribute` | Display text | `"Login"`, `"Settings"` |
| `kAXDescriptionAttribute` | Accessibility label | `"Login button"` |
| `AXIdentifier` | accessibilityIdentifier | `"login_btn"` |
| `kAXValueAttribute` | Current value / placeholder | `"Enter email"` (SwiftUI placeholder) |
| `kAXPositionAttribute` | Screen position | `CGPoint(x: 100, y: 200)` |
| `kAXSizeAttribute` | Element size | `CGSize(width: 300, height: 44)` |
| `kAXEnabledAttribute` | Interactive state | `true` / `false` |

**Activation and retry:**

The Simulator's AX tree is not immediately available after activation. `findSimulatorContent()` retries up to 15 times with 200ms intervals (3 seconds total). Each retry checks both that the window exists AND that it has children (fully loaded).

```swift
for _ in 0..<15 {
    if let window = getFirstWindow(of: app) {
        if let children = getChildren(of: window), !children.isEmpty {
            return window  // ready
        }
    }
    usleep(200_000)  // 200ms
}
```

**Tree depth:** Capped at 20 levels to prevent infinite recursion in circular accessibility hierarchies.

### Layer 2: CGEvent -- Simulating Input

All user input (keyboard, mouse, gestures) is simulated through macOS `CGEvent` APIs. No accessibility actions or UI scripting -- direct kernel-level events.

**Tapping elements:**

AutoPilot first tries the native accessibility action:

```swift
AXUIElementPerformAction(element, kAXPressAction as CFString)
```

If that fails (some elements don't support `kAXPressAction`), it falls back to a CGEvent mouse click at the element's center coordinates:

```swift
let mouseDown = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, 
                        mouseCursorPosition: center, mouseButton: .left)
let mouseUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, 
                      mouseCursorPosition: center, mouseButton: .left)
mouseDown?.postToPid(pid)
mouseUp?.postToPid(pid)
```

**Typing text:**

Each character is mapped to a macOS virtual key code and sent as key down + key up events:

```swift
let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
if needsShift {
    keyDown?.flags = .maskShift
}
keyDown?.postToPid(pid)
keyUp?.postToPid(pid)
usleep(30_000)  // 30ms between keys for reliability
```

Key codes are mapped manually (US QWERTY layout). Shift is applied for uppercase letters and special characters (`~!@#$%^&*()_+{}|:"<>?`).

**Swipe/Scroll gestures:**

The Simulator translates macOS mouse drags into iOS swipe gestures. AutoPilot simulates this with 20 incremental drag steps:

```swift
// Mouse down at start
mouseDown?.post(tap: .cghidEventTap)

// 20 incremental drag steps (15ms apart)
for i in 1...20 {
    let t = CGFloat(i) / 20.0
    let point = CGPoint(
        x: start.x + (end.x - start.x) * t,
        y: start.y + (end.y - start.y) * t
    )
    let drag = CGEvent(mouseType: .leftMouseDragged, mouseCursorPosition: point)
    drag?.post(tap: .cghidEventTap)
    usleep(15_000)
}

// Mouse up at end
mouseUp?.post(tap: .cghidEventTap)
```

Smooth movement is required -- a single jump from start to end is not recognized as a swipe by the Simulator.

**`postToPid` vs `.cghidEventTap`:**

- `postToPid(pid)` -- sends the event to a specific process. Used for typing and tapping within the app.
- `.post(tap: .cghidEventTap)` -- posts globally to the HID event tap. Used for `tapAt`, `swipe`, `scroll`, and `longPress` because it reaches system UIs (photo picker, permission dialogs, share sheets) that live outside the app's process.

**Clear text field:**

```swift
// 1. Tap the field
AXUIElementPerformAction(element, kAXPressAction)

// 2. Cmd+A (select all) -- key code 0 = 'a', maskCommand = Cmd
let aDown = CGEvent(virtualKey: 0, keyDown: true)
aDown?.flags = .maskCommand
aDown?.postToPid(pid)

// 3. Delete -- key code 51
let delDown = CGEvent(virtualKey: 51, keyDown: true)
delDown?.postToPid(pid)
```

**Long press:**

Mouse down, hold for N seconds, mouse up. Uses global posting to work with system UIs:

```swift
mouseDown?.post(tap: .cghidEventTap)
usleep(UInt32(duration * 1_000_000))  // hold
mouseUp?.post(tap: .cghidEventTap)
```

### Layer 3: xcrun simctl -- Device & App Lifecycle

Commands that shell out to Apple's `simctl` tool:

| Operation | simctl command | Notes |
|---|---|---|
| List devices | `simctl list devices -j` | Parses JSON, groups by booted/shutdown |
| Boot | `simctl boot <udid>` | Resolves device name to UDID first |
| Shutdown | `simctl shutdown <udid>` | Same name resolution |
| Launch app | `simctl launch <deviceId> <bundleId>` | |
| Terminate app | `simctl terminate <deviceId> <bundleId>` | |
| Install app | `simctl install <deviceId> <path>` | Accepts .app bundles |
| Screenshot | `simctl io <deviceId> screenshot <path>` | |
| Add media | `simctl addmedia <deviceId> <path>` | Photos, videos, contacts |
| Clipboard | `simctl pbcopy/pbpaste <deviceId>` | Read/write pasteboard |
| Open URL | `simctl openurl <deviceId> <url>` | Deep links, universal links |

**Device name resolution:** When you pass a name like `"iPhone 16"`, AutoPilot lists all devices via `simctl list devices -j`, finds the matching name (case-insensitive), and extracts the UDID. If the input is already a UDID (length > 30, contains hyphens), it's used directly.

### Layer 4: AppleScript -- Simulator Menu Automation

Face ID has no simctl or API equivalent. It lives in the Simulator's menu bar under Features > Face ID. AutoPilot automates this via AppleScript:

```applescript
tell application "System Events" to tell process "Simulator"
    click menu item "Matching Face" of menu "Face ID" 
        of menu item "Face ID" of menu "Features" of menu bar 1
end tell
```

**Why AppleScript?** The Simulator menu bar is a macOS menu, not an iOS UI element. AXUIElement could access it, but AppleScript provides a more readable and maintainable approach for menu navigation.

**Enrollment check:** Reads the `AXMenuItemMarkChar` attribute of the "Enrolled" menu item. If a checkmark is present, Face ID is enrolled.

**Requirement:** The Simulator must be the frontmost application. AutoPilot calls `NSRunningApplication.activate()` and waits 500ms before executing the AppleScript.

### Element Matching Algorithm

Finding the right element is critical. AutoPilot uses a three-pass depth-first strategy:

**Pass 1 -- Exact match (all depths):**
```
identifier == query  OR  title == query  OR  label == query  OR  value == query
```
Scans the entire tree. First exact match wins.

**Pass 2 -- Contains match (all depths):**
```
label.contains(query)
```
When multiple elements match, selects the one with the **shortest label** (most specific element). This prevents matching a long description like `"Login button, double tap to activate"` when a simpler `"Login"` element exists.

**Why value matching matters:** SwiftUI elements often expose their visible text in `kAXValueAttribute` instead of `kAXTitleAttribute` or `kAXDescriptionAttribute`. Without value matching, SwiftUI placeholder text and text field content would be invisible to the tool.

All comparisons are case-insensitive.

---

## Command Reference

### Simulator Management

```bash
auto ping                              # Verify Simulator is connected
auto list                              # List all simulators (booted + available)
auto boot "iPhone 16"                  # Boot by name
auto boot <UDID>                       # Boot by UDID
auto shutdown "iPhone 16"              # Shutdown by name
```

### App Lifecycle

```bash
auto launch com.example.app            # Launch app
auto terminate com.example.app         # Kill app
auto install /path/to/MyApp.app        # Install app on booted simulator
```

### UI Interaction

```bash
auto tap "Login"                       # Tap element by id/title/label/value
auto doubleTap "Image"                 # Double tap
auto longPress "Item" 2                # Long press for 2 seconds (default: 1s)
auto type "Hello World"                # Type text (requires focused field)
auto type "Username" "user@test.com"   # Tap field, then type
auto clear "Username"                  # Select all + delete
auto swipe up                          # Swipe the whole screen
auto swipe down
auto swipe left
auto swipe right
auto scroll "tableView" down           # Scroll within a specific element
auto tapAt 200 400                     # Tap at coordinates (for system UIs)
```

### UI Inspection

```bash
auto tree                              # Print full accessibility tree
auto tree -s "Login"                   # Search elements matching text
auto exists "Welcome"                  # YES/NO (exit code 0 either way)
auto elementAt 200 400                 # Inspect element at coordinate
auto waitFor "Home" 10                 # Wait up to 10s for element to appear
```

### Hardware & Data

```bash
auto faceid enroll                     # Toggle Face ID enrollment
auto faceid match                      # Simulate successful scan
auto faceid fail                       # Simulate failed scan
auto faceid status                     # Check if enrolled
auto media photo.jpg                   # Inject photo into library
auto media video.mp4 photo2.jpg        # Multiple files
auto paste "Hello"                     # Set clipboard
auto paste                             # Get clipboard
auto openurl "myapp://deep/link"       # Open URL / deep link
auto screenshot                        # Save as screenshot.png
auto screenshot result.png             # Save with custom name
```

### Scripting

```bash
auto run test-flow.auto                # Execute automation script
```

---

## Script Format (.auto)

Each line is a command, exactly as you'd type it in the terminal. Comments start with `#`. Quoted strings are supported.

```bash
# login-flow.auto
# Tests the complete login flow

launch com.example.myapp
waitFor "Login" 5

# Enter credentials
tap "Username"
type "testuser@example.com"
tap "Password"  
type "secret123"

# Submit and verify
tap "Sign In"
waitFor "Welcome" 10
screenshot login-success.png
```

**Execution:**

```
$ auto run login-flow.auto
[1] launch com.example.myapp
Launched com.example.myapp (245ms)
[2] waitFor "Login" 5
Found 'Login' (1203ms)
[3] tap "Username"
Tapped 'Username' (89ms)
[4] type "testuser@example.com"
Typed text (680ms)
[5] tap "Password"
Tapped 'Password' (76ms)
[6] type "secret123"
Typed text (312ms)
[7] tap "Sign In"
Tapped 'Sign In' (91ms)
[8] waitFor "Welcome" 10
Found 'Welcome' (2105ms)
[9] screenshot login-success.png
Saved: login-success.png (142KB, 203ms)

9 step(s) completed (5004ms)
```

**Behavior:**
- Steps are numbered sequentially
- On failure: prints the line number, error, and exits with code 1
- Blank lines and comments are skipped
- Quoted strings (single or double) are tokenized correctly

---

## CI/CD Integration

AutoPilot is built for headless CI/CD. Here's what you need:

### Runner Setup

```bash
# 1. Grant accessibility permissions to your CI runner
#    (must be done once, requires admin)

# 2. Boot a simulator
xcrun simctl boot "iPhone 16"

# 3. Open Simulator.app (macOS needs the process even headless)
open -a Simulator

# 4. Wait for boot
sleep 5

# 5. Run your automation
auto run regression-tests.auto
echo "Exit code: $?"  # 0 = pass, 1 = fail
```

### Exit Codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Failure (element not found, timeout, simctl error) |

### Combining with shell

```bash
auto launch com.example.app
auto waitFor "Home" 15 || { echo "App failed to load"; exit 1; }
auto tap "Profile"
auto exists "Username" && echo "Profile loaded"
```

---

## Project Structure

```
AutoPilot/
├── cli/                        # Swift Package (the tool)
│   ├── Package.swift           # SPM manifest (macOS 13+, Swift 5.9)
│   └── Sources/
│       ├── main.swift          # CLI entry, command dispatch, script runner
│       ├── SimulatorBridge.swift    # AX, CGEvent, simctl, AppleScript
│       └── TreePrinter.swift   # Accessibility tree pretty-printer
├── protocol/
│   └── commands.json           # Platform-agnostic command spec
├── Demo/                       # Sample iOS app (SwiftUI) for testing
├── scripts/                    # Example .auto scripts
├── legacy/                     # Previous socket-based architecture (reference)
├── README.md
└── ROADMAP.md
```

### Why `legacy/` is included

AutoPilot started as a socket-based XCUITest runner (compile a test binary, communicate over Unix sockets). That approach was replaced by the current direct AX approach because it eliminates xcodebuild compilation, the test runner process, and all the complexity of maintaining a socket server. The legacy code is preserved as reference for anyone exploring alternative architectures.

---

## Requirements

- macOS 13 (Ventura) or later
- Xcode (any version with iOS Simulator)
- Swift 5.9+
- Accessibility permissions for Terminal / your CI runner

---

## Compared to Alternatives

| | AutoPilot | Appium/WDA | XCUITest | Detox |
|---|---|---|---|---|
| Setup time | `swift build` | Node + WDA + xcodebuild | Xcode project required | npm + metro + build |
| Server needed | No | Yes (WDA HTTP) | No | Yes (gRPC) |
| Compilation per run | No | WDA once | Every run | Every run |
| Dependencies | None | Node, Appium, WDA | Xcode | Node, React Native |
| CI/CD headless | Yes | Yes | Yes | Yes |
| System UI access | Yes (tapAt) | Limited | Limited | No |
| Binary size | ~311KB | ~200MB+ | N/A | ~150MB+ |
| Camera simulation | Planned | No | No | No |

---

## License

MIT
