# Client smoke harness (headless, Lune)

`tools/smoke` boots the real client code from `src/` in [Lune](https://github.com/lune-org/lune)
and drives it through scripted scenarios. It catches Luau runtime errors that
luau-lsp cannot see (UiKit property tables are untyped, `UiKit.new` returns
`any`), checks the camera/cursor state machine, and estimates text sizes at
four viewport sizes.

**It is not Roblox.** Nothing is rendered, there is no physics, and the GUI
layout is a simplified model. A PASS means "no Luau error and the checked
behaviour held in an emulation"; it does not replace a Studio playtest.

## Running

```sh
bash tools/smoke/run.sh                 # all scenarios, concise report
bash tools/smoke/run.sh --verbose       # every check, tracebacks, game print() output
bash tools/smoke/run.sh --only=c,d      # selected scenarios (self-check and boot always run)
bash tools/smoke/run.sh --no-editables  # AssetService:CreateEditable* throws (tests the fallback path)
bash tools/smoke/run.sh --no-camera-scripts  # disable the PlayerModule stand-in (see below)
bash tools/smoke/run.sh --root=/path/to/other/checkout
bash tools/smoke/run.sh --profile       # time spent in the layout model
```

Needs Lune 0.10.x (tested with 0.10.4; not pinned in `rokit.toml`, set
`LUNE=/path/to/lune` if it is not on `PATH`). A full run takes ~15 s.
Exit status: `0` no scenario failed (WARN allowed), `1` a scenario FAILed,
`2`/`3` setup problems.

## Reading the report

The first table has one line per scenario: `PASS`, `WARN` (only warnings) or
`FAIL` (a failed check or a Luau error in game code). Below it, each scenario
lists its non-passing checks, then:

* `ERROR(game @ src/...:N)` - a Luau error whose location is in the game
  source: a thrown error in a controller, a signal handler, a delayed
  callback, or a `warn("[Signal] handler error: ...")` from the shared
  Signal. These fail the scenario.
* `ERROR(harness)` - an error raised inside the harness itself (a mock gap or
  harness bug). Shown as a warning; please fix the harness, not the game.
* `warn()` - other `warn` output from the game.
* `harness notes` - emulation gaps hit during the run (an engine method the
  harness does not implement was called and returned nil, a property had no
  known default). They are not game bugs but can explain odd results.

Scenario `0` loads a deliberately broken snippet through the same loader and
confirms every error class below is caught with `file:line`. If it fails, do
not trust the rest of the report.

## Scenarios

| id | what it does | what it checks |
|---|---|---|
| 0 | self-check snippet | unknown property read/write, wrong value type, read-only write, wrong enum, bad `Instance.new`, bad `Parent`, bad tween goal, Roblox-legal coercions accepted, error inside an `Activated` handler, infinite `WaitForChild` |
| a | runs `src/client/init.client.luau` (its own init/start order), spawns the character, sets `workspace.MapReady` | script reaches its last line, every Controllers module required, `ClientArtReady` set, loading card cleared, no thread stuck in `WaitForChild` |
| b | State snapshots (threats, team, objective), Notify toasts (good/bad/info, a 9-toast burst), every `fx("Name", ...)` cue found by scanning `src/server` with plausible data, `Carrying`/`Downed` attributes, Ping broadcast and the G key | text appears / disappears, toasts expire and stay bounded, no Luau errors from any cue, one rate-limited Ping |
| c | Session payloads shaped like `Workstation.payload()`: empty desktop, click sweep of every non-leave button, all six drives started and played with seeded random clicks against the **real** `src/server/Minigames` modules (stage 2 and completion forced if random play does not reach them), power loss, story fragment, phantom window, FinalPurge / SignOff / ClockOut, leave by button, Backspace, gamepad B and jumping out | windows show their content, each view renders controls, `start`/`act`/`bossReply`/`phantom`/`purgeCancel`/`signOffStart`/`signOffConfirm` are sent, every Desktop `FireServer` passes `Workstation.onDesktop`'s validation (session id, kind, argument types, known command), remote payloads survive serialisation, leaving fires `Leave` once and closes the desktop |
| d | ProximityPrompts made by the **real** server factory `src/server/Util/Prompts.luau` on parts in front of the camera (E and F keys, hold and instant, an own "Help up" prompt), keyboard / gamepad / touch, hold begin/end, tap, desktop open, phone viewport, prompt behind the camera, prompt destroyed | prompts use `ProximityPromptStyle.Custom`, at most one card, nearest prompt wins, own prompt hidden, card inside the viewport, hold timing, keycap relabels per input type, card hidden while seated |
| e | sit / Session active, `Desktop.leave()`, server kick, server ends while still seated, death, respawn, character replaced while seated, active payload after standing up, `Cursor.request` from another reason, icon hidden by someone else | walking = `LockCenter` + icon hidden + `Custom` + `LockFirstPerson`; seated = `Default` + icon visible + `Scriptable`; `Cursor.isFree()` matches; nothing sticks after 20 frames with the camera-script stand-in fighting for the mouse |
| f | HUD state (toast, pager, carry hint, prompt card) and desktop state (FileSort + Messenger + fragment window) at 667x375, 1366x768, 1920x1080, 2560x1440 | readable fonts >= 13 px, pixel fonts (Silkscreen, Arcade) >= 8 px, no visible element beyond the viewport. Small text is a FAIL at desktop sizes and a WARN on the phone viewport; off-screen elements are WARN only (approximate layout) |

## How it works

* **Instances** (`lib/rt.luau`) are userdata proxies (`typeof` = `"Instance"`)
  over a record that owns hierarchy, attributes, tags and signals. Each keeps
  a real `@lune/roblox` Instance of the same class as a *shadow*: every
  property write is replayed on it first, so wrong names, types and enums
  throw like Roblox, and unset properties read Roblox defaults. Membership
  (property / event / method), read-only flags and script security come from
  `api_members.json`, a compact index of the public API dump
  (`python3 tools/smoke/gen_api.py API-Dump.json` regenerates it). Roblox's
  own coercions (enum by name or number, number to string, numeric string to
  number) are accepted. Errors are raised at the game's call site.
* **Events** are fake `RBXScriptSignal`s. Engine-originated events (remotes,
  input, RunService, prompts) start handlers immediately in their own thread;
  property / attribute / child changes fire deferred, like Roblox's default
  `SignalBehavior`. Destroy disconnects everything.
* **Time** (`lib/sched.luau`) is virtual: `task.wait/delay/defer/spawn`,
  `wait`, `os.clock`, `tick`, `time` all use a clock that advances only when
  a scenario steps frames, so long loops and fades cost nothing.
* **Modules** (`lib/loader.luau`) are mounted from `default.project.json`
  like Rojo (`init.luau`, `init.client.luau`, `.server.luau`), with the
  StarterPlayerScripts copy placed in `Players.LocalPlayer.PlayerScripts`;
  `require`, `script`, `game`, `workspace` and the datatype globals are
  provided per script. Sources load unmodified.
* **Engine stand-ins** (`lib/services.luau`): Players with a LocalPlayer,
  PlayerGui and a character (Humanoid, HumanoidRootPart, Head); Camera with
  pinhole `WorldToViewportPoint` / `ViewportPointToRay`; UserInputService,
  RunService (frame = sleepers, BindToRenderStep by priority, RenderStepped,
  layout, Stepped, Heartbeat), GuiService, ContextActionService (priority
  dispatch, Sink), TweenService, Sound, ProximityPrompt hold/trigger,
  CollectionService, AssetService (fake EditableImage/EditableMesh with
  Roblox's buffer-size and mesh-size limits), TextService, Debris,
  StarterGui, remotes. A **PlayerModule stand-in** keeps the camera on the
  head and re-locks the mouse to `LockCenter` every frame while the camera is
  not Scriptable and the player is in first person, which is what the seated
  camera must override. As in Roblox, a visible `GuiButton` with `Modal =
  true` or the open Roblox menu releases the lock regardless of
  `MouseBehavior`; scenario `e` reports that effective state (and the raw
  property).
* **Server** (`lib/server.luau`) builds State snapshots and Session payloads
  with the real minigame modules and validates every client `FireServer`
  (the accepted `act` actions and desktop commands are re-read from
  `Workstation.luau`'s `ACTIONS` and every `registerCommand("...")` call).
* **Layout** (`lib/layout.luau`) computes AbsoluteSize/Position and
  TextBounds once per frame for each changed ScreenGui and fires their change
  signals.

## Limitations (read before trusting a result)

* Layout is approximate: UDim2, AnchorPoint, UIScale (about the anchor point;
  on a ScreenGui about its top-left), UIPadding, UISizeConstraint,
  UIAspectRatioConstraint, UIListLayout (incl. UIFlexItem fill/grow/shrink,
  SpaceBetween/Around/Evenly, Stretch), UIGridLayout, AutomaticSize (one
  extra pass), ScrollingFrame canvas, ClipsDescendants, `IgnoreGuiInset`
  (58 px top bar). Not modelled: rotation, UIPageLayout, UITableLayout,
  wrapping list layouts, safe-area insets, real glyph metrics.
* Text metrics are estimates: width = characters x TextSize x a per-family
  factor (Silkscreen 0.78, Ubuntu 0.52, Inconsolata 0.55, ...), height =
  lines x TextSize. TextScaled picks the largest size <= 100 that fits,
  clamped by UITextSizeConstraint. TextBounds is unscaled (not multiplied by
  UIScale). Treat the legibility numbers as +/- 10 %.
* AbsoluteSize updates once per frame (Roblox is also deferred, but not on
  the same schedule); TextBounds is computed on read.
* No rendering, z-order or hit testing: a click reaches a button even if
  another element covers it; `Visible`, `Enabled`, clipping and the viewport
  are respected. No `GuiService` gamepad selection navigation.
* Tweens apply their end values immediately on `Play`; `Completed` fires
  after the tween's duration.
* No physics: `workspace:Raycast` only hits a floor plane at y = 0. Seats,
  jumping and character respawn are scripted by the scenarios.
* The map is a stub with the parts the client looks up by name
  (`Map.Interactive.SourceScreen_1..6`, `DoorStatusLight`, `PrinterLed`, a
  rain window, a `Surface` texture, four art anchors); `MapBuilder` does not
  run here (`tools/audit` covers the map).
* Prompt visibility comes from a small stand-in for Roblox's prompt system:
  a prompt is shown when Enabled, in the workspace, within
  `MaxActivationDistance` of the HumanoidRootPart and on screen;
  `Exclusivity` (OnePerButton / OneGlobally) and `MaxPromptsVisible` apply;
  `RequiresLineOfSight` is ignored. Shown prompts get their keyboard /
  gamepad key (after ContextActionService). Roblox's real choice between
  same-key prompts may differ.
* Remote ordering is immediate (no latency); the mock server is a stand-in,
  not `src/server` (except the minigame modules and the prompt factory).
* Sounds never play audio; non-looped sounds with an id fire `Ended` 1.5 s
  after `Play`.
* `RunService:IsStudio()` is false; `settings()` / `UserSettings()` are not
  emulated.

## Adding a scenario

Write `scenarios/<name>.luau` returning `function(H)`, register it in
`main.luau`. Use `H.step(n)` / `H.run(seconds)` to advance frames,
`H.fire(remote, ...)` for server->client remotes, `H.buttons()`,
`H.findText(text)`, `H.click(rec)` / `H.tap(rec)`, `World.pressKey(keyCode)`
(`keyDown` / `keyUp` to hold), `H.camState()`, `H.clientModule(path)`,
and `H.Report.check/warn/info`. `World.remoteLog` holds every `FireServer`.
