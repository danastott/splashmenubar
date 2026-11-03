# Splash Menu Bar

A macOS menu bar app that runs `splash serve`, keeps it alive, and shows its
live inference metrics.

## What it does

- **Install check**: on launch (and when you press **Start**) the app looks
  for `splash` on its PATH. If it's missing, it asks you to either install it
  yourself (**Copy Command** copies `brew install incoai/tap/splash`) or
  authorize the app to run that Homebrew install for you, with live output
  in a progress window. The server starts automatically once the install
  succeeds. If Homebrew itself isn't found, it points you to https://brew.sh.
- **Auto-start**: launching the app starts `splash serve` with the configured
  parameters (see Settings below).
- **Start / Stop / Restart**: the flyout's icon buttons switch between a
  green ▶ **Start** and a red ■ **Stop** based on whether a server is actually
  serving the configured port. Stop, Restart and Quit (⏻) ask for
  confirmation first. **Stop** shuts the server down even when it
  was started outside the app: it finds the splash server listening on the
  port and its `serve-native` engine, SIGTERMs them, and SIGKILLs after 5 s.
  A process on the port that isn't splash is never touched, and a `/status`
  reply that isn't splash's isn't mistaken for a running server. If the server dies on
  its own the flyout shows a crashed state and offers to start it again.
  Quitting the app stops only its own server (and its engine, waiting up to
  3 s so nothing is left holding the model); an externally started server is
  left running.
- **Pin**: the pin icon in the flyout's header keeps the flyout open: clicking
  elsewhere, pressing Esc, clicking the menu bar item or using its buttons no
  longer closes it, until you click the pin again to unpin it. While pinned
  you can drag it anywhere on screen by its top edge (the pointer turns into
  a hand there); unpinning snaps it back
  under the menu bar item.
- **Startup progress**: until splash reports Ready, the flyout shows a
  *Starting up* card: the current stage (preparing, downloading
  `owner/repo`, loading weights, starting the server), a progress bar with
  size, speed and time left while the model downloads, elapsed time, and the
  latest line splash printed. The menu bar reads `⏳ 42%` during a download (a green ● once serving with no requests yet),
  and its tooltip names the stage. If splash exits, the flyout shows its
  last output line.
- **Live metrics** from the server's `GET /status` endpoint, polled every
  2 s by default (configurable):
  - **tok/s gauge** (live decode batch, falling back to the lifetime decode
    speed and the last log-parsed request), a **prefill gauge** (the
    running prefill batch's tok/s, falling back to the lifetime prefill
    speed; full ring = 500 tok/s) and a **cache-hit gauge**
    (`cache.hit_rate`)
  - **tok/s line graph over time** (sampled from the polled status), with a
    0-based Y axis labeled at round steps and a dotted average line
  - load: completed/cancelled/failed requests, TTFT p50/p95, prefill and
    decode speed, total output, active requests (decode/prefill/queued),
    memory, uptime, thermal state, and the chip temperature (the hottest
    Apple silicon die sensor, read through IOKit's HID event system; shown in
    °F or °C per System Settings › General › Language & Region)
  - **prefill progress**: while a request is in its prompt phase,
    `prompt_processed / prompt_tokens` from `active_requests` with an
    estimated time left (remaining tokens ÷ current prefill speed)
- **Last request** detail (from splash's stdout lines): output, input/cached,
  deduplicated, TTFT, tok/cycle.
- The status bar item shows the live tok/s while decoding, e.g. `▣ 78.5 t/s`; while a prompt is prefilling (and nothing is decoding) it shows the prompt progress instead, e.g. `▣ ◐ 46%`; when the server is idle it shows a green ●.

## Build

```sh
make          # builds SplashMenuBar.app (needs the Xcode/CLT Swift toolchain)
make run      # builds and launches
make clean
```

## Settings

Open the gear icon in the flyout (or press ⌘, after focusing it). The dialog
edits the full `splash serve` command line, persisted to
`~/.splashmenubar.json`; saving restarts the server:

| Field | Flag | Notes |
|---|---|---|
| Model | `--model` | drop-down of splash's supported models, grouped into Downloaded (with size on disk) and Not downloaded; **Custom…** takes any `OWNER/REPO[:VARIANT]` |
| Port | `--port` | e.g. `8081` |
| Max memory | `--max-memory` | e.g. `28G` (blank = auto) |
| Idle release | `--idle-release` | e.g. `off` (blank = default 10m) |
| Max context | `--max-context` | e.g. `100K` (blank = auto) |
| KV format | `--kv-format` | `int8` (default) or `bf16` |
| State format | `--state-format` | `fp32` (default) or `bf16` |
| Max cache disk | `--max-cache-disk` | e.g. `16G`; `0` turns it off (blank = auto) |
| Language only | `--language-only` | skip vision |
| Disable Neural Engine | `--disable-ane` | prefill on GPU alone |
| Persistent cache | `--persistent-cache` | keep the SSD cache across restarts |

Blank optional fields and default pickers omit the flag entirely.

Downloaded models are found in the Hugging Face cache (`HF_HUB_CACHE`, else
`HF_HOME/hub`, else `~/.cache/huggingface/hub`), where splash downloads them.
Other GGUF variants of the supported repos found there are listed too.

Below the splash options, **UI refresh** sets how often the app polls
`/status` to update the flyout and menu bar: 500 ms, 1 s, 2 s (default), 5 s
or 10 s. It's stored in the same file as `refreshInterval`; changing only this
doesn't restart the server. **Speed graph span** sets how many minutes of
generation the tok/s graph shows: 1, 3, 5 (default), 10, 15 or 30 min, stored
as `graphMinutes`; it also doesn't restart the server.

Every element in the flyout and the Settings window has hover text explaining
it.

`splash` is resolved from `PATH`; since apps launched from Finder get a
minimal PATH, `/opt/homebrew/bin`, `/usr/local/bin`, and `~/.local/bin` are
prepended automatically.

## How it works

- `SplashProcess` owns the `splash serve` child process, reads stdout/stderr
  on dedicated threads (blocking `availableData` loops) and dispatches
  complete lines to the main thread. `SplashParser` turns lines into events
  (Started/Done requests, thermal transitions, the Ready line, weights load,
  and startup stages). Lines are split on `\r` as well as `\n` so download
  progress bars come through, and the child gets `TQDM_POSITION=-1`, which
  makes huggingface_hub draw its byte-level bars even though stderr isn't a
  TTY.
- `StatusClient` polls `http://127.0.0.1:<port>/status` every 2 s;
  `MetricsStore` merges the polled snapshot with the log-derived per-request
  data into one `@Published` state.
- The flyout is a borderless, non-activating `NSPanel` positioned just below
  the menu bar on the status item's screen, clamped inside the screen (the
  body scrolls and the control bar stays pinned when it cannot fit). It
  dismisses on outside click, Escape, or clicking the status item again.

## Notes

- The app is unsigned; open it with `make run` or by double-clicking
  `SplashMenuBar.app` on your own machine.
- While a request is in flight the last completed values stay on screen;
  endpoint metrics update every 2 s.
