#!/bin/sh
#
# Example for the Command field in Settings.
#
# The same command runs after a recording is filed and after taps with no
# recording, so the first thing it does is work out which it was and check it was
# given what that case promises. A recording is transcribed with MacWhisper, then
# a local LM Studio model classifies it and pulls out the part worth keeping,
# which is filed as a note, a task, or put on the clipboard.
#
# Needs MacWhisper and LM Studio. It also uses jq, which is part of macOS.
#
# Put this file's path in the field. Nothing else: everything it needs either
# comes from the app as an ALPHAFINGER_ variable, or is a constant below.

set -eu

# --- constants --------------------------------------------------------------
# Absolute paths because the app inherits launchd's PATH when opened from Finder:
# /usr/bin:/bin:/usr/sbin:/sbin. jq is on it; the other two are not.
MACWHISPER_CLI=/usr/local/bin/mw
LMSTUDIO_CLI="$HOME/.lmstudio/bin/lms"
JQ_CLI=/usr/bin/jq
# Written inside the recordings folder, wherever Settings currently points it.
NOTES_SUBFOLDER=notes
TASKS_FILE_NAME=tasks.md
CALL_LOG_NAME=calls.csv
NOTIFY_ON_ACTION=1

# --- what the app promised --------------------------------------------------
# require: these must arrive. refuse: these must not -- a tap has no recording, and
# one turning up with a file would mean the app's side of this changed.
require() {
  missing=""
  for name in "$@"; do
    eval "value=\${$name:-}"
    [ -n "$value" ] || missing="$missing $name"
  done
  [ -z "$missing" ] && return 0
  echo "unset or empty for ${ALPHAFINGER_GESTURE:-?}:$missing" >&2
  exit 2
}

refuse() {
  present=""
  for name in "$@"; do
    eval "value=\${$name:-}"
    [ -z "$value" ] || present="$present $name"
  done
  [ -z "$present" ] && return 0
  echo "set for ${ALPHAFINGER_GESTURE:-?}, which has no recording:$present" >&2
  exit 2
}

# Not in either list: ALPHAFINGER_TIMESTAMP is genuinely optional. The ring's
# clock is unset until the app writes it, and a recording made before that has no
# time to report, so this defaults it rather than demanding it.
RECORDING_ONLY="ALPHAFINGER_FILE ALPHAFINGER_METADATA_FILE ALPHAFINGER_DURATION
                ALPHAFINGER_PRESS_PATTERN"
RECORDED_AT="${ALPHAFINGER_TIMESTAMP:-unknown}"

require ALPHAFINGER_GESTURE ALPHAFINGER_TAP_COUNT ALPHAFINGER_START_INDEX \
        ALPHAFINGER_RECORDINGS_DIR

# Echoed so the debug log, which captures stdout line by line, shows what this run
# was actually given.
env | grep '^ALPHAFINGER_' | sort

# --- a row per call, written before anything slow ---------------------------
# First, deliberately: transcription and the model take seconds and can fail, and
# a run that dies half way should still have left evidence it happened.
#
# Empty duration is what marks a row as a tap rather than a recording; empty
# battery means the ring reported none. Nothing needs quoting -- every field is a
# number, an ISO timestamp, or empty. Commands run one at a time, so appending
# cannot interleave.
log_call() {
  CALL_LOG="$ALPHAFINGER_RECORDINGS_DIR/$CALL_LOG_NAME"
  mkdir -p "$ALPHAFINGER_RECORDINGS_DIR"
  [ -f "$CALL_LOG" ] \
    || echo "timestamp,tap_count,duration_seconds,battery_millivolts" > "$CALL_LOG"
  printf '%s,%s,%s,%s\n' \
    "$RECORDED_AT" \
    "$ALPHAFINGER_TAP_COUNT" \
    "${ALPHAFINGER_DURATION:-}" \
    "${ALPHAFINGER_BATTERY_MILLIVOLTS:-}" >> "$CALL_LOG"
  echo "logged the call to: $CALL_LOG"
}

log_call

# "1 tap", "2 taps".
taps_in_words() {
  if [ "$1" -eq 1 ]; then echo "1 tap"; else echo "$1 taps"; fi
}

# The ring's time as a local clock reading, or empty if there is not one.
#
# ALPHAFINGER_TIMESTAMP is ISO 8601 in UTC. BSD date cannot convert between zones
# directly, so it goes through an epoch: parse as UTC with -u, render without it.
local_clock_time() {
  [ -n "${ALPHAFINGER_TIMESTAMP:-}" ] || return 0
  epoch=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ALPHAFINGER_TIMESTAMP" +%s 2>/dev/null) \
    || return 0
  date -r "$epoch" "+%H:%M"
}

