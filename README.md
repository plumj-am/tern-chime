# Chime for Tern

A sound when something needs you: a pane's unseen alert (terminal bell, agent
waiting or finished out of sight, exited program), an omp agent yielding its
turn, or a long shell command finishing. Chimes never overlap, and one
window's chime suppresses the same moment's chime in every other window.

## Install

The plugin has two halves, and the host half is not on `main` yet. Install
the branch that carries it:

```sh
tern plugin install https://github.com/plumj-am/tern-chime#patch/PlumJam-tmtylltqsswz
```

Installing `main` gives the window half alone. It has no host half to ask,
so it stays silent.

For development, `tern plugin link /path/to/tern-chime`.

## Two halves

The plugin runs in two parts. The window half (`src/window.luau`) decides
when a sound is due: it watches panes for unseen alerts, watches for long
shell commands, and takes the agent_finished event for an agent that
yielded its turn. The host half (`src/host.luau`) does the heavy work: it
reads and parses `sounds.toml`, finds a sound player, and starts it. The
two halves talk through files in the plugin's data folder.

The split is there because the window half runs on the window's UI thread
with a tight time budget, and reading a config file, probing for a player
and starting one do not belong there. The host half runs in the session
daemon on its own worker thread, where there is much more room.

Two triggers follow from that split. An agent that needs you raises the
pane's own alert flag, so it chimes as an alert. An agent that yielded its
turn chimes through the agent_finished event, so a turn that ended in a
failure does not chime: only a turn that finished does.

Nothing changes for you. The sounds, the commands and the config file work
as before: the config still lives in `sounds.toml`, it is still re-read every
few seconds, and the mute toggle still shows in the status line.

One consequence is worth stating plainly: the sound now plays on the machine
that runs the session daemon. For a normal local session that is the same
machine as the window. The window half decides, the host half plays.

## Platforms

| OS | Player | Notes | Volume |
|---|---|---|---|
| Windows | `Media.SoundPlayer` via a hidden `wscript` launcher | WAV only; no console flash | Ignored: SoundPlayer has no volume control |
| macOS | `afplay` (ships with the OS) | Plays whatever afplay reads | `afplay -v` |
| Linux | `pw-play` → `paplay` → `aplay` → `ffplay` → `play`, first found wins | PipeWire-native first; on a bare server install one of `pipewire-bin`, `pulseaudio-utils`, `alsa-utils`, `ffmpeg` or `sox` | `pw-play`, `paplay`, `ffplay` and `play` take it; `aplay` ignores it |
| iOS | — | Silent; sound playback isn't available to plugins | Silent anyway |

On Linux without any player, Chime logs one warning and stays silent rather
than erroring on every trigger.

## Sounds

Custom sounds are the point. `sounds.toml` in the plugin folder names the
audio file per trigger, and `<plugin data>/sounds.toml` overrides it so a
reinstall keeps your sounds. In your override, paths can be absolute,
`~/`-relative, or relative to the plugin data folder (handy for a `sounds/`
folder next to the config); an empty path silences that trigger. `volume` is a
whole percent from 1 to 100 that scales every chime; 100 is normal volume, and
a player without volume control (Windows, `aplay`) ignores it rather than
erroring. The config re-reads every few seconds, and **Chime: Reload sounds**
refreshes it at once.

The bundled chimes in `sounds/` are synthesized in-repo and free to keep, but
they are just defaults. To use the Mac "Funk" alert sound, for example:

1. Save a `Funk.aiff` (from `/System/Library/Sounds` on a Mac, or any
   recording of it) next to your override config:
   `<plugin data>/sounds/Funk.aiff`. (`tern plugin dir` shows the plugins
   folder; plugin data lives under Tern's local data folder, e.g.
   `%LOCALAPPDATA%\Tern\plugin-data\chime` on Windows.)
2. On Windows, convert it to WAV first — `Media.SoundPlayer` plays WAV only:
   `ffmpeg -i Funk.aiff -ar 44100 -ac 1 Funk.wav`. macOS and Linux play
   whatever their player reads (see Platforms above).
3. Point the triggers at it:

```toml
# <plugin data>/sounds.toml
alert = "sounds/Funk.wav"   # terminal bell, agent waiting, pane alert
yield = "sounds/Funk.wav"    # omp agent yielded its turn
done = ""                     # long commands: silent
only_unfocused = true         # chime only for panes you aren't looking at
min_seconds = 30              # commands running this long chime done
volume = 100                  # playback volume in percent, 1-100
```

More recipes:

```toml
# One shared chime for everything, including the focused pane:
alert = "~/sounds/ping.wav"
yield = "~/sounds/ping.wav"
done = "~/sounds/ping.wav"
only_unfocused = false
min_seconds = 0
volume = 100
```

```toml
# Silent agent yields; only waiting agents and long builds make noise:
alert = "C:/sounds/alarm.wav"
yield = ""
done = "C:/sounds/ta-da.wav"
min_seconds = 120
volume = 40
```

## Palette

**Chime: Mute / unmute** (the status line shows `chime muted` while muted),
**Chime: Play test sound**, **Chime: Reload sounds**, **Chime: Diagnose panes
and agents** (writes what Chime sees to `<plugin data>/diagnose.txt`).
