# TODO — Splash Menu Bar

Improvement backlog, 2026-11-03. Verified against the codebase and a live
splash 1.5.0 server (schema_version 6, 607-field `/status`).

Priority: **P1** = fix/ship first · **P2** = next batch · **P3** = optional.

---

## 1. Correctness (bugs found in review)

- [x] **P1 — "Memory" row is always "—"** (done 2026-11-04). `StatusDoc.memory_current_bytes`
  (StatusClient.swift) does not exist in schema 6. The live doc has
  `memory_actual.current_bytes` (and `memory_actual.peak_bytes`). Decode the
  new shape (keep the old top-level field for older splash). Show current +
  peak in the LOAD section.
- [x] **P1 — Engine crashes are invisible** (done 2026-11-04: warning card for
  recovering/unstable/metal-unhealthy engines). The app only watches its own
  child (the Python wrapper). If the `serve-native` engine dies, the wrapper
  restarts it; `/status` reports it via `transport.recovering`,
  `transport.restarts`, `transport.last_crash_trace`, `metal.healthy`,
  `metrics.metal_failures`, `metrics.capacity_failures` — none decoded. UI
  shows a green ● while the engine crash-loops. Surface an "engine
  recovering / restarted N×" warning (and a notification, see §3).
- [x] **P1 — Launch race with an external server** (done 2026-11-04:
  `startServer()` probes `/status` on the configured port before spawning;
  a splash answering there (started outside the app) is adopted — no
  child, no crash. The auto-restart and the crash notification re-probe
  the port the same way, so a child that dies on "address in use" behind
  a healthy external server is treated as adoption (no restart loop, no
  "splash exited" banner), and the flyout shows a neutral "splash exited —
  an external server is serving this port" card instead of the red crash
  card). On launch,
  `startServer()` starts a child unconditionally. If an external splash
  already holds the port, the child exits with "address in use" and the
  flyout shows a red crash card *and* a green "external" chip. Probe
  `/status` first: if an external splash is serving, don't start a child
  (or show an informational card instead of a red crash card).
- [x] **P2 — Model catalog is stale and hardcoded** (done 2026-11-04:
  `suggested-models.tsv` is read next to the installed splash binary, with the
  hardcoded table as fallback; Settings shows download size, a one-line
  description, and an orange "needs N GB RAM" warning).
  `SplashModels.catalog` (9 models) was missing 2 of the 11 entries in the
  installed splash's own `suggested-models.tsv`
  (`unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q2_K_XL`,
  `unsloth/Qwen3.8-27B-GGUF:UD-IQ3_XXS`). That TSV (shipped at
  `<splash install>/install/suggested-models.tsv`, resolved relative to the
  `splash` binary) also carries per-model minimum-RAM and download-size
  columns, and splash's own desktop app consumes it. Read the TSV instead of
  the hardcoded list; show "36 GB RAM · 21 GB download" per model and warn
  when the model exceeds the Mac's RAM before the first start.
- [x] **P2 — Silent settings fallbacks** (done 2026-11-04: the Port field
  is validated as a number in 1–65535 and the model as non-empty, with
  orange inline errors under the fields and Save disabled while invalid).
  `SettingsModel.asConfig` does
  `Int(port) ?? 8081` and empty model → default. Typing a bad port silently
  restarts the server on 8081. Validate port/model inline and block Save.
- [x] **P2 — Speed graph X axis is misleading** (done 2026-11-04: relabel
  route — section now reads "DECODE SPEED · TOK/S", and the section/graph
  help say the plot holds the last N samples taken while generating,
  evenly spaced by count, with idle gaps not stretching it).
  `tpsHistory` only samples
  *while decoding* (MetricsStore.apply), but the section says "SPEED OVER
  TIME": a 20 s burst of samples is stretched across the whole 5-min span.
  Either plot real timestamps with idle gaps, or relabel to "last N samples
  while generating".
