# Chime for Tern

A sound when something needs you: a pane's unseen alert (terminal bell, agent
waiting or finished out of sight, exited program), an omp agent yielding its
turn, or a long shell command finishing. Chimes never overlap, and one
window's chime suppresses the same moment's chime in every other window.

## Install

```sh
tern plugin install https://github.com/H4vC/tern-chime
```

For development, `tern plugin link /path/to/tern-chime`.

## Sounds

Custom sounds are the point: `sounds.toml` in the plugin folder names the
audio file per trigger, and `<plugin data>/sounds.toml` overrides it so a
reinstall keeps your sounds. Paths there can be absolute or `~/`-relative; an
empty path silences that trigger. The config re-reads every few seconds, and
**Chime: Reload sounds** refreshes it at once.

```toml
alert = "C:/sounds/ping.wav"   # terminal bell, agent waiting, pane alert
yield = "~/sounds/done.wav"    # omp agent yielded its turn
done = ""                      # long commands: silent
only_unfocused = true          # chime only for panes you aren't looking at
min_seconds = 30               # commands running this long chime done
```

Windows plays WAV only; macOS and Linux play whatever their player reads. The
bundled chimes live in `sounds/` and are synthesized, so they are free to keep
or replace.

## Palette

**Chime: Mute / unmute** (the status line shows `chime muted` while muted),
**Chime: Play test sound**, **Chime: Reload sounds**, **Chime: Diagnose panes
and agents** (writes what Chime sees to `<plugin data>/diagnose.txt`).