# Says what was understood, which is the part only this script knows.
#
# A recording also gets the app's own "Recording saved" banner, and that is the one
# to click: `display notification` belongs to Script Editor and carries no click
# action, so this one cannot reveal anything however much it would like to.
#
# The body is built into an AppleScript string literal, so text from the model has
# to be escaped -- an unescaped quote ends the string early and a newline ends the
# statement, both of which turn a filed note into a shell error.
notify() {
  [ "$NOTIFY_ON_ACTION" = "1" ] || return 0
  subtitle=$1
  body=$(printf '%s' "$2" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g')
  osascript -e "display notification \"$body\" with title \"AlphaFinger\" \
                subtitle \"$subtitle\"" || true
}

# --- taps with no recording -------------------------------------------------
# One action per tap count -- this is where the per-tap-count commands went when
# Settings collapsed to a single field. There is no file here, but there is still
# $ALPHAFINGER_RECORDINGS_DIR, so a tap can write somewhere sensible.
tap_action() {
  counted=$(taps_in_words "$ALPHAFINGER_TAP_COUNT")
  # Worth saying only when it is not now: a tap made while the ring was out of
  # range is delivered when it next syncs, which can be minutes later. With no
  # timestamp there is nothing to say, so nothing is said.
  when=$(local_clock_time)
  [ -n "$when" ] && counted="$counted at $when"
  notify "Tap" "$counted"
  echo "handled $counted"
}

# --- classification ---------------------------------------------------------
# One word was not enough: "copy this to the clipboard: <address>" put the whole
# sentence on the clipboard, instruction included. Asking for an object separates
# the payload from the words that asked for it.
SYSTEM_PROMPT='You classify a short voice memo.

The transcript is timed: a line like *01:23* marks when the text after it was
spoken. Use them to judge pacing and pauses if that helps you decide, but never
put a marker in "text" -- that field is prose only.

Reply with ONLY a JSON object, no prose and no markdown fence:
{"kind":"NOTE|TASK|SNIPPET|OTHER","title":"a few words","text":"the payload"}
kind NOTE: a thought or piece of information to keep.
kind TASK: something the speaker intends to do, or asks to be reminded of.
kind SNIPPET: text dictated to be pasted somewhere - a message, a command, an address.
kind OTHER: anything else, including nonsense and accidental recordings.
title: a short label, a few words.
text: for SNIPPET the exact text to paste, with any instruction to copy it
removed; for TASK the task alone; for NOTE the note; for OTHER the transcript.'

# Prints the object. lms has no structured-output option, so the shape is asked
# for in the prompt and checked here rather than trusted: anything that is not the
# expected object is a prompt that stopped working, and the raw reply is the only
# way to see how.
classify() {
  # lms writes ANSI escapes before the answer even when piped, and those must go
  # as whole sequences -- ESC[K and ESC[?25h contain letters a character filter
  # would leave behind. Without --reasoning off the model answers with its
  # thinking attached ("none" is rejected; the choices are auto, on, off). The
  # last sed drops a fence if the model adds one anyway.
  esc=$(printf '\033')
  reply=$("$LMSTUDIO_CLI" chat --reasoning off \
            -s "$SYSTEM_PROMPT" -p "$(cat "$MD")" \
          | sed "s/${esc}\[[0-9;?]*[a-zA-Z]//g" | tr -d '\r' | sed '/^[[:space:]]*```/d')
  printf '%s' "$reply" \
    | "$JQ_CLI" -e 'has("kind") and has("title") and has("text")' >/dev/null 2>&1 \
    || { echo "model did not return the expected object: $reply" >&2; exit 4; }
  printf '%s' "$reply"
}

# One field of the classification. Read through jq at the point of use so newlines
# and quotes in the value survive intact.
field() { printf '%s' "$CLASSIFICATION" | "$JQ_CLI" -r ".$1"; }

# --- a filed recording ------------------------------------------------------
transcribe_and_file() {
  for tool in "$MACWHISPER_CLI" "$LMSTUDIO_CLI" "$JQ_CLI"; do
    [ -x "$tool" ] || { echo "not executable: \"$tool\"" >&2; exit 3; }
  done

  WAV="$ALPHAFINGER_FILE"
  BASE="${WAV%.wav}"
  STEM=$(basename "$BASE")
  MD="$BASE.transcribed.md"
  # From the app rather than dirname of the wav: the same folder either way, but
  # it is the one a tap gets too, so both paths agree by construction.
  NOTES_DIR="$ALPHAFINGER_RECORDINGS_DIR/$NOTES_SUBFOLDER"
  TASKS_FILE="$NOTES_DIR/$TASKS_FILE_NAME"

  # One transcript, in markdown, which carries a "*mm:ss*" marker per segment. The
  # model reads it as-is; the prompt below explains the markers, which is cheaper
  # than a second pass over the same audio to strip them. No --model, so MacWhisper
  # uses whichever it has selected. --overwrite because a recording can be filed
  # again under the same name after a ring reset.
  "$MACWHISPER_CLI" transcribe "$WAV" --format md -o "$MD" --overwrite

  # Not a size check: a recording with no speech still produces a file, and it can
  # hold markers and nothing else. What matters is whether anything was said.
  if ! grep -qv -e '^\*[0-9][0-9]*:[0-9][0-9]\*$' -e '^[[:space:]]*$' "$MD"; then
    echo "nothing was said in \"$MD\". Nothing to classify."
    return 0
  fi

  CLASSIFICATION=$(classify)
  KIND=$(field kind)
  TITLE=$(field title)
  echo "classified as $KIND: $TITLE"

  # A new kind is one branch here and one line in SYSTEM_PROMPT.
  case "$KIND" in
    NOTE)    note_file ;;
    TASK)    append_task ;;
    SNIPPET) copy_snippet ;;
    # Still worth a banner: it is the only sign the run happened at all, and
    # "nothing to do" is a decision the model made rather than a silence.
    OTHER)   notify "Filed" "$TITLE"; echo "left beside the recording" ;;
    *) echo "unexpected kind \"$KIND\" in: $CLASSIFICATION" >&2; exit 4 ;;
  esac
}

