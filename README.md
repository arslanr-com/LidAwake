# LidAwake

Keep your MacBook awake with the lid closed. No external display, keyboard or mouse needed.

LidAwake is a small, free, open-source menu bar app for macOS. One click and your Mac keeps running downloads, builds, renders, SSH sessions, servers and AI agents with the lid shut, then sleeps normally again when you turn it off.

If you came here looking for **Amphetamine**, **Caffeine**, **KeepingYouAwake**, **Lungo**, **Theine**, **InsomniaX** or **NoSleep**, LidAwake does the same job in about 300 lines of Swift that you can read before you run them.

## Features

- **Closed-lid mode** that actually works: the Mac stays awake when you close the lid, on battery or on power, with no external display attached.
- **Display turns off when the lid closes**, so the screen isn't lit inside your bag.
- **One password prompt, ever.** After the first switch, turning it on and off needs no password (see [How it works](#how-it-works)).
- **Timers**: stay awake for 30 minutes or 1, 2, 4 or 8 hours, then return to normal sleep automatically.
- **Battery guard**: switches itself off below 15% battery so a closed Mac doesn't drain to zero.
- **Launch at login**.
- Menu bar only: no Dock icon, no windows, no telemetry, no network access, no dependencies.
- Universal binary for Apple Silicon and Intel, macOS 13 Ventura or later.

## Install

Build from source. You need the Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/arslanr-com/LidAwake.git
cd LidAwake
./build.sh
mv LidAwake.app /Applications/
open /Applications/LidAwake.app
```

A moon icon appears in the menu bar. The app is ad-hoc signed, so if macOS blocks the first launch, right-click the app and choose **Open**.

## Usage

Click the menu bar icon:

| Item | What it does |
| --- | --- |
| **Turn On / Turn Off** (⌘T) | Keep the Mac awake indefinitely, or return to normal sleep |
| **Turn On For…** | Stay awake for a set time, then sleep normally |
| **Turn Off Display When Lid Closes** | Blank the built-in screen while the lid is shut (on by default) |
| **Turn Off Below 15% Battery** | Battery guard (on by default) |
| **Launch at Login** | Start LidAwake when you log in |
| **Remove Passwordless Access** | Delete the sudoers rule described below |
| **Quit** | Quit the app; if it was on, sleep is switched back on first |

The icon is a moon when sleep is normal and a filled coffee cup when the Mac is kept awake.

## How it works

Apps that keep a Mac awake with power assertions (what `caffeinate` uses) stop the idle timer, but macOS still sleeps when the lid closes unless the Mac is in clamshell mode with an external display and power. Closed-lid wake needs the system-wide `disablesleep` flag:

```bash
sudo pmset -a disablesleep 1   # never sleep, even with the lid closed
sudo pmset -a disablesleep 0   # back to normal
```

Changing that flag needs root. The first time you switch LidAwake on, macOS asks for your password once, and LidAwake installs this rule as `/etc/sudoers.d/lidawake` after checking it with `visudo`:

```
<your-user> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

It lets your user run those two exact commands without a password and nothing else. **Remove Passwordless Access** in the menu deletes it, or you can delete it yourself:

```bash
sudo rm /etc/sudoers.d/lidawake
```

With `disablesleep` on, macOS also leaves the built-in display on when the lid closes. LidAwake watches the lid (`AppleClamshellState`) and runs `pmset displaysleepnow` to blank it. It skips this when an external display is active, because that command would blank the external display too.

## Caveats

- `disablesleep` is a system-wide setting and **persists across reboots** until it's turned off. If you delete LidAwake while it's on, run `sudo pmset -a disablesleep 0`.
- A closed MacBook that is working can get warm. Don't run heavy workloads with the lid shut inside a bag or on a soft surface.
- Force-quitting LidAwake (for example `kill`) leaves the mode as it was. Use **Quit** from the menu to switch sleep back on.

## LidAwake vs. other keep-awake apps

| | LidAwake | caffeinate / power-assertion apps |
| --- | --- | --- |
| Prevents idle sleep | ✅ | ✅ |
| Stays awake with the lid closed, no external display | ✅ | ❌ |
| Turns the display off when the lid closes | ✅ | n/a |
| Open source, no App Store account needed | ✅ | varies |

Amphetamine has its own closed-display mode and many more triggers (apps, Wi-Fi, schedules). Use it if you need those. LidAwake is for people who want one toggle and source code they can audit.

## Uninstall

1. Turn LidAwake off and quit it from the menu.
2. Click **Remove Passwordless Access** first, or run `sudo rm /etc/sudoers.d/lidawake`.
3. Delete `/Applications/LidAwake.app`.

## License

[MIT](LICENSE)
