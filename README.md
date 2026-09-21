# claude-talk

A `/talk` slash command for [Claude Code](https://claude.com/claude-code) that speaks the last response aloud.

Like `/copy`, but for your ears. Useful when you want to keep reading code while Claude explains something, or when you're stepping away from the screen mid-task.

```
/talk              speak the last response
/talk stop         stop playback
/talk --print      print what would be spoken, don't speak
/talk --doctor     check your audio setup
```

Two speech engines are available. Google Cloud Text-to-Speech needs an API key and bills per character; it streams, so speech starts while the rest of the answer is still being synthesized. `edge-tts` calls Microsoft's cloud voices, is free and needs no key, and waits for the whole answer before it starts. `/talk` uses Google when a key is configured and falls back to `edge-tts` when it isn't.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/motionharvest/claude-talk/main/install.sh | bash
```

Or clone and run `./install.sh`. Both drop two files into `~/.claude/`:

```
~/.claude/talk.sh            the script
~/.claude/commands/talk.md   the slash command
```

The installer offers to take a Google API key and writes it to `~/.config/claude-talk/google-api-key` with `600` permissions. Skip it and `/talk` uses `edge-tts` instead.

Start a new session and `/talk` is available. To remove it, run `./uninstall.sh`.

### Google Cloud Text-to-Speech

Create a project in the [Google Cloud console](https://console.cloud.google.com), enable the **Cloud Text-to-Speech API** on it, then make an API key under *APIs & Services → Credentials*. The key is what `/talk` needs; there is no OAuth flow and no service account file.

If you skipped the installer prompt:

```bash
mkdir -p ~/.config/claude-talk
printf '%s' 'YOUR_KEY' > ~/.config/claude-talk/google-api-key
chmod 600 ~/.config/claude-talk/google-api-key
```

`/talk --check-key` confirms the key works and reports how many voices it can reach. `/talk --list-voices` names them all — several hundred, across most languages, in tiers that sound and cost differently. The default is `en-US-Neural2-F`; set another with `TALK_GOOGLE_VOICE`.

The key is never passed as a command line argument, so it never appears in `ps` output or in your shell history. `talk.sh` doesn't read it either — it hands the path to the synthesis client, which is the only process that sees the contents.

**Billing.** Google bills per character synthesized, at a rate that depends on the voice tier, and gives a free monthly allowance per tier. Both are on the [pricing page](https://cloud.google.com/text-to-speech/pricing); check it before you point this at long answers. `/talk` prints the character count it sent every time it speaks, and `TALK_MAXLEN` caps how much of an answer it will read at all.

**Voices that refuse speed and pitch.** Some tiers — Chirp and Studio among them — reject `speakingRate` and `pitch`. `/talk` doesn't try to predict which: it sends them, and if the API rejects them it drops both and re-sends, for the rest of that run. So `TALK_GOOGLE_VOICE=en-US-Chirp3-HD-Aoede` works, it just ignores `TALK_RATE`.

### Streaming

Google synthesis streams. `talk.sh` splits the answer at sentence boundaries, sends the opening 180 characters as its own request, and starts playing that chunk the moment it lands. The rest go out in parallel — four requests at a time by default — so they are all in hand long before the opening sentence finishes playing. First word in about a second, whatever the length of the answer.

`TALK_STREAM=0` waits for the whole answer instead and plays one file. `edge-tts` always works that way; it has no streaming mode here.

### Requirements

| | |
|---|---|
| `jq` | reads the session transcript |
| `python3` | strips markdown, and talks to the Google API |
| `ffmpeg` | recommended; required on WSL |
| `edge-tts` | `pip install edge-tts` — only for the free fallback engine |

Plus something to make sound, which you almost certainly already have: `afplay` on macOS, `paplay`/`pw-play`/`ffplay`/`mpv` on Linux, and on WSL nothing extra — it plays through Windows.

Both engines need a network connection. If neither is reachable, `/talk` falls back to a local voice automatically (`say` on macOS, Windows SAPI on WSL, `spd-say`/`espeak-ng` on Linux).

## Configuration

Environment variables, or `~/.config/claude-talk/config` (plain shell syntax):

```bash
TALK_ENGINE=auto             # auto | google | edge; auto prefers google
TALK_RATE=+30%               # default +18%; negative slows down
TALK_MAXLEN=6000             # chars before truncating at a sentence boundary
TALK_PLAYER=auto             # auto | windows | linux | macos
TALK_STREAM=1                # 0 waits for the whole file before playing
TALK_LATENCY_MSEC=200        # PulseAudio buffer, Linux route only

TALK_GOOGLE_VOICE=en-US-Neural2-D   # default en-US-Neural2-F
TALK_GOOGLE_KEY_FILE=~/keys/gcp     # default ~/.config/claude-talk/google-api-key
TALK_GOOGLE_LANG=en-GB              # default: the language in the voice name
TALK_GOOGLE_SPEED=1.2               # overrides TALK_RATE for google
TALK_GOOGLE_PITCH=-2                # semitones, -20 to 20; default 0
TALK_GOOGLE_JOBS=4                  # parallel synthesis requests
TALK_GOOGLE_ENCODING=MP3            # MP3 | OGG_OPUS | LINEAR16
TALK_GOOGLE_FIRST_CHUNK=180         # chars in the opening chunk
TALK_GOOGLE_CHUNK=700               # chars per request after that

TALK_VOICE=en-US-GuyNeural   # edge only; default en-US-AriaNeural
TALK_PITCH=-5Hz              # edge only; default +0Hz
```

`TALK_GOOGLE_KEY` holds the key itself, if you would rather keep it in the environment than in a file. Anything that can read your environment can read it, so the file is the better default.

Override per-invocation too: `/talk --voice en-US-Studio-O --rate +40%`.

`TALK_RATE` drives both engines. Google takes a multiplier rather than a percentage, so `/talk` converts `+18%` to `1.18` and clamps the result to the range 0.25 to 4.0.

`/talk --list-voices` lists the active engine's voices: name, language codes and gender for Google, `edge-tts --list-voices` output for edge.

## How it works

Claude Code writes each session to `~/.claude/projects/<project>/<session-id>.jsonl`, and exposes the session id to commands as `CLAUDE_CODE_SESSION_ID`. `talk.sh` reads that transcript directly, so nothing needs to be piped around.

Getting *the last response* right takes a little care. A turn's transcript isn't one message — it's interleaved with the "let me check X" lines Claude emits between tool calls. So the script walks backwards from the end and stops at the first message containing a `tool_use`, which leaves exactly the final answer.

The text then goes through a markdown-to-prose pass, because code fences and tables are miserable to listen to: fenced code becomes "Code block omitted", links collapse to their text, and headings, bullets, emphasis and emoji are stripped.

What reaches Google is a small Python client that `talk.sh` writes into its runtime directory at speak time. It does the sentence splitting, the parallel HTTP and the base64 decode in one process, and it is the only thing that ever holds the API key. Nothing is installed for it and there is no daemon to warm up.

The slash command uses Claude Code's `` !`...` `` syntax, so the script runs at expansion time rather than as a tool call. No model round-trip, no risk of Claude narrating over it.

## Notes on audio quality

Two problems worth knowing about, since both produce the same symptom — clicking and popping — for entirely different reasons.

**Sample-rate mismatch.** Google returns 24 kHz mono. If your sound server runs at 44.1 kHz, it has to resample by a ratio of 147/80, and a cheap inline resampler on a non-integer ratio audibly clicks. The script converts to the sink's exact format up front using [soxr](https://sourceforge.net/projects/soxr/) at 28-bit precision, so the sound server resamples nothing. You can confirm it worked — `pactl list sink-inputs` should report `Resample method: n/a` during playback.

**WSLg's `RDPSink`.** Under WSL the Linux sink streams audio to Windows over RDP with no buffer headroom. It starves partway through and crackles no matter how the stream is formatted — the giveaway is playback that starts clean and degrades. No Linux-side buffer setting fully fixes it, so on WSL the script hands the audio to Windows and lets the native audio stack play it, taking WSLg out of the path entirely.

If you're using some other TTS setup on WSL and hearing the same grit, this is very likely why.

## Troubleshooting

`/talk --doctor` reports the detected platform, every dependency, your sink format, whether a Google key was found and works, and the resolved transcript path.

**Nothing plays.** Check `--doctor` found a player. On Linux, `sudo apt install ffmpeg pulseaudio-utils` covers it.

**"API key not valid".** The key is wrong, or the Cloud Text-to-Speech API isn't enabled on the project the key belongs to. Enabling it takes a minute to propagate. `/talk --check-key` tests it on its own.

**Crackling on WSL.** Should be handled automatically. If it persists, `TALK_PLAYER=linux /talk` uses the PulseAudio route instead, and `TALK_LATENCY_MSEC=400` gives it a bigger buffer.

**"could not find session transcript".** `CLAUDE_CODE_SESSION_ID` is only set inside Claude Code — expected if you ran `talk.sh` straight from a terminal.

**It spoke the wrong thing.** `/talk --print` shows exactly what the extractor picked up without making any sound, and without spending any characters.

**A key is configured but `/talk` still uses edge.** `/talk --doctor` prints the resolved engine and where it looked for the key. An empty key file counts as no key.

**Speech stutters or pauses mid-answer.** Streaming ran out of chunks, which means a request was slow. Raise `TALK_GOOGLE_JOBS` so more of them are in flight, or set `TALK_STREAM=0` to wait for the whole answer.

**`/talk` costs more than expected.** Every `/talk` re-synthesizes the whole answer — there is no cache. `--print` is free, `TALK_MAXLEN` caps the ceiling, and Standard voices cost a fraction of the neural tiers.

## License

MIT