- [x] **P2 — Model folder links** (done 2026-11-04): the flyout's Model row
  and Settings' "Downloaded · N on disk" line are blue links that open the
  model's folder in the Hugging Face cache in Finder
  (`SplashModels.storageURL(for:)` — the repo's newest snapshot); plain text
  when the repo isn't in the cache yet.
- [x] **P2 — Empty "LAST REQUEST" section** (done 2026-11-04): the section is
  log-derived, so an adopted (external) server — and any moment before the
  first finished request — showed a wall of "—". It now renders only once a
  request has actually completed.
- [x] **P2 — Prefill ETA shape** (done 2026-11-04): the Prefill row's
  "… left" now uses the ring's `Fmt.eta` shape ("6m 04s", "10s") instead of
  "364.3s".
- [x] **P2 — MEM bar flicker** (done 2026-11-04): the bar color follows
  `memory_pressure`, which oscillates around its threshold; a new value now
  has to be reported on two consecutive polls before the color switches
  (MetricsStore test: `testMemoryPressureOscillationDoesNotFlicker`).
- [x] **P3 — SERVER label consistency** (done 2026-11-04): the Model and
  Endpoint row labels were dimmer (`.secondary`) than every other row; all
  SERVER labels now use the same style.

## 2. Better information to display (all confirmed in live `/status`)

- [x] **P1 — ITL p50/p95** (done 2026-11-04): an "ITL (p50 / p95)" row in
  LOAD ("36.4 ms / 113 ms" live), with the 1000 ÷ ITL perceived-speed
  explanation in the hover.
- [x] **P1 — `memory_pressure`** (done 2026-11-04): the Mem load bar is
  colored by the server's pressure report — green = normal, yellow = warning,
  red = critical (orange until the first /status arrives); explained in the
  bar's hover text. *Design note: originally proposed as a header pill next to
  thermal state; dropped in favor of reusing the existing MEM bar.*
  `memory_governor.denied_reservations` is still not surfaced (optional).
- [x] **P2 — Decode progress for in-flight requests** (done 2026-11-04):
  while a request generates, a "Decode" row in LOAD like the prefill one —
  "737 tok · 41s", plus "· ~9m 29s left" when it carries a max-tokens cap.
- [x] **P2 — Draft acceptance rate** (done 2026-11-04): a "Draft accept"
  row in LOAD from the endpoint's lifetime rate ("43%" live; "off" when the
  server reports no drafted tokens); the log-parsed "Tok/cycle" stays in
  LAST REQUEST as the per-request view.
- [x] **P2 — Queue wait** (done 2026-11-04): the Active row appends
  "· waiting 12 s" (`admission.oldest_wait_ms`) once requests are queued or
  blocked on resources (`scheduler.waiting_resources`).
- [x] **P2 — KV cache** (done 2026-11-04): a "KV cache" row in LOAD —
  allocated bytes + lifetime reused tokens ("3.7 GiB · 4.35M tok reused"),
  explaining *why* similar prompts run fast. `kv_capacity_tokens` lives
  under `memory_plan` (excluded debug depth), so it's not shown.
- [x] **P2 — SSD cache** (done 2026-11-04): an "SSD cache" row in SERVER —
  "0.0 GiB / 32.0 GiB", orange "· writes gated" while writes are paused
  (`disk.writes_gated` is a "yes"/"no" string in schema 6, decoded
  leniently as string-or-bool).
- [x] **P2 — Weights lifecycle** (done 2026-11-04): the LOAD "Weights" row
  now carries the lifecycle — load time + "· released" / "· reloading" +
  restore counts, with the idle-release timeout (`600 s` live) in the
  hover; hidden while the weights simply sit loaded.
- [x] **P2 — Linkable Endpoint URL** (done 2026-11-04): the Endpoint row is
  a blue link; clicking opens the URL in the default browser (splash's chat
  page).
- [x] **P3 — SERVER facts** (done 2026-11-04): "Input" (text · image · pdf)
  and "ANE" (split · 56%) rows in SERVER; `memory_actual.peak_bytes` was
  already surfaced in the Memory row.
- [x] **P3 — Server self-reported staleness** (done 2026-11-04): a
  "Health" row in SERVER — "age 0.0 ms · tick 128 ms"; orange when the
  snapshot is >2 s old or a loop tick ran >1.5 s.
- Not adding: `latency.*` histograms, `identity`/`memory_plan` internals —
  debug depth, not menu-bar depth.

## 3. Workflows

- [x] **P1 — Auto-restart on crash** (done 2026-11-04: "Auto-restart" toggle
  in Settings; waits 2 s, up to 3 consecutive crashes, a manual Start resets
  the count, Stop cancels a pending restart). The README promised the app
  "keeps it alive"; before, a crash left the server dead until someone
  pressed Start.
- [x] **P1 — Crash notification** (done 2026-11-04: "splash exited" banner
  with a "Start splash" action; suppressed while an auto-restart is pending).
  A menu bar app isn't always in view; the only crash signal before was a
  faint icon and "✕".
