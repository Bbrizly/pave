# Pave

Pave is a native macOS automation app. It lets you build macros as
ordered steps, bind them to global or app-specific hotkeys, and launch them
from a radial wheel that appears under the cursor.

The project is a Swift Package with one shared engine and three executables:

- `PaveKit`: macro models, JSON storage, hotkey lookup, and execution.
- `Pave.app`: the SwiftUI editor for macros, settings, and radial rings.
- `PaveAgent.app`: the menu bar agent that listens for keys and runs macros.
- `pavectl`: a terminal command for listing and running saved macros.

## Requirements

- macOS 13 or newer.
- Swift 5.9 or newer.
- Accessibility permission for `PaveAgent.app`.
- Input Monitoring permission for `PaveAgent.app`.

Grant the same permissions to `Pave.app` if you use editor test runs.

## Build and Install

```sh
swift build
swift test
make app
make install
```

`make app` builds release binaries and bundles them into `dist/`.
`make install` copies both apps to `/Applications` and installs `dist/pavectl`.

The Makefile signs the app bundles with the first available local code signing
identity. If none exists, it uses an ad-hoc signature. With ad-hoc signing,
macOS may drop Accessibility permissions after each rebuild.

## First Run

1. Run `make install`.
2. Open `/Applications/PaveAgent.app`.
3. Open `/Applications/Pave.app`.
4. Grant Accessibility and Input Monitoring when macOS asks.
5. Hold Right Command to show the radial wheel.

On a new store, the app creates five starter macros and a global radial ring.

## How It Works

Pave stores all user data as JSON in:

```text
~/Library/Application Support/Pave/
```

Files inside that directory:

- `macros/<uuid>.json`: one macro per file.
- `rings.json`: radial wheel layouts by context.
- `settings.json`: radial hold key, fire mode, and tick sound.
- `.initialized`: marker that prevents starter macros from being installed twice.

The editor writes JSON to disk, then posts a distributed reload notification.
The agent also watches the data directory, so edits made by hand are picked up
without polling.

When the agent starts, it:

1. Loads macros, rings, and settings from `Store`.
2. Builds a `Registry` from enabled macros with valid hotkeys.
3. Starts a global `CGEventTap`.
4. Tracks the frontmost app bundle id.
5. Shows the radial wheel when the hold key is held for 150 ms.
6. Runs the selected macro through a single serial `Executor`.

Only one macro runs at a time. A second fire while one is running is rejected as
busy. Each macro has a 30 second execution cap, checked between steps.

## Macro Format

Example macro:

```json
{
  "v": 1,
  "id": "6F9B2C6E-1111-2222-3333-444455556666",
  "name": "Build and run",
  "enabled": true,
  "context": "com.apple.dt.Xcode",
  "hotkey": { "key": "r", "mods": ["cmd", "shift"] },
  "steps": [
    { "type": "keys", "key": "r", "mods": ["cmd"] }
  ]
}
```

`context` is optional. If set, that hotkey only wins while that app is frontmost.
An app-specific hotkey beats a global hotkey with the same key combination.

Supported step types:

- `app`: launch or focus an app by bundle id.
- `open`: open a URL, file, or folder.
- `text`: paste text, then restore the clipboard by default.
- `keys`: post a keystroke with modifiers.
- `shell`: run `/bin/zsh -c`, toast up to four output lines, fail on nonzero exit.
- `window`: move the focused window to halves, thirds, maximize, or next display.
- `system`: volume, mute, brightness, mic mute, dark mode, or screen recording UI.
- `delay`: sleep for a number of milliseconds.

Unknown step types are preserved as `unknown`, not dropped. The editor opens
those macros read-only, the registry skips them, and the executor refuses to run
them.

## Radial Wheel

Rings are stored by context in `rings.json`.

- `global` is the fallback ring.
- App bundle ids, such as `com.apple.dt.Xcode`, define app-specific rings.
- Each ring shows up to 8 slices.
- A slice can point to a macro.
- Submenus are supported by the agent but must be edited in JSON for now.

Default hold key: Right Command.

Available hold keys in settings: Right Command, Right Option, F18, and F19.

Fire modes:

- Release to fire: move toward a slice, release the hold key, run it.
- Click to fire: keep the wheel open until click, Return, or Escape.

## Commands

```sh
pavectl list
pavectl run <uuid-or-name>
```

`pavectl list` prints each saved macro with its id, hotkey, context, and flags.
`pavectl run` executes by exact UUID or exact case-insensitive name.

## Import and Export

The editor imports and exports `.pave` files.

Imported macros get fresh ids. Imported macros containing shell steps are
disabled so the script can be reviewed before use.

## Development

Useful commands:

```sh
swift build
swift test
make app
make install
make clean
```

Tests cover:

- Step encoding and decoding.
- Unknown step preservation.
- Store save/load/delete.
- Import safety for shell macros.
- Hotkey registry lookup and conflict detection.
- Executor ordering, failures, busy rejection, and timeout behavior.

## Not In v1

Recorder, variables, loops, image matching, sync, Windows support, and AI.
