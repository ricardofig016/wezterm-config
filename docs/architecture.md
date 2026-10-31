# Architecture

The session layer is four session modules, the entry, and a shell hook.
`lib\state.lua` owns the schema and the files, `lib\layout.lua` owns the planner
and restore, `lib\save.lua` owns the change detector, `lib\log.lua` owns the
log, and `shell\history.ps1` owns per-pane PSReadLine history. `wezterm.lua`
only assembles them. This note covers the state model, the invariants a future
change must not break, the two details that cost the most to learn, the
post-restore self-check, and the known limits. Where this note states a
behaviour, it names the spec or scenario that pins it; limits are sourced from
the plan.

## State model

The schema is version 1. One JSON file per live instance lives at
`<state dir>\sessions\<instance id>.json`, with a transient
`<instance id>.json.tmp` during a write. There is no index file and no single
"current session" file.

`version` is the integer `1`. `state.validate` rejects any other value, and
restore logs `restore.version` and falls back rather than reading a file it
does not understand. State spec: "read and read_latest reject a mismatched
schema version".

`saved_at` is Unix seconds. Restore rejects a state older than 604800 seconds
(seven days) and logs `restore.stale`. State spec: "is_stale compares against
the seven day cap". Fault spec: "a stale state file logs, shows a failure and
opens a maximized fallback".

`instance` is `{ id, started_at }`. `id` is minted once per process from the
current time and a random suffix, then memoized, so every save from one process
goes to one file. `started_at` is Unix seconds for the process that saved. The
id is what makes two live instances independent: each writes only
`<id>.json`, so neither can replace the other. State spec: "the instance id is
memoized so repeated saves cannot mint several files", "two instances own two
files and restore reads the newest". Integration scenario `two_instances`
checks `no_overwrite_idle`, `read_latest_newest` and `peer_not_overwritten`.

`window` is `{ cols, rows, active_tab, active_pane }`. `cols` and `rows` are
the active tab's cell extent, taken from the maximum right and bottom edge of
its pane rectangles, so the dividers are included. Restore passes them as the
`width` and `height` of the mux spawn call, which are cells, not pixels.

`window.active_tab` is a one-based position in `tabs`. It is not a tab id.
`window.active_pane` is a pane id, and pane ids in this build start at zero, so
zero is a valid active pane while a one-based position cannot be zero. The two
fields deliberately use different kinds of value. Save spec: "active tab is
a one-based position while active pane is a pane id". State spec: "an active
pane id of zero validates and round-trips".

`tabs` is an ordered array. `tabs[].title` is a string; an unset title falls
back to the active pane's title when the state is collected, while an empty
title stays empty. Save spec: "an unset tab title falls back to the active pane
title, but an empty title stays empty". The array order is the tab order
restore rebuilds.

`tabs[].panes` is an ordered array. The order is the saved order. The planner
takes it as input and replays leaves by input position, not by geometry, so a
restored layout keeps the saved pane identity even when the geometric order
differs. Layout spec: "plan is pure and deterministic" and "plan round-trips
one to eight panes at zero tolerance".

`tabs[].panes[].id` is the pane's numeric id from `pane:pane_id()`. It is the
only pane identity in the schema; array position and geometry are not identity.
Restore turns the saved id into `WEZTERM_SESSION_HISTORY_KEY` for the pane it
creates. Save spec: "collect reads tabs, titles, pane rects, cwds, active tab
position and active pane id".

`tabs[].panes[].rect` is `{ left, top, width, height }`. Every value is cells.
The rectangle is tab-relative: `left = 0, top = 0` is the tab's top-left
corner, not the window's. Width and height must be positive. No pixel value is
stored anywhere in the schema. Layout spec: "the captured five-pane fixture
round-trips with its dividers".