- [x] **P2 — Launch at login** (`SMAppService.mainApp`). Make it a configurable
  option in Settings (done 2026-11-04: "Launch at login" toggle in Settings;
  the app registers/unregisters itself as a system login item on Save,
  re-syncs from the saved preference at launch (covers toggling it in System
  Settings), and a failed change alerts instead of being saved. Verified in
  System Settings → Login Items.)
- [x] **P2 — Launch at login** (`SMAppService.mainApp`). A server-keeper
  that dies on reboot isn't keeping anything alive. (done 2026-11-04 — same
  feature: at login the app starts and `startServer()` brings splash up.)
- [x] **P2 — Notifications for**: model download finished/failed,
  thermal → serious/critical, weights released after idle. (done 2026-11-04:
  "Model ready" banner when the server reports Ready after it actually
  fetched files during startup (a crash mid-download is covered by the
  existing "splash exited" banner); a banner on each crossing into thermal
  "serious"/"critical"; a banner when /status reports the weights were
  released after idleness. All plain banners via the existing permission
  flow.)
- [x] **P2 — Open the WebUI**: the Endpoint row is inert text; splash ships
  a chat page. (done — the Endpoint row is now a clickable link opening the
  chat page in the default browser; see the §2 note.)
- [x] **P3 — Persist the pinned flyout's position** across app restarts.
  (done 2026-11-04: the pin state and the flyout's top-left corner persist
  in the config; a pinned flyout reopens pinned at its saved corner on
  launch — falling back to under the status item if that corner is no
  longer on any screen.)
