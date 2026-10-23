# AGENTS.md

Guidance for coding agents working on LidAwake.

## What this is

A macOS menu bar app (AppKit, no SwiftUI, no Xcode project) that keeps a Mac awake with the lid closed by toggling `pmset -a disablesleep 1/0`. The whole app is one file: `Sources/main.swift`.

## Layout

```
Sources/main.swift   all app code: helpers, AppDelegate, menu, entry point
build.sh             compiles a universal binary, writes Info.plist, ad-hoc signs
README.md            user-facing docs
```

`LidAwake.app/` and `.build/` are build output and are git-ignored.

## Build and run

```bash
./build.sh
open LidAwake.app
```

Requirements: Xcode Command Line Tools, Swift 5 language mode, deployment target macOS 13. The build makes `arm64` and `x86_64` slices and merges them with `lipo`. A linker warning about `libswiftCompatibilityPacks.a` missing `x86_64` is expected and harmless.

To restart after a rebuild, quit from the menu (not `kill`, which skips `applicationWillTerminate`), then `open LidAwake.app` again.

## How it works

- **State** is read from `pmset -g` (`SleepDisabled`), never cached as the source of truth. A 10 s timer syncs it, so changes made in Terminal show up in the menu.
- **Switching** runs `sudo -n /usr/bin/pmset -a disablesleep 0|1`. If that fails, the app installs a sudoers rule through `NSAppleScript` (`do shell script … with administrator privileges`) and retries.
- **Lid handling**: a 1.5 s timer reads `AppleClamshellState` from `IOPMrootDomain`. When the lid is closed, the built-in display is awake and no external display is awake, it runs `pmset displaysleepnow` (at most every 10 s).
- **Timers and battery guard** are checked in the 10 s tick.
- **Settings** live in `UserDefaults` (`batteryGuardEnabled`, `lidDisplayOffEnabled`, both default `true`).
- **Launch at Login** uses `SMAppService.mainApp`.

## Rules

- **The sudoers rule must stay minimal**: exactly `/usr/bin/pmset -a disablesleep 0` and `/usr/bin/pmset -a disablesleep 1` for the current user. Don't widen it (no wildcards, no `pmset` without arguments, no other binaries). Always validate with `visudo -cf` before installing, and install with mode `0440`, owner `root:wheel`.
- Keep the sudoers path (`/etc/sudoers.d/lidawake`) and the `sudo` arguments in `setSleepDisabled` in sync with the rule text, or switching will silently fall back to a password prompt every time.
- Anything else that needs root goes through `runAsAdmin`. Don't add a privileged helper or launch daemon without a strong reason.
- `displaysleepnow` must not run when an external display is awake.
- On Quit, sleep must be switched back on if the app turned it off.
- No third-party dependencies and no network access.
- All user-facing strings, comments and docs are in English.
- Match the existing style: small free functions for system calls, `AppDelegate` for state and menu, short comments that explain why.

## Testing

There are no automated tests. They'd need root and real hardware. Before you finish a change, check by hand:

1. `./build.sh` succeeds and `lipo -archs LidAwake.app/Contents/MacOS/LidAwake` prints `x86_64 arm64`.
2. Turn On / Turn Off: the icon changes and `pmset -g | grep SleepDisabled` follows.
3. With `/etc/sudoers.d/lidawake` absent, the first switch asks for a password once and later switches don't.
4. Close the lid while on: the Mac stays awake (for example `ping` it from another machine) and the built-in display goes dark.
5. A timed mode turns itself off when the time runs out.
6. Quit from the menu while on: `SleepDisabled` returns to `0`.

When you change behavior, update `README.md` too.
