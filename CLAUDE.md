# CLAUDE.md

Macro Studio: macOS macro engine + radial wheel surface. Swift, SwiftUI,
AppKit, SPM. Parent rules at `~/Documents/GitHub/CLAUDE.md` apply.

## Layout
- `MacroEngineKit`: model, JSON codec, hotkey registry, executor, mac step
  runners. Pure Swift except MacRunner (gated `#if os(macOS)`).
- `MacroStudioAgent`: menu bar agent. Event tap, radial panel, toasts,
  dir watcher, distributed-notification listener.
- `MacroStudio`: SwiftUI editor.
- `macroctl`: CLI (list, run).

## Build and test
- `swift build`, `swift test` (engine tests are platform-neutral).
- `make app` bundles both apps into `dist/`, `make install` copies to
  /Applications. Ad-hoc signing: permissions must be re-granted after rebuild.

## Rules
- Step types are a closed set of 8. Never add one without codec tests.
- Unknown step types must load as `.unknown` and disable the macro. Never
  crash, never drop.
- Nothing polls. Timers allowed: clipboard restore, shell timeout, tap
  watchdog, radial hold threshold.
- Macros with unknown steps are read-only in the editor.
- Vault note: `1 Projects/Macro Studio.md`. Update its Status and the line in
  `1 Projects/0 Dashboard.md` when meaningful work lands.
