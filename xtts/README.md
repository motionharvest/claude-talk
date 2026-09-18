# XTTS-v2 engine for claude-talk

This module replaces the cloud speech engine in `/talk` with [XTTS-v2](https://huggingface.co/coqui/XTTS-v2) running on your own machine. Nothing leaves the host at speak time, and the voice can be cloned from a short recording.

## Install

```bash
./install-xtts.sh
```

The installer checks the host, asks you to accept the model license, builds a virtualenv at `~/.local/share/claude-talk/venv`, installs PyTorch and `coqui-tts` into it, downloads the checkpoint, and copies `xtts_server.py` to `~/.claude/talk-xtts.py`. It installs nothing if you decline the license.

`talk.sh` finds the engine by looking for that server script and that python. When both are present, `/talk` uses XTTS-v2. When either is missing, `/talk` falls back to `edge-tts`.

## Why there is a daemon

Loading XTTS-v2 takes ten to twenty seconds. Paying that on every `/talk` would make the command useless. So `xtts_server.py serve` holds the model in memory and answers requests over a unix socket in `$XDG_RUNTIME_DIR/claude-talk/xtts.sock`. The client starts the daemon on first use and the daemon exits after `TALK_XTTS_IDLE` seconds of inactivity, which defaults to 900. A unix socket rather than a TCP port keeps the engine reachable only by processes that can read the socket file, which is created mode 0600.

## Why the text is split

XTTS-v2 truncates any input longer than roughly 250 characters for English. A typical Claude answer is far longer than that, so the server splits the text before synthesis. Splitting happens at sentence boundaries first, at word boundaries only when one sentence is itself too long, and mid-word only when one word is too long. The resulting audio is concatenated with 80 ms of silence between chunks. `split_text` preserves every non-whitespace character of the input, which is checked in the tests below.

Speaker conditioning is computed once per speaker and cached, so the per-chunk cost is inference alone.

## Using it directly

```bash
VENV=~/.local/share/claude-talk/venv/bin/python
$VENV ~/.claude/talk-xtts.py status
$VENV ~/.claude/talk-xtts.py speakers
$VENV ~/.claude/talk-xtts.py say --text "Hello." --out /tmp/out.wav
$VENV ~/.claude/talk-xtts.py preload
$VENV ~/.claude/talk-xtts.py stop
```

`say` prints the path of the wav file it wrote, which is how `talk.sh` consumes it.

## Protocol

One JSON object per line in each direction over the socket. Requests carry an `op` of `ping`, `preload`, `speakers`, `synthesize` or `shutdown`. Every response carries `ok`, and an `error` string when `ok` is false.

```json
{"op":"synthesize","text":"Hello.","out":"/tmp/out.wav","speaker":"Claribel Dervla","language":"en","speed":1.18}
{"ok":true,"out":"/tmp/out.wav","chunks":1,"seconds":0.94,"device":"cuda","rate":24000}
```

## Voice cloning

Record 6 to 30 seconds of clean speech, mono, no music and no background noise. Point `TALK_XTTS_SPEAKER_WAV` at the file, or pass `/talk --speaker /path/to/voice.wav` for one run. A reference clip takes precedence over `TALK_XTTS_VOICE`.

Clone only a voice you have permission to clone.

## License

The code here is MIT, like the rest of claude-talk. XTTS-v2 itself is published under the [Coqui Public Model License](https://coqui.ai/cpml) and permits non-commercial use only. Use `/talk --engine edge` for commercial work.

## Tests

```bash
./test-dispatch.sh
```

That runs 22 checks and needs neither the virtualenv nor the checkpoint. It builds a throwaway `HOME`, writes a fake session transcript, and puts a stub in place of the real server, so it exercises `talk.sh` end to end without loading a model. `test-chunker.py` runs on its own and covers `split_text` against ten inputs, including empty text, a 700-character single word, 400 words with no punctuation, and strings exactly at the limit.

## What is verified

Verified by `./test-dispatch.sh` on this working copy, on Linux 6.18 under WSL2 with Python 3.12.3: all 22 checks pass. They cover engine dispatch, the rate-to-speed conversion and its clamps, voice and language overrides, reference-clip forwarding, voice listing, warm-up, the doctor report, and the error path when XTTS is requested but absent. `split_text` produces no chunk over the limit, no empty chunk, and loses no non-whitespace character.

Not verified here: synthesis through the real model, audio quality, and load or inference timings. Those need the checkpoint, which the installer downloads only after you accept the license. The author's expectation, untested, is that a CUDA GPU synthesizes faster than real time and a CPU does not.
