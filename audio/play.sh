#!/bin/sh
# Play a wav file without blocking Klipper.
#
# Called from [gcode_shell_command _PLAY_AUDIO] in config/macro/audio.cfg.
# RUN_SHELL_COMMAND waits for its child to exit and kills it after the
# configured timeout, so aplay must not be run in the foreground: long clips
# were truncated at 2s and the printer's command queue stalled meanwhile.
# gcode_shell_command execs the command directly rather than through a
# shell, so the '&' cannot live in the config - hence this wrapper.
#
# Usage: play.sh /absolute/path/to/file.wav

if [ -z "$1" ]; then
    echo "play.sh: no file given" >&2
    exit 0
fi

if [ ! -r "$1" ]; then
    echo "play.sh: cannot read '$1'" >&2
    exit 0
fi

aplay -q "$1" >/dev/null 2>&1 &

# Always succeed: a missing sound must never abort a print.
exit 0
