# claude-talk

A `/talk` slash command for [Claude Code](https://claude.com/claude-code) that speaks the last response aloud.

Like `/copy`, but for your ears. Useful when you want to keep reading code while Claude explains something, or when you're stepping away from the screen mid-task.

```
/talk              speak the last response
/talk stop         stop playback
/talk --print      print what would be spoken, don't speak
/talk --doctor     check your audio setup
```

Two speech engines are available. `edge-tts` calls Microsoft's cloud voices and needs a network. XTTS-v2 runs on your own machine, needs no network at speak time, and can clone a voice from a short recording. `/talk` prefers XTTS-v2 when it is installed and falls back to `edge-tts` when it is not.

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/motionharvest/claude-talk/main/install.sh | bash
```

Or clone and run `./install.sh`. Both drop two files into `~/.claude/`:

```
~/.claude/talk.sh            the script
~/.claude/commands/talk.md   the slash command
```

Start a new session and `/talk` is available. To remove it, run `./uninstall.sh`.

### Local voices with XTTS-v2

The base install uses `edge-tts`. To add the local engine:

```bash
./xtts/install-xtts.sh
```

That builds a virtualenv under `~/.local/share/claude-talk/venv`, installs PyTorch and `coqui-tts` into it, downloads the XTTS-v2 checkpoint, and copies the server to `~/.claude/talk-xtts.py`. It asks you to accept the model license first and installs nothing if you decline. Expect roughly 8 GB of disk and a long first run.

Once it is installed, `/talk` uses it by default. `/talk --engine edge` goes back to the cloud voice for one run, and `TALK_ENGINE=edge` makes that permanent.

XTTS-v2 takes ten to twenty seconds to load, so the server holds the model in memory between requests and exits after fifteen minutes of silence. `/talk --warm` loads it ahead of time. The daemon listens on a unix socket in the runtime directory, not on a network port.

Playback streams. The server renders the answer in chunks and `/talk` starts playing the first one while the rest are still being made. Synthesis runs about twice as fast as speech plays back, so the player never runs dry. On a warm daemon the first word arrives in about a second for a short answer and under four for a long one, rather than scaling with the length of the answer. Chunks always break at sentence boundaries in ordinary prose. `TALK_STREAM=0` restores the older behaviour of waiting for the complete file.

**Cloning a voice.** Record 6 to 30 seconds of clean speech as a wav file, then set `TALK_XTTS_SPEAKER_WAV=/path/to/voice.wav`. `/talk --speaker /path/to/voice.wav` does the same for one run. Without a clip, `/talk` uses a built-in speaker, and `/talk --list-voices` names all of them.

**License.** XTTS-v2 is published under the [Coqui Public Model License](https://coqui.ai/cpml), which permits non-commercial use only. `edge-tts` is the engine to use for commercial work.

### Requirements

| | |
|---|---|
| `edge-tts` | `pip install edge-tts` — neural voices, free, no API key |
| `jq` | reads the session transcript |
| `python3` | strips markdown down to speakable prose |
| `ffmpeg` | recommended; required on WSL |

XTTS-v2 adds its own requirements, all installed into its own virtualenv by `xtts/install-xtts.sh`: PyTorch, `coqui-tts`, and about 2 GB for the checkpoint. A CUDA GPU is optional. On CPU the model runs, and it runs slower than speech plays back, so a long answer will not start immediately.

Plus something to make sound, which you almost certainly already have: `afplay` on macOS, `paplay`/`pw-play`/`ffplay`/`mpv` on Linux, and on WSL nothing extra — it plays through Windows.

`edge-tts` needs a network connection. If it can't reach Microsoft's endpoint, `/talk` falls back to a local voice automatically (`say` on macOS, Windows SAPI on WSL, `spd-say`/`espeak-ng` on Linux).

## Configuration

Environment variables, or `~/.config/claude-talk/config` (plain shell syntax):

```bash
TALK_ENGINE=auto             # auto | xtts | edge; auto prefers xtts
TALK_VOICE=en-US-GuyNeural   # default en-US-AriaNeural; edge only
TALK_RATE=+30%               # default +18%; negative slows down
TALK_PITCH=-5Hz              # default +0Hz; edge only
TALK_MAXLEN=6000             # chars before truncating at a sentence boundary
TALK_PLAYER=auto             # auto | windows | linux | macos
TALK_LATENCY_MSEC=200        # PulseAudio buffer, Linux route only

TALK_XTTS_VOICE="Ana Florence"        # default "Claribel Dervla"
TALK_XTTS_SPEAKER_WAV=~/voice.wav     # clone this voice instead
TALK_XTTS_LANG=en                     # default en
TALK_XTTS_SPEED=1.2                   # overrides TALK_RATE for xtts
TALK_XTTS_IDLE=900                    # seconds idle before the model unloads
TALK_STREAM=1                         # 0 waits for the whole file before playing
```

Override per-invocation too: `/talk --voice en-GB-RyanNeural --rate +40%`.

`TALK_RATE` drives both engines. XTTS takes a multiplier rather than a percentage, so `/talk` converts `+18%` to `1.18` and clamps the result to the range 0.5 to 2.0.

`/talk --list-voices` lists the active engine's voices. For `edge-tts` that is several hundred across most languages. For XTTS-v2 it is the built-in speakers in the checkpoint.

## How it works

Claude Code writes each session to `~/.claude/projects/<project>/<session-id>.jsonl`, and exposes the session id to commands as `CLAUDE_CODE_SESSION_ID`. `talk.sh` reads that transcript directly, so nothing needs to be piped around.

Getting *the last response* right takes a little care. A turn's transcript isn't one message — it's interleaved with the "let me check X" lines Claude emits between tool calls. So the script walks backwards from the end and stops at the first message containing a `tool_use`, which leaves exactly the final answer.

The text then goes through a markdown-to-prose pass, because code fences and tables are miserable to listen to: fenced code becomes "Code block omitted", links collapse to their text, and headings, bullets, emphasis and emoji are stripped.

The slash command uses Claude Code's `` !`...` `` syntax, so the script runs at expansion time rather than as a tool call. No model round-trip, no risk of Claude narrating over it.

## Notes on audio quality

Two problems worth knowing about, since both produce the same symptom — clicking and popping — for entirely different reasons.

**Sample-rate mismatch.** `edge-tts` returns 24 kHz mono. If your sound server runs at 44.1 kHz, it has to resample by a ratio of 147/80, and a cheap inline resampler on a non-integer ratio audibly clicks. The script converts to the sink's exact format up front using [soxr](https://sourceforge.net/projects/soxr/) at 28-bit precision, so the sound server resamples nothing. You can confirm it worked — `pactl list sink-inputs` should report `Resample method: n/a` during playback.

**WSLg's `RDPSink`.** Under WSL the Linux sink streams audio to Windows over RDP with no buffer headroom. It starves partway through and crackles no matter how the stream is formatted — the giveaway is playback that starts clean and degrades. No Linux-side buffer setting fully fixes it, so on WSL the script hands the file to Windows and lets the native audio stack play it, taking WSLg out of the path entirely. That costs about a second before speech starts, for an 8 MB WAV copy into the Windows temp directory.

If you're using some other TTS setup on WSL and hearing the same grit, this is very likely why.

## Troubleshooting

`/talk --doctor` reports the detected platform, every dependency, your sink format, and the resolved transcript path.

**Nothing plays.** Check `--doctor` found a player. On Linux, `sudo apt install ffmpeg pulseaudio-utils` covers it.

**Crackling on WSL.** Should be handled automatically. If it persists, `TALK_PLAYER=linux /talk` uses the PulseAudio route instead, and `TALK_LATENCY_MSEC=400` gives it a bigger buffer.

**"could not find session transcript".** `CLAUDE_CODE_SESSION_ID` is only set inside Claude Code — expected if you ran `talk.sh` straight from a terminal.

**It spoke the wrong thing.** `/talk --print` shows exactly what the extractor picked up without making any sound.

**XTTS is installed but `/talk` still uses edge.** `/talk --doctor` prints the resolved engine and both paths it looks for. It needs `~/.claude/talk-xtts.py` and an executable python at `~/.local/share/claude-talk/venv/bin/python`.

**XTTS synthesis fails.** Run `~/.local/share/claude-talk/venv/bin/python ~/.claude/talk-xtts.py status` for the model and daemon state. The daemon writes its own log next to the audio, in `$XDG_RUNTIME_DIR/claude-talk/xtts.log`.

**XTTS speech cuts off.** XTTS-v2 truncates any input longer than roughly 250 characters, so the server splits text at sentence boundaries and joins the audio afterwards. A cut-off answer means a chunk was dropped rather than truncated, which the log will show.

**Speech stutters or pauses mid-answer.** Streaming ran out of chunks, which means synthesis fell behind playback. The opening chunk has a floor of 110 characters precisely to stop that happening at the start. If it still happens, synthesis on your machine is slower than speech plays, which is normal on a CPU. Set `TALK_STREAM=0` to wait for the whole file instead.

**`/talk` right after `/talk stop` is slow.** A cancelled stream finishes the chunk it is already rendering before releasing the model, which costs up to about five seconds. Waiting a moment, or letting the answer finish rather than stopping it, avoids the delay.

## License

MIT
