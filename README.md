# claude-talk

A `/talk` slash command for [Claude Code](https://claude.com/claude-code) that speaks the last response aloud.

Like `/copy`, but for your ears. Useful when you want to keep reading code while Claude explains something, or when you're stepping away from the screen mid-task.

```
/talk              speak the last response
/talk stop         stop playback
/talk --print      print what would be spoken, don't speak
/talk --doctor     check your audio setup
```

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

### Requirements

| | |
|---|---|
| `edge-tts` | `pip install edge-tts` — neural voices, free, no API key |
| `jq` | reads the session transcript |
| `python3` | strips markdown down to speakable prose |
| `ffmpeg` | recommended; required on WSL |

Plus something to make sound, which you almost certainly already have: `afplay` on macOS, `paplay`/`pw-play`/`ffplay`/`mpv` on Linux, and on WSL nothing extra — it plays through Windows.

`edge-tts` needs a network connection. If it can't reach Microsoft's endpoint, `/talk` falls back to a local voice automatically (`say` on macOS, Windows SAPI on WSL, `spd-say`/`espeak-ng` on Linux).

## Configuration

Environment variables, or `~/.config/claude-talk/config` (plain shell syntax):

```bash
TALK_VOICE=en-US-GuyNeural   # default en-US-AriaNeural
TALK_RATE=+30%               # default +18%; negative slows down
TALK_PITCH=-5Hz              # default +0Hz
TALK_MAXLEN=6000             # chars before truncating at a sentence boundary
TALK_PLAYER=auto             # auto | windows | linux | macos
TALK_LATENCY_MSEC=200        # PulseAudio buffer, Linux route only
```

Override per-invocation too: `/talk --voice en-GB-RyanNeural --rate +40%`.

`/talk --list-voices` prints every voice edge-tts offers — several hundred, across most languages.

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

## License

MIT
