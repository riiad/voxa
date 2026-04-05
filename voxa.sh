#!/bin/bash
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

RECORDING_PID_FILE="/tmp/voxa.pid"
RECORDING_FILE="/tmp/voxa_recording.wav"
MODEL_PATH="$HOME/.voxa/models/ggml-small.bin"
WHISPER_LANG="fr"

ACTION="${1:-toggle}"

start_recording() {
    if [ -f "$RECORDING_PID_FILE" ]; then
        return
    fi
    afplay /System/Library/Sounds/Tink.aiff &
    ffmpeg -y -f avfoundation -i ":0" -ar 16000 -ac 1 -sample_fmt s16 "$RECORDING_FILE" 2>/dev/null &
    echo $! > "$RECORDING_PID_FILE"
}

stop_recording() {
    if [ ! -f "$RECORDING_PID_FILE" ]; then
        return
    fi
    PID=$(cat "$RECORDING_PID_FILE")
    rm -f "$RECORDING_PID_FILE"

    kill "$PID" 2>/dev/null
    wait "$PID" 2>/dev/null

    afplay /System/Library/Sounds/Pop.aiff &

    whisper-cli -m "$MODEL_PATH" -l "$WHISPER_LANG" -f "$RECORDING_FILE" -np -otxt -of /tmp/voxa_output 2>/dev/null

    if [ -f /tmp/voxa_output.txt ]; then
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' /tmp/voxa_output.txt | tr -d '\n' | pbcopy
        osascript -e 'tell application "System Events" to keystroke "v" using command down'
    fi

    rm -f "$RECORDING_FILE" /tmp/voxa_output.txt
}

case "$ACTION" in
    start)
        start_recording
        ;;
    stop)
        stop_recording
        ;;
    toggle)
        if [ -f "$RECORDING_PID_FILE" ]; then
            stop_recording
        else
            start_recording
        fi
        ;;
esac
