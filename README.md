# AlphaFinger

A macOS menu-bar app that pulls voice recordings off an **Index01** ring, then optionally runs commands. Just shell commands.

---

## Before you build this

**This software was vibe-coded** — written fast, in conversation with an LLM, by
someone who had never seen this device's Bluetooth protocol. Most of it was
inferred from watching the ring behave; there was never any specification or
agreement.

**It talks to your ring over Bluetooth, and it could brick it.** There is no reason
to think it will — see *What it will not do to your ring* — but nobody has proven
it safe. It may also drain the
battery faster than the official app, lose recordings, or mis-date them. It has
been run against exactly **one** ring, by **one** person, on **one** Mac.

If that is not acceptable, use the official app. Terms are at the end.

---

## What it is

The Index01 is a ring that records audio when you hold its button. It has apps for
phones. It has nothing for macOS.

AlphaFinger sits in your menu bar, waits for the ring to say it has something, and
files each recording as a WAV with a JSON sidecar:

```
2026-08-23T131852Z-a1b2c3d4e5f6-tap0-0308.wav
[ring's own clock]-[ring id   ]-[taps]-[index]
```

`tap0` is a plain recording; `tap1` means you tapped once before recording. The
timestamp is the **ring's** clock, so a recording made hours before it syncs is
still dated when you made it.

It can also run a shell command when you tap without recording — the same command
as for a recording, told apart by the variables it is given.