note_file() {
  mkdir -p "$NOTES_DIR"
  # Named after the recording, not the title: the stem is stable, sorts beside the
  # audio, and a model-written title has no business naming a file.
  DEST="$NOTES_DIR/$STEM.md"
  {
    echo "---"
    echo "recorded: $RECORDED_AT"
    echo "duration: $ALPHAFINGER_DURATION"
    echo "presses: $ALPHAFINGER_PRESS_PATTERN"
    echo "taps: $ALPHAFINGER_TAP_COUNT"
    echo "startIndex: $ALPHAFINGER_START_INDEX"
    echo "audio: $WAV"
    echo "metadata: $ALPHAFINGER_METADATA_FILE"
    echo "timestamped: $MD"
    echo "---"
    echo
    echo "# $TITLE"
    echo
    field text
  } > "$DEST"
  notify "Note" "$TITLE"
  echo "filed note: $DEST"
}

append_task() {
  mkdir -p "$NOTES_DIR"
  # The task alone, not the sentence that asked for it. Folded to one line because
  # a checklist item is one line.
  TASK=$(field text | tr '\n' ' ')
  printf -- '- [ ] %s  <!-- %s -->\n' "$TASK" "$STEM" >> "$TASKS_FILE"
  notify "Task" "$TITLE"
  echo "appended task to: $TASKS_FILE"
}

copy_snippet() {
  # .text, not the transcript: "copy this to the clipboard: <address>" must put
  # the address on the clipboard and not the request for it.
  #
  # Through a variable rather than piped straight to pbcopy: jq -r ends its output
  # with a newline, and a snippet that arrives on the clipboard with one sends the
  # message early in anything that treats Return as send. Command substitution
  # strips trailing newlines and leaves any inside the text alone.
  SNIPPET=$(field text)
  printf '%s' "$SNIPPET" | pbcopy
  # The text itself, not the title: what is on the clipboard is the thing worth
  # showing, and seeing it is how you know the right part was taken.
  notify "Copied" "$SNIPPET"
  echo "copied to the clipboard: $TITLE"
}

# --- which of the two was it? -----------------------------------------------
if [ "$ALPHAFINGER_GESTURE" = "recording" ]; then
  require $RECORDING_ONLY
  # Any recording, however many taps preceded it -- $ALPHAFINGER_TAP_COUNT says
  # how many, and is 0 for a plain one.
  transcribe_and_file
else
  refuse $RECORDING_ONLY
  case "$ALPHAFINGER_TAP_COUNT" in
    1) tap_action ;;
    2) tap_action ;;
    3) tap_action ;;
    *) echo "no action for $(taps_in_words "$ALPHAFINGER_TAP_COUNT")" ;;
  esac
fi