`tabs[].panes[].cwd` is a string. The collector reduces the URL form's leading
slash and `file://` prefix to `C:/...`; restore passes the string to the window
spawn, each `spawn_tab` and each split. The self-check normalizes slashes, case
and a trailing separator before comparing, so `C:\work` and `c:/work/` are the
same directory. Layout spec: "selfcheck ignores case, slash direction and a
trailing separator".

`tabs[].panes[].foreground` is optional: `{ argv, alt_screen }`, where `argv`
is a non-empty string array and `alt_screen` is a boolean. Restore types the
joined argv once the pane's shell answers the foreground process query, and
only when `alt_screen` is true. This is the only terminal input restore sends,
and it is a command line, not saved screen output. Layout spec: "restore replays a
full-screen program once the shell answers". Save spec: "collect records
alt-screen foreground only when a process record exists".

Per-instance files mean the newest `saved_at` wins. `read_latest` lists
`sessions\` with `wezterm.read_dir`, validates each file, and returns the valid
one with the greatest `saved_at`; a tie breaks on the instance id so the result
is deterministic. A file that fails validation is skipped, never repaired. The
writer opens `<id>.json.tmp`, writes, reads the file back, parses it, checks
the version and validates it, and only then replaces `<id>.json`. Windows
rename refuses an existing destination, so the old file is removed only after
the temporary file has proved itself, and the rename is retried. A crash can
leave a `.tmp`; the next save from that instance truncates it. State spec: "a
full state round-trips through write and read", "read_latest picks the largest
saved_at and breaks ties by instance id", "a truncated temporary file leaves
the previous state intact".

The state directory defaults to
`C:\Users\rfigueiredo\AppData\Roaming\wezterm-session-layer` and
`WEZTERM_SESSION_STATE_DIR` overrides it. Tests use the override so they never
read or write the live directory. State spec: "state directory honours
WEZTERM_SESSION_STATE_DIR and its pinned fallback".

## Invariants

### Config evaluation is side-effect free, and it happens more than once per process

`wezterm.lua` builds the config and registers gui-startup handlers. It starts
no timer, writes no file and captures no state at load. WezTerm evaluates a
config more than once per process, so a load-time timer would be registered
twice and save twice. The save detector therefore starts inside gui-startup,
and `save.start` is idempotent so a repeated startup event cannot add a second
chain. The log is initialized in gui-startup too; a process that never gets
there never touches the disk. Save spec: "start is idempotent and gui-startup
always returns true". State spec: "the logger stays inert until init is called".

A config change that adds a timer, a write or a capture at load time breaks
this invariant.

### Only the instance whose fingerprint changed writes

The fingerprint covers the schema version, the window cell size, the active tab
position and active pane id, every tab title, and every pane id, rectangle and
cwd. It excludes `saved_at` and `instance`, so a save that only touches the
clock is not a change. It also excludes the foreground program record, which
the plan's fingerprint definition does not list.

Each second the detector collects the live window, fingerprints it, and writes
only after the fingerprint has been stable for two seconds. An idle instance
compares an unchanged fingerprint with its last write and writes nothing, so it
cannot overwrite another instance's file. The explicit save key writes at once,
updates the baseline, and shows the save time in the status area. A failed
write logs `save.failed`, shows ` save failed `, and starts a fresh settle
window instead of retrying every tick. Save spec: "the debounce writes after
two stable seconds and not while idle", "collected fingerprints are stable
until a tracked field changes", "a refused write shows save failed, logs it,
and a later save replaces the status". Integration scenario `save_timing`
checks `idle_silent_10s` and `split_saved_within_3s`; `two_instances` checks
`no_overwrite_idle`.

Only the instance that owns a file writes it, and it writes only when its
fingerprint changed. A future contributor who adds a periodic unconditional
write, or writes to a shared file name, breaks both halves.

### Every geometry value is cells

Window size, pane rectangles and split sizes are cells. The planner's `cells`
field is the second side's size and is passed to `pane:split` as a numeric
size. Nothing converts cells to pixels on the save or restore path. Pixel
dimensions appear only in test assertions that the maximize fallback actually
ran. Layout spec: "plan round-trips one to eight panes at zero tolerance". The
property spec asserts the same thing over 30 seeds: "seed N: random layouts of
one to eight panes round-trip at zero tolerance".

### Screen text is never replayed

The schema has no field for screen text, and restore never calls
`inject_output`. It rebuilds panes and their cwds, sets titles, activates the
saved tab and pane, and types a saved foreground program's argv. That is why
the archived plugin's scrollback replay and its `inject_output` workaround do
not exist here. Layout spec: "restore spawns saved cell dimensions and rebuilds
tabs in order".

## The two hard-won details

### A split leaves a one-cell divider that belongs to neither pane

Live WezTerm panes do not tile their bounding box. A `pane:split` reserves one
cell between the siblings, and that cell is part of neither pane. For a Right
split of a parent `W` cells wide whose second side is `b`, the first side is
`a = W - 1 - b`, the divider is the cell after it, and the second pane starts
at `parent.left + a + 1`. Bottom splits use the same arithmetic on rows, and
nested splits apply inside a child's rectangle. The planner accepts exactly
that geometry and rejects overlaps, holes, exact tilings and gaps that are not
a one-cell divider. A planner that asked for exact tiling would reject every
real layout. Layout spec: "plan round-trips one to eight panes at zero
tolerance", "the captured five-pane fixture round-trips with its dividers",
"plan rejects empty, malformed, overlapping and non-gutter inputs". Property
spec: "plan rejects a layout whose rectangles overlap", "plan rejects a layout
with a hole inside its bounding box".

The plan tree uses `Right` and `Bottom` only, which is what `pane:split`
accepts for the replay path. The `Up` and `Down` spellings belong to the
`SplitPane` key-action form, not to `pane:split`. Layout spec: "the Up/Down and
Top/Bottom direction vocabularies are pinned as data".

### Restore must set the history key per pane

`pane:split` accepts `set_environment_variables`, and restore passes
`WEZTERM_SESSION_HISTORY_KEY` equal to the saved pane id for every pane it
creates. The window spawn and each `spawn_tab` pass it for the tab's root pane;
each split passes it for the pane that split creates, which is the first leaf
of the split's second subtree. The shell hook resolves that variable, then
`WEZTERM_PANE`, then leaves the global history file alone. A pane whose split
omits the key keys its history by the id this build assigned instead of the
saved id, so it loses the history the state promised. Layout spec: "replay
splits in plan order with cwd and the history key". The shell suite cases
`restored-key`, `pane-fallback` and `no-key` cover the hook side.

## The settle window and a silent clean restore

After restore, `layout.selfcheck` compares every live title, rectangle and pane
id against the report built from the plan, and compares a pane's cwd only once
the pane has reported one. Rectangles allow one cell of slack per edge; titles
must match exactly; a missing pane is a finding. Cwd comparison normalizes
slashes, case and a trailing separator. Layout spec: "selfcheck accepts a
one-cell drift and normalizes cwd URLs", "selfcheck reports a rectangle drift
beyond one cell", "selfcheck reports a cwd mismatch", "selfcheck reports a
title mismatch as a tab finding".

Titles, rectangles and missing panes are stable as soon as the panes exist. Cwd
is not. A freshly split pane reports the cwd handed to `pane:split` only after
its shell or the foreground process query catches up. `get_current_working_dir`
returning nil, an empty string, or a Url with an empty file path means "not yet
reported": it is unknown, not a finding, and it never drives the status. The
check retries every 0.1 seconds for up to 100 steps (about ten seconds) and
stops as soon as every pane has reported and matches. At the timeout a reported
value that still differs is genuine drift: it logs `selfcheck.drift` with the
count, up to three finding kinds, the tab and the first pane, sets `timed_out`,
and flashes ` restore drift: N `. Panes that never reported are logged
separately at info level as `selfcheck.cwd_unknown` with their count, and never
touch the status. Layout spec: "a clean check settles immediately and stays
silent", "a cwd that settles after one step stays silent", "an unreported cwd is
unknown, not a finding", "an unreported cwd that arrives late stays silent", "a
cwd that never reports logs cwd_unknown without status or drift", "a reported
cwd mismatch keeps driving drift and status after the settle window".

A clean restore must be silent. The status area is shared with save, and a
check that flashed on every clean start would make a real drift message
indistinguishable from startup noise. A drift flashes ` restore drift: N ` for
four seconds and logs `selfcheck.drift` with the count, up to three finding
kinds, the tab and the first pane. A failure to set the status logs
`selfcheck.status_failed` and never triggers another fallback. Layout spec: "a
drifting restore logs and flashes a short status", "a clean restore stays
quiet", "a self-check error is logged and never falls back".

## Known limitations

Restore produces the saved cell size, not an OS-maximized window. This build
exposes no maximized state to read, so a maximized window and a window created
at the same cell size save the same state, and restore cannot know the OS had
maximized it. A monitor or DPI change can also clip the restored window. The
fresh-window fallback is the one path that maximizes. The plan records this
limit at "Restored rectangles are exact in cells, but a monitor or DPI change
can clip the window".

A live shell that picks up a changed history key mid-session keeps the history
it already loaded. Restore sets the key in the environment of a fresh shell;
PSReadLine reads its save file during the delayed initialization on the first
prompt. In a shell that already loaded history, setting the path changes where
new commands are saved but leaves the loaded items in memory. PSReadLine has no
public reload, so only a freshly started shell honours the new path. The plan
records this limit and `shell\history.ps1` repeats it.

A closed pane leaves an id gap that can later collide with a hand-made pane's
history file. Restored panes keep their saved ids through the history key, so
their history survives, but a pane created by hand can later reuse a gap id and
share a history file with a restored pane whose saved id matches. The plan
records this edge. The suite does not exercise the collision itself.

This build exposes no getter for the status text. The unit tests pin the string
passed to the status setter through a fake window, and the `selfcheck_drift`
scenario asserts the `selfcheck.drift` log line. Where the live build has no
getter, the scenario treats the absence of `selfcheck.status_failed` as
evidence that setting the status did not fail. Drift is therefore asserted
through the log, not through the live status text.

Random layouts are property-tested at the planner level, not through a live
window. Thirty seeded test cases, each covering one to eight panes, round-trip
at zero cells of tolerance in `tests\unit\property_spec.lua`, and the live mux
path is exercised by the captured five-pane fixture. The `fixture_roundtrip`
scenario restores that fixture and checks `rects_exact` and `window_cells`, and
the `full_restore` scenario rebuilds a layout through the real mux. Running
every random seed through the GUI would cost minutes per run and would exercise
the same split arithmetic; the fixture is the regression input for the one-cell
divider.

## How to verify

Run `pwsh -NoProfile -File tests\run.ps1 -All`. It runs the headless unit suite
in `tests\unit`, the shell suite in `tests\shell`, and the real-GUI integration
suite in `tests\scenarios`, and prints one PASS or FAIL line per suite or
scenario. The claims above map to named cases: `tests\unit\state_spec.lua`
"read_latest picks the largest saved_at and breaks ties by instance id" and "a
truncated temporary file leaves the previous state intact";
`tests\unit\layout_spec.lua` "plan round-trips one to eight panes at zero
tolerance", "a clean restore stays quiet", "an unreported cwd is unknown, not a
finding" and "a reported cwd mismatch keeps driving drift and status after the
settle window"; `tests\unit\save_spec.lua` "the debounce writes
after two stable seconds and not while idle"; the shell cases `restored-key`,
`pane-fallback` and `no-key`; and the integration scenarios `full_restore`,
`selfcheck_drift` and `fixture_roundtrip`. The plan behind the layer lives in
`plans\wezterm-session-layer\plan.md`; it is git-ignored, so the tests are the
durable check.