You can buy the ring at **[repebble.com](https://repebble.com)**.

## How the audio is stored

The ring does not send WAV. It sends something considerably more interesting, and
decoding it is most of what this app does.

Audio arrives **losslessly compressed**, using a scheme built from two classic
pieces that predate the device by decades.

### Second-order DPCM

Rather than storing each sample, the ring stores how the signal is *changing* —
[differential pulse-code
modulation](https://en.wikipedia.org/wiki/Differential_pulse-code_modulation).
Speech is smooth on the scale of a single sample, so consecutive samples are
close together and the differences are small numbers. Small numbers are cheap.

This one is **second order**: it keeps a velocity as well as a position, and the
stored value is the change in the *change*. Decoding runs a double integrator:

```
velocity += residual
position += velocity      // position is the sample
```

That is a two-tap [linear
predictor](https://en.wikipedia.org/wiki/Linear_predictive_coding) — it assumes the
waveform continues in a straight line and stores only the error in that guess.
Getting the order wrong is not subtle: a single integrator still produces
speech-shaped output, but leaves a discontinuity at every record boundary, which
you hear as a loud regular click.

Samples are also quantised first: a fixed number of low bits is dropped before
encoding. That part is *not* lossless, and it is the only lossy step.

### Golomb–Rice coding

The residuals then go through [Golomb–Rice
coding](https://en.wikipedia.org/wiki/Golomb_coding), an [entropy
coder](https://en.wikipedia.org/wiki/Entropy_coding) designed for exactly this
shape of data: values clustered near zero, getting rarer as they grow.

The encoding is delightfully direct. Zero is a single `1` bit. A residual of
magnitude *n* is *n* zeros, a `1`, and a sign bit — so small values cost a few
bits and large ones cost more, in proportion to how unlikely they are. That is
[unary coding](https://en.wikipedia.org/wiki/Unary_coding), the simplest possible
variable-length code. A run of zeros beyond a threshold escapes to a literal, so a
genuinely large jump does not cost an absurd number of bits.

Golomb coding is named for [Solomon W.
Golomb](https://en.wikipedia.org/wiki/Solomon_W._Golomb), who described it in
1966. The power-of-two variant used here is due to **Robert F. Rice** at NASA's Jet
Propulsion Laboratory in the 1970s, developed for compressing telemetry from
spacecraft where bandwidth was measured in bits per second and there was no
possibility of asking for a retransmission.

The same family underpins [FLAC](https://en.wikipedia.org/wiki/FLAC) and
[Shorten](https://en.wikipedia.org/wiki/Shorten_%28file_format%29) — a linear predictor
followed by Rice-coded residuals is close to the standard recipe for [lossless
audio compression](https://en.wikipedia.org/wiki/Lossless_compression).

The app converts to plain
[PCM](https://en.wikipedia.org/wiki/Pulse-code_modulation) and writes a mono
[WAV](https://en.wikipedia.org/wiki/WAV) at the ring's own sample rate, which is
not one of the usual ones — resampling it would throw away accuracy for no reason.

## Running something afterwards

One command in Settings runs after a recording is filed, and after taps with no
recording. Which one it was is in
`$ALPHAFINGER_GESTURE` — `recording`, or `1-tap`, `2-tap`… — and a recording
additionally gets `$ALPHAFINGER_FILE` and three more, so testing for a file is how
a script tells the two apart. None of the recording variables are set for a tap.
`$ALPHAFINGER_TAP_COUNT` is how many taps there were; for a recording that is how
many preceded it, so `0` for a plain one.

Context arrives as environment variables, never spliced into the command line,
where a filename would be one odd character away from becoming shell syntax. The
field is run with `/bin/sh`, so any shell command works; a script given by path
must be executable.

Two can be absent, so default them rather than requiring them.
`$ALPHAFINGER_TIMESTAMP` is missing when the ring's clock was never set — a
recording made before that has no time to report — and
`$ALPHAFINGER_BATTERY_MILLIVOLTS` when the collection carried no reading.

`examples/transcribe-and-file.sh` is a worked example: it transcribes the
recording with [MacWhisper](https://goodsnooze.gumroad.com/l/macwhisper)'s `mw`
(as markdown, which marks each segment with the time it was spoken), asks a local
model through [LM Studio](https://lmstudio.ai)'s `lms` what kind of thing it is,
and files it — a note, a task, or straight onto the clipboard. The prompt explains
the timestamps, so no second pass is needed to strip them. It also uses `jq`,
which is part of macOS, so there is nothing to install for that.

The model is asked for a small object rather than a one-word answer:

```json
{"kind": "NOTE|TASK|SNIPPET|OTHER", "title": "a few words", "text": "the payload"}
```

`text` is the part worth keeping, separated from the words that asked for it — for
`SNIPPET` the exact text to paste with any *"copy this to the clipboard"* removed,
for `TASK` the task alone, for `NOTE` the note. Without that separation, dictating
*"copy to the clipboard: 14 rue de la Paix"* puts the whole sentence on your
clipboard instead of the address. `lms` has no structured-output option, so the
shape is asked for in the prompt and then checked with `jq`; a reply that is not
that object stops the run and is quoted back in the log. Adding a kind is one
shell function, one line in a `case`, and one line in the prompt.

It needs no configuration: the command field holds the script's path and nothing
else. Everything it uses either arrives from the app as an `ALPHAFINGER_*`
variable or is a named constant at the top of the file. It branches on the gesture
and then checks what that case promises — the recording variables must be present
for a recording and **must be absent for a tap**, so a mismatch stops it rather
than letting it work from a stale path. A tap with no recording then picks its
action by `$ALPHAFINGER_TAP_COUNT`, which is where per-tap-count commands live now
that Settings has a single field.

Transcripts are written beside the `.wav`; notes and `tasks.md` go in a `notes/`
folder inside your recordings folder, which the app names in
`$ALPHAFINGER_RECORDINGS_DIR` so a tap — which has no file — can find it too.
Every call also appends a row to `calls.csv` there before anything slow happens,
so a run that fails later still leaves a record of itself.

Both tools are named by absolute path because the app inherits **launchd's**
`PATH` when opened from Finder — `/usr/bin:/bin:/usr/sbin:/sbin`, which has
neither `/usr/local/bin` nor `~/.lmstudio/bin` on it. The script prints the
`ALPHAFINGER_*` variables it was given before doing anything, and those land in
the debug log.

Commands run on their own serial queue, so a slow one — transcription takes tens
of seconds — never blocks the interface or the fetch loop. They are given five
minutes before being terminated, and killed shortly after that if they ignore it.

## No binaries

There is no dmg, no release, no notarised build, no Homebrew formula, and there
will not be one. **Build it yourself.** I don't want to make this easy to use
until people who know what they're getting into have been happy with it for some
time.

Because you built it yourself it is unsigned, so macOS will refuse to open it the
first time. Right-click the app → **Open** → **Open** again in the dialog. You only
need to do this once.

## Building

Requires **Xcode** (the full app, not just Command Line Tools) and macOS 13 or
later. Nothing else — no package manager, no dependencies, no toolchain to
install.

```sh
make app
open build/AlphaFinger.app
```

`make help` lists everything: `build`, `test`, `app`, `clean`.

If you happen to build inside a **nix shell**, note that `make` strips the SDK
variables nix exports: Apple's `swiftc` refuses to build against a non-Apple SDK.
The same applies to `sourcekit-lsp` if your editor inherits that environment.

### Tests

```sh
make test     # 111 tests, no hardware required
```

The end-to-end tests run against a synthetic ring session generated by
`SyntheticRing.swift` — encoded audio, button presses, multipart recordings — so
there is nothing real in this repository and the tests work on a clean checkout.
`testRiceRoundTrip` encodes a known waveform and decodes it back, which is what
keeps the generator honest.

There is no command-line tool: this repository builds one thing, a menu-bar app.

## First run

1. Build and open it. Get past Gatekeeper as above.
2. macOS will ask for **Bluetooth**. It needs this. Without it the app scans
   forever and finds nothing.
3. Recordings go to `~/Documents/AlphaFingerRecordings` unless you pick somewhere else
   in Settings. The folder is created when the first recording arrives.

The menu-bar icon tells you what is happening — a dashed ring for no ring paired,
dotted while looking, solid when connected, an arrow while downloading.

macOS used to ask for local network permission on launch — reading the hostname
triggers mDNS, and that call is gone. If it ever asks anyway, denying it costs
nothing: the app makes no network requests at all.

## If it does not work

The app writes a debug log to `~/Library/Application Support/AlphaFinger/`, one
folder per run, and the **Debug** window in the menu shows the same thing live.
Turn verbosity up in Settings if you need more. Deleting those folders is safe —
how far through the ring's recordings the app has got is a preference
(`cursorIndex`, tagged with `cursorRing`), not a file in there.

**That log identifies your ring** — it contains its Bluetooth identifiers and, at
higher verbosity, raw payloads. Read it before sharing it anywhere.

Tested only on macOS 26.5. It is built against the macOS 13 SDK, but CoreBluetooth
behaviour differs between releases and several bugs found during development were
version-specific, so older systems are genuinely untested.

## What it will not do to your ring

**It cannot write anything to your ring except the clock.** There are exactly two
places in the entire codebase that write over Bluetooth, both in
`RingSession.swift`: an outbound queue, and a single-byte probe used to start
pairing. Everything reaching that queue passes through `send()`, which

- **refuses erase operations unconditionally**, and
- **refuses program operations at every address except the clock.**

So the complete set of bytes it can put on the device is: read requests, a 4-byte
clock value, one `0x00` byte to trigger pairing, and the standard subscribe
writes.

**There is no firmware-update path in this codebase.** None. Not disabled, not
gated behind a flag — absent.

**It makes no network requests.** No telemetry, no analytics, no update check,
nothing.

**It never erases anything on the ring.** How far it has got is remembered on
your Mac, as a preference; the ring's own storage is left alone. The ring seems to
delete older records on its own.

## This is not official

Not endorsed by, affiliated with, or connected to the ring's maker or any other
company. Nobody asked for it and nobody approved it.

**Interoperability.** The hardware has no macOS support. This makes it work on a
platform its maker does not target.

## Warranty and liability

**No warranty of any kind, express or implied** — including merchantability,
fitness for a particular purpose and noninfringement. **No liability** for any
claim, damage or other loss arising from the software or its use, in contract,
tort or otherwise. Building or running it is entirely at your own risk.

## Licence

**None. All rights reserved.**

Nothing is granted here. Contributions have no defined terms, for you or for me,
which is worth knowing before you spend time on a patch.

This can change. If a licence is added it will be announced.
