#!/bin/bash
set -uo pipefail
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

VOXA_TMP="$HOME/.voxa/tmp"
mkdir -p "$VOXA_TMP"

RECORDING_PID_FILE="$VOXA_TMP/voxa.pid"
RECORDING_FILE="$VOXA_TMP/recording.wav"
CONFIG_FILE="$HOME/.voxa/config"

# Defaults
MODEL_PATH="$HOME/.voxa/models/ggml-small.bin"
WHISPER_LANG="fr"

# Read config
if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r key value; do
        key=$(echo "$key" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        value=$(echo "$value" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        case "$key" in
            language) WHISPER_LANG="$value" ;;
            model) MODEL_PATH="$HOME/.voxa/models/$value" ;;
        esac
    done < <(grep -v '^#' "$CONFIG_FILE" | grep '=')
fi

ACTION="${1:-toggle}"

notify_error() {
    osascript -e "display notification \"$1\" with title \"Voxa Error\"" 2>/dev/null &
}

start_recording() {
    if [ -f "$RECORDING_PID_FILE" ]; then
        return
    fi

    afplay /System/Library/Sounds/Tink.aiff &
    disown

    ffmpeg -y -f avfoundation -i ":0" -ar 16000 -ac 1 -sample_fmt s16 "$RECORDING_FILE" 2>"$VOXA_TMP/ffmpeg.log" &
    local FFMPEG_PID=$!
    disown

    # Verify ffmpeg actually started
    sleep 0.3
    if ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
        notify_error "Microphone recording failed. Check permissions."
        return 1
    fi

    echo "$FFMPEG_PID" > "$RECORDING_PID_FILE"
}

stop_recording() {
    # Wait briefly for PID file in case start is still writing it
    local retries=0
    while [ ! -f "$RECORDING_PID_FILE" ] && [ "$retries" -lt 10 ]; do
        sleep 0.1
        retries=$((retries + 1))
    done

    if [ ! -f "$RECORDING_PID_FILE" ]; then
        return
    fi

    local PID
    PID=$(cat "$RECORDING_PID_FILE")
    rm -f "$RECORDING_PID_FILE"

    # Verify PID belongs to ffmpeg before killing
    local PROC_NAME
    PROC_NAME=$(ps -p "$PID" -o comm= 2>/dev/null || true)
    if [ -z "$PROC_NAME" ]; then
        rm -f "$RECORDING_FILE"
        return
    fi

    # Send SIGINT for graceful shutdown (ffmpeg finalizes the WAV header)
    kill -INT "$PID" 2>/dev/null
    for _ in $(seq 1 20); do
        kill -0 "$PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -9 "$PID" 2>/dev/null || true

    afplay /System/Library/Sounds/Pop.aiff &
    disown

    # Validate recording
    if [ ! -s "$RECORDING_FILE" ]; then
        notify_error "No audio recorded"
        rm -f "$RECORDING_FILE"
        return
    fi

    # Transcribe
    if ! whisper-cli -m "$MODEL_PATH" -l "$WHISPER_LANG" -f "$RECORDING_FILE" -np -otxt -of "$VOXA_TMP/output" 2>"$VOXA_TMP/whisper.log"; then
        notify_error "Transcription failed. Check ~/.voxa/tmp/whisper.log"
        rm -f "$RECORDING_FILE" "$VOXA_TMP/output.txt"
        return
    fi

    # Copy to clipboard + auto-paste
    if [ -f "$VOXA_TMP/output.txt" ]; then
        sed 's/^[[:space:]]*//;s/[[:space:]]*$//' "$VOXA_TMP/output.txt" | tr -d '\n' | pbcopy
        if ! osascript -e 'tell application "System Events" to keystroke "v" using command down' 2>/dev/null; then
            notify_error "Auto-paste failed. Text is in clipboard — paste manually."
        fi
    fi

    # Cleanup
    rm -f "$RECORDING_FILE" "$VOXA_TMP/output.txt"
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