- [x] **P3 — "Reset to defaults"** in Settings. (done 2026-11-04: footer
  button; sets every field to `SplashConfig.default` — blank stays "splash's
  own default" — and nothing changes until Save.)

## 4. Information that shouldn't be displayed (noise)

- [x] **P2 — "Deduplicated" row** (done 2026-11-04: row dropped; the niche
  figure is explained in the "Input / cached" hover, which is where the
  per-request dedup share belongs).
- [x] **P2 — "avg" detail under the tok/s ring** (done 2026-11-04): kept,
  but shortened to "avg 42.5" (dropped "t/s") — the number stays, the unit
  clutter goes. (User decision; it does mirror the graph's dotted line, but
  the inline figure is the one people read.)
- [x] **P2 — "Weights load" in the LOAD section** (done 2026-11-04: the
  Weights lifecycle row moved to SERVER — it's a server-state fact, and the
  startup card still shows the load time at boot).
- [x] **P2 — Two unlabeled "memories"** (done 2026-11-04: bar caption is
  "Mac RAM", the LOAD row is "splash (server)"; both hovers state the
  distinction explicitly).
- [x] **P2 — "cached" gauge fallback mixes semantics** (done 2026-11-04:
  the ring is always the lifetime hit rate — "share of prompt tokens served
  from the cache since the server started"; the per-request figure stays in
  LAST REQUEST → "Input / cached", and the ring's hover says so).
- [x] **P3 — Endpoint URL as plain text** (done 2026-11-04: the Endpoint row
  is a blue link that opens splash's chat page in the default browser —
  same as the §2 item).
- [x] **P3 — "Context" row** (done 2026-11-04: merged into the Model row's
  hover — "context window N tokens (prompt + output for one request)"; the
  row itself is gone, the Model row doubles as the model-finder link).

## 5. Error handling

- [x] **P1 — Crash card shows one line** (done 2026-11-04: shows the last 5
  timestamp-stripped output lines; the card is shown even when splash printed
  nothing, using the launch-failure note). Tracebacks are multi-line.
- [x] **P1 — Exit codes are ambiguous** (done 2026-11-04: `CrashInfo`
  carries `bySignal` from `Process.terminationReason`; the card and tooltip
  read "killed by signal N" vs "exited with code N", and a failed spawn says
  "couldn't launch: …").
- [x] **P2 — One poll timeout flips ready → not-ready** (done 2026-11-04:
  a single failed `/status` poll is a first strike only; the dot and the
  "ready" state flip only after two consecutive failures — one slow poll no
  longer blips the menu bar. MetricsStore test:
  `testPollFailureNeedsTwoConsecutiveStrikes`).
- [x] **P2 — Config I/O is silent** (done 2026-11-04: `load()` quarantines a
  corrupt `~/.splashmenubar.json` to `~/.splashmenubar.json.bak` and
  reports the reason via a warning the app surfaces at launch; `save()`
  returns a `Bool` — Settings' Save checks it and shows a "Couldn't save
  settings" alert instead of claiming success).
- [x] **P2 — Port occupied by a non-splash service** (done 2026-11-04: the
  launch/exit port probe now classifies — splash, another service, or
  nothing. "Another service" shows an orange "port in use" card: "Something
  else (not splash) is serving port N, so the splash the app started
  exited. Stop that service — or change the port in Settings — then press
  Start." Verified live against a non-splash HTTP server on a test port).
- [x] **P3 — `brew install` can stall** (done 2026-11-04: the install
  card shows an orange hint after 5 minutes without output — "No output
  for 5 minutes — brew may be waiting on the network, or on an Xcode
  license it can't ask for (run `sudo xcodebuild -license accept`…)";
  the install keeps running, with Cancel).
- [x] **P3 — Proxy defense** (done 2026-11-04: the `/status` poll goes
  through a small `URLProtocol` (`DirectLoopbackProtocol`) that opens a
  direct loopback socket — `URLSession` proxy settings, including PAC
  configs that route 127.0.0.1, can no longer intercept the poll. Status
  Client tests: `testProbeClassifies{SplashServer,OtherService,Nothing}`
  run the protocol against live local HTTP servers).

## 6. User controls

- [x] **P1 — Color Picker** (done 2026-11-04: right-click the TOK/S,
  PREFILL or CACHED ring and choose "Color…" — the system color panel
  opens pre-selected with the ring's current color and updates it live. A
  `ColorPicker` embedded in the context menu renders disabled on macOS —
  color wells don't work inside NSMenu — so the menu item opens
  NSColorPanel instead).
- [x] **P1 — Color Picker** (done 2026-11-04: right-click the GPU, CPU or
  Mem bar and choose "Color…" for the same panel flow. The Mac RAM bar
  shows the user's color only while the server's pressure is normal —
  warning/critical pressure overrides it).
- [x] **P1 — Color Picker** (done 2026-11-04: right-click the DECODE SPEED
  graph and choose "Color…" for the same panel flow, recoloring the line
  and its fill).
- [x] **P1 — Theme** (done 2026-11-04): "Appearance" picker in Settings —
  System / Light / Dark — applied to the flyout and every window via
  `preferredColorScheme`; persisted like every other setting (Save).
  All picks save straight to the config (they take effect immediately and
  survive restarts; `SplashConfig.gaugeColors`, hex per gauge).

## Done / considered solid (do not touch)

- Stop/kill logic: re-identifies pids after the grace period, never touches
  non-splash listeners (`findServerPIDs`, `killAfterGrace`).
- `isSplash` guard on `/status` replies (a non-splash service on the port is
  not mistaken for a running server).
- `OutputReader` line splitting: multibyte-safe (0x0A/0x0D never occur
  inside a UTF-8 character), handles `\r` progress redraws, delivers an
  unterminated final line at EOF.
- ANSI stripping for stacked progress bars.
- `TQDM_POSITION=-1` forcing byte-level download bars over a non-TTY pipe.
- Private-API thermal sensor degrades gracefully (nil) if macOS drops the
  symbols.

## Suggested first batch — DONE 2026-11-04

1. `memory_actual` decode + peak row. ✅
2. Engine health surfaced (`transport.recovering/restarts`, `metal.healthy`
   warning card; `memory_pressure` → MEM bar color, per design change). ✅
3. Multi-line crash card + signal-vs-exit code. ✅
4. Read `suggested-models.tsv` instead of the hardcoded catalog. ✅
5. Auto-restart toggle + crash notification. ✅

Verified: 26 unit tests pass; smoke-launched against the live server —
memory row shows server memory, MEM bar green under normal pressure,
external-server chip + multi-line crash card on port conflict, Settings
shows TSV catalog (11 models, download sizes, descriptions) and the
Auto-restart toggle. Auto-restart verified end-to-end against a dummy
/status on a taken port: the child crashed with "cannot bind … Address
already in use", the app retried (errors from both attempts accumulate in
the crash card), then gave up at 3 with the crash card + notification.

## §1 Correctness batch — DONE 2026-11-04

1. Launch race: `startServer()` probes `/status` before spawning; an
   external splash on the port is adopted (no child, no crash card).
   Auto-restart and the crash notification re-probe the port on every
   exit, so "address in use" behind a live external server never
   crash-loops or notifies; the flyout shows a neutral info card while
   the external "chip" explains the state. ✅
2. Settings validation: port (number, 1–65535) and model (non-empty)
   checked inline with orange errors; Save disabled while invalid. ✅
3. Speed graph relabeled "DECODE SPEED · TOK/S" (last N samples while
   generating, evenly spaced by count; idle gaps don't stretch it). ✅

Verified: 30 unit tests pass (26 + 4 new SettingsModel validation).
Smoke-launched the new build against a live splash 1.5.0 already
serving port 8081: the app adopted it — no `splash serve` child spawned,
flyout shows green dot + "external" chip with the external server's live
metrics (no red crash card), the adopted server survives app quit, and
the Settings window renders with Save enabled on valid fields.

## §2 Information batch — DONE 2026-11-04

1. LOAD: ITL p50/p95 row ("36.4 ms / 113 ms"); Decode progress row
   ("737 tok · 41s · ~9m 29s left"); Draft accept ("43%", "off" with no
   draft traffic); KV cache ("3.7 GiB · 4.35M tok reused").
2. Active row appends "· waiting N s" from `admission.oldest_wait_ms`
   once requests are queued or blocked on resources.
3. Weights row upgraded to a lifecycle: load time + released / reloading
   + restore counts, idle-release timeout in the hover; hidden while the
   weights simply sit loaded.
4. SERVER: Input modalities, ANE split (state · share), SSD cache
   (used / limit, orange "writes gated" when paused), Health (status age
   · max loop tick, orange when stale), and the Endpoint row is now a
   link that opens the URL in the default browser.
5. tok/s ring detail shortened to "avg N"; `Fmt.context` gained a million
   tier (3,492,100 → 3.49M).
6. `FlexBool` decode for `disk.writes_gated` (a "yes"/"no" string in
   schema 6; also accepts booleans and never fails the document).

Verified: 35 unit tests pass (30 + 5 new StatusDoc/MetricsStore decode
tests). Smoke-launched the new build against the live splash 1.5.0 on
8081 (adopted, "external" chip): every new row rendered with live values
— ITL, Decode (with time-left), Draft accept, KV cache, Input, ANE,
SSD cache, Health, Endpoint as a blue link, ring detail "avg 42.5".

## §4/§5/§6 batch — DONE 2026-11-04

Noise, error handling, and user controls in one pass.

1. Noise (§4): the "Deduplicated" row is gone (its figure is explained in
   the "Input / cached" hover); the Weights lifecycle row moved LOAD →
   SERVER; the whole-Mac bar is captioned "Mac RAM" and the server memory
   row "splash (server)", each hover stating the distinction; the CACHED
   ring is always the lifetime hit rate (per-request share stays in LAST
   REQUEST); the Endpoint row is a link; the static Context row merged
   into the Model row's hover.
2. Error handling (§5): a failed `/status` poll is one strike — ready →
   not-ready needs two consecutive failures; a corrupt config is
   quarantined to `~/.splashmenubar.json.bak` and reported, and a failed
   Settings write alerts; a port held by a non-splash service shows an
   orange "port in use" card instead of a bare crash card (verified
   live against a dummy non-splash HTTP server); a stalled `brew install`
   (5 min silent) gets an orange hint naming the likely causes; and the
   poll now goes through `DirectLoopbackProtocol` — a `URLProtocol` that
   opens the loopback socket directly, so system/PAC proxy settings can't
   intercept it.
3. User controls (§6): right-click any ring (TOK/S, PREFILL, CACHED), bar
   (GPU, CPU, Mem) or the DECODE SPEED graph and choose "Color…" — the
   system color panel (NSColorPanel, continuous) recolors that element
   live; a `ColorPicker` inside the context menu is disabled by macOS, so
   the panel is the picker. Picks persist in `SplashConfig.gaugeColors`
   and take effect immediately (the Mac RAM bar shows pressure color
   instead while warning/critical). Settings gained an "Appearance"
   System/Light/Dark picker applied app-wide via `preferredColorScheme`.

Verified: 51 unit tests pass (35 + 4 color/theme round-trip,
`testPollFailureNeedsTwoConsecutiveStrikes`, 3 live `testProbeClassifies*`
that run the direct-connection protocol against local HTTP servers, 3
`GaugeColorPanel` tests for the pick → live update → coalesced save path).
Smoke-launched against the live server: rings/bars/graph recolored from
injected config values, light theme applied, "Mac RAM" / "splash
(server)" labels, Weights under SERVER, no Deduplicated/Context rows, and
the "port in use" card against a dummy non-splash service.
