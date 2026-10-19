# MacTouch

Free touchscreen driver for macOS. Plug in a USB touch monitor (any Windows-style HID
multi-touch digitizer, e.g. Dell P2424HT), run MacTouch, touch the screen.

- Works in extended and mirrored mode, with several displays and several touchscreens.
- Taps, drags, long press, two-finger scroll with momentum, pinch, rotate, 3/4/5-finger taps and
  swipes, edge swipes. Every gesture is mappable to a built-in action, a keyboard shortcut, a mouse
  button, typed text, a shell command, an app or a URL (menu bar icon → Gestures).
- grandMA3 onPC: true multi-point touch. Touches on onPC windows are sent into onPC's own
  multi-touch engine through its Lua `Touch()` API, so several executors or faders can be held at
  once (menu bar icon → grandMA3 tab, install the plugin once).
- No kernel extension, no Xcode needed to build, nothing leaves the Mac.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/lukasbaxter/mactouch/main/install.sh | zsh
```

Then enable MacTouch under System Settings → Privacy & Security → *Input Monitoring* and
*Accessibility* (the app opens both panes on first launch). It starts at login.

## Build from source

```sh
./build.sh            # needs only the Command Line Tools (swiftc)
open build/MacTouch.app
Tests/run.sh          # parser / mapping / gesture tests
```

## How it works

macOS receives reports from USB touchscreens but does nothing with them. MacTouch opens the
digitizer with IOHIDManager, parses the HID report descriptor itself (parallel and hybrid
Windows-precision-touch formats, up to 10 contacts), maps the panel coordinates onto the display
the screen belongs to (rotation, mirroring and calibration included), runs a gesture recognizer
and posts the resulting pointer, scroll and keyboard events through Core Graphics.

macOS has a single pointer and no public multi-point injection, so apps other than grandMA3 see
one finger as the mouse and multi-finger input as gestures.

Config: `~/Library/Application Support/MacTouch/config.json`. Log: `~/Library/Logs/MacTouch.log`.
