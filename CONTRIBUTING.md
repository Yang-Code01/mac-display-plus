# Contributing

## Prerequisites

- Apple Silicon Mac running macOS 26 or newer
- Xcode Command Line Tools (`xcode-select --install`) — a full Xcode install is
  **not** needed, and there is no Xcode project or SwiftPM manifest

## Build

```bash
./build.sh
open "build/display++.app"
```

`build.sh` compiles every file under `Sources/`, assembles the `.app` bundle,
generates the icon on first run, and ad-hoc signs the result. It takes about
half a minute from clean.

## Testing a change

There is no unit test target. Every behaviour is verified through the CLI, so
each one has a `--flag` that prints measured values rather than assertions
about internal state. Run the flag that covers your change and paste its output
into the pull request:

```bash
APP="build/display++.app/Contents/MacOS/display++"
"$APP" --probe          # what the machine actually offers
"$APP" --selftest       # panel layout and visibility
"$APP" --geometry-test  # panel fits 7 synthetic screen sizes
```

Anything that mutates display state (`--control-test`, `--hidpi-test`,
`--overflow-test`, `--arrangement-test`) restores what it changed before it
exits, including on failure. Keep it that way: a test that can leave someone's
displays misconfigured is a bug, not a test.

## Code layout

```
Sources/DisplayPlusPlus/
├── main.swift        entry point + CLI dispatch
├── AppDelegate.swift status item, hotkeys, settings window
├── Model/            value types (deliberately hold no CGDisplayMode)
├── Services/         everything that mutates display state
├── UI/               AppKit + SwiftUI views (read state, call intents)
└── Support/          CLI probes, localisation, @State replacement
```

`DisplayManager` is the only place that changes display state. Views read model
state and call intent methods; they never call CoreGraphics directly. Keep new
display mutations behind that boundary.

## Conventions

- Swift 5 language mode, no external dependencies.
- Comments explain *why*, not *what*. If you discovered something surprising
  about a macOS API while writing the code, leave the note — those are the most
  valuable comments in this repository.
- Localised strings use English source text as the key; add the Chinese
  translation in `Resources/zh-Hans.lproj/Localizable.strings`.
- CLI diagnostics stay in English. They are meant to be read alongside
  `CGError` names and `CGDisplayMode` fields.

## Private APIs

Parts of this project call undocumented SkyLight / IOKit / DisplayServices
entry points (`CGSGetDisplayModeDescriptionOfLength`, `IOAVServiceWriteI2C`,
`DisplayServicesSetBrightness`, `CGVirtualDisplay`, …). This is deliberate — the
public CoreGraphics surface cannot express HiDPI backing scale on external
displays, DDC brightness, or display disconnect.

Consequences to keep in mind:

- These symbols can disappear or change signature between macOS releases. Every
  call site should fail gracefully rather than crash.
- `IOAVServiceCreateWithService` returns a 24-byte heap object, **not** a mach
  port. Declaring it as `io_object_t` truncates the pointer and segfaults.
- Never do I2C against the built-in display's `DCPAVServiceProxy`; it crashes.
  Only touch `Location == "External"`.

## Reporting a bug

Include:

1. macOS version and Mac model (`sw_vers`, `sysctl -n machdep.cpu.brand_string`)
2. The output of `--probe`
3. What you expected versus what happened

For anything display-mode related, `--probe` output is not optional: half the
bugs in this area are a specific panel refusing a mode that CoreGraphics
advertises as valid.
