# Macro Studio

Mac automation with a radial wheel that blooms under your cursor.

One engine (macros: ordered steps, per-app contexts), two surfaces: global
hotkeys and the radial. Hold Right Command, the wheel appears, flick toward a
slice, release, it fires. Muscle memory in a day.

Native Swift. No Electron, no runtime deps. Macros are plain JSON files you
can read, edit, and commit to git.

## Step types

app launch/focus, open URL or path, type text (clipboard restored), keystroke,
shell script (output toast), window halves/thirds/maximize/next display,
system (volume, mic mute, brightness, dark mode), delay.

## Install (from source, for now)

```
make app
make install
```

Open `MacroStudioAgent` and `Macro Studio` from /Applications. macOS will ask
for Accessibility and Input Monitoring for the agent. Grant both, that is the
whole setup. Note: rebuilding re-signs the binary, so macOS drops the grants;
re-add the agent in System Settings after a rebuild.

- `Macro Studio.app` is the editor. Build macros, lay out the wheel.
- `MacroStudioAgent.app` is the engine. Menu bar icon, start at login toggle.
- `dist/macroctl` runs macros from the terminal (`macroctl list`, `macroctl run <name>`).

## Files

Everything lives in `~/Library/Application Support/Macro Studio/`:
`macros/<uuid>.json`, `rings.json`, `settings.json`. Edit them by hand if you
want, the agent hot-reloads. Example macro:

```json
{
  "id": "6F9B2C6E-1111-2222-3333-444455556666",
  "name": "Build and run",
  "context": "com.apple.dt.Xcode",
  "hotkey": { "key": "r", "mods": ["cmd", "shift"] },
  "steps": [ { "type": "keys", "key": "r", "mods": ["cmd"] } ]
}
```

Imported `.macrostudio` files that contain shell steps arrive disabled. Read
the script, then enable. Treat imports like border control.

## Not in v1

Recorder, variables, loops, image matching, Windows, sync, AI. On purpose.
