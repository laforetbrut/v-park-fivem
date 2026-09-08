# Error log

Every non-trivial error hit while building v-park, with what actually caused it.

Newest first. The point of this file is that the next person - including a future me - reads it
before working in the same area, so every entry names the file and states the rule that came
out of it.

---

## [2026-09-09 01:20] — A nil in the parameter list scrambled every insert batch

**Context:** First real server run. Four rows written, the migration importing two more.

**Error:** MariaDB, via oxmysql:

    Incorrect integer value: 'MIG00001' for column `v_park_vehicles`.`class` at row 1

with a parameter list that read `["0TL0SYH04JZU9","MIG00003",12345,"0TL0SYH03Y4JO","MIG00001",
970598228,null,null,null, ...]` - two vehicles' worth of ids, plates and models interleaved,
followed by a hundred and twenty-eight nulls.

**Root cause:** `Persist.flush` built the parameter list with

    for _, value in ipairs(Store.toValues(record)) do values[#values + 1] = value end

and `Store.toValues` legitimately contains nils: most vehicles leave `owner_name`, `job`,
`statebags`, `trailer_id` and `last_garage` empty, and a migrated row also has no `model_name`
because `GetDisplayNameFromVehicleModel` does not exist server-side.

Two separate failures from that one line. `ipairs` stops at the first hole, so only the values
before it were ever read. And `#values` over a table that already has a hole is UNDEFINED, so
each subsequent write landed at an arbitrary index - which is why the plate ended up in the
class column.

**The scale of it:** this would have hit almost every batch on a live server, because almost
every vehicle has at least one nil column. Persistence would have appeared to work - vehicles
adopted, `/vparkscan` listing them - and then quietly lost the lot at the first flush, with one
line of console output.

**Fix:** `upsertBatch` in `server/persist.lua` now writes a literal `NULL` into the statement
where a value is nil, and only ever appends non-nil values to the parameter list. The list is
dense by construction and the length operator is meaningful again. `NULL` is a keyword, not
data; nothing operator-supplied or player-supplied reaches the statement text.

**Prevention:** `tools/check.py` check 11 fails on any `ipairs` or `pairs` over
`Store.toValues`. RULES.md already said "never a nil in an array literal" - this was the same
rule one level down, and it is now enforced by construction rather than by remembering.

---

## [2026-09-09 00:50] — Admin commands were refused from the server console

**Context:** First server run, reading the console.

**Error:** `Access denied for command vparkstats`, and the same for `vparkzones` and
`vparkadmin`. `vparkinfo` worked.

**Root cause:** `RegisterCommand`'s third argument creates an ACE object called
`command.<name>` and refuses the command to any principal that has not been granted it. THE
SERVER CONSOLE IS ALSO A PRINCIPAL, and it does not hold `command.vparkstats` either.

So every command marked `permission = 'admin'` was registered restricted and became unusable
from the console - which is exactly backwards. `server/commands.lua` carries a comment saying
that a server owner debugging a broken framework needs these commands from the console, and the
code did the opposite.

**Fix:** registered unrestricted, gated in the handler by `Bridge.isAdmin`, which returns true
for source 0 and checks ACE first for everybody else. Nothing was loosened: the handler already
refused before reaching the command body, on every call.

The flag's other job - hiding the command from the chat suggestion list - it was not doing
either, because `chat:addSuggestion` is sent to -1 and every client gets the list regardless.

**Prevention:** `restricted` on `RegisterCommand` is for commands the console genuinely should
not run, which is none of ours.

---

## [2026-09-09 01:05] — The migration rollback could never find its own rows

**Context:** The smoke test's migration case. `run force` imported two rows; `rollback` reported
success and removed none.

**Error:** `rolled back 0 migrated vehicle(s)`, with two `source = 'migrated'` rows still in the
table.

**Root cause:** `Migrate.rollback` filtered on `source = 'migrated' AND created_at >=
migrated_at`, and a migrated row's `created_at` is the SOURCE table's creation time - which is
older than the migration that imported it, by definition. The comparison could never be true.

**Fix:** `Migrate.convert` now stores `now` in `updated_at` - the row genuinely was written now
- while `created_at` and `touched_at` keep the source timestamps, which is what the expiry sweep
should measure against. The rollback filters on `updated_at` instead.

**Prevention:** a timestamp copied from somebody else's table is evidence about their data, not
about ours. Anything that needs to know when WE wrote a row needs a column we set.

Found in the same case, and worth knowing: after the broken rollback left rows behind, the next
migration reported them as duplicates and imported nothing. That part was correct - the
duplicate check by plate and position did exactly its job - and it made the fixture dirty in a
way that looked like a second bug.

---

## [2026-09-08 23:40] — An unanswered restore leaked an entity, and enough of them froze streaming

**Context:** Reading `server/spawn.lua` back before the first in-game test.

**Error:** Found by review, not by symptom. `Spawn.create` marks a vehicle both `live` and
`pending`. The timeout sweep cleared `pending` after 20 seconds and left the entity alone.

**Root cause:** A vehicle whose nominated client never answered - the client disconnected,
crashed, or never received the entity - stayed in the world forever, undressed and unplaced,
and stayed counted in `Store.liveCount()`. That on its own is a leak.

What makes it a freeze is the order of the pass. The entity-ceiling check returns EARLY, before
the timeout sweep at the bottom. So once enough leaked entities push `liveCount` to
`Config.Streaming.maximumEntities`, the pass returns at the ceiling every time, the timeout
sweep never runs again, and nothing is ever released. The resource stops spawning anything,
permanently, with nothing in the console to say why.

**Fix:** The timeout sweep moved to the TOP of the pass, before any early return, and a timeout
now calls `Spawn.despawn` rather than only clearing the pending flag.

**Prevention:** An early return in a periodic pass must not sit above the cleanup that the
condition for that early return depends on. Worth checking the other passes for the same shape:
`Persist.sweep` and the three lifecycle sweeps have no early return, which is why they are fine.

---

## [2026-09-08 23:35] — A per-class spawn radius larger than the global one did nothing

**Context:** Same review.

**Error:** `Config.Streaming.classRadius[16] = 400` against a `spawnRadius` of 250 had no
effect at all.

**Root cause:** The grid query asked for `spawnRadius`, and the per-class radius was applied
afterwards as a filter over the result. A filter can only remove, so a larger class radius could
never see a vehicle the query had already excluded. The shipped defaults are all *smaller* than
the global, which is why it worked and why nothing looked wrong.

**Fix:** The query asks for the largest radius in play - the global and every class override -
and the per-class value still narrows afterwards. Cached, because it is read once per player per
pass.

**Prevention:** When a broad query is narrowed by a per-item rule, the query has to be at least
as broad as the loosest rule. Worth stating in the comment, which it now is.

---

## [2026-09-08 23:30] — `SetEntityHeading` after `SetEntityRotation` flattened the pitch

**Context:** Same review, `client/placement.lua` and `server/spawn.lua`.

**Error:** Both calls were there, the second immediately after the first.

**Root cause:** `SetEntityRotation` sets all three axes, which is the point - a car parked on the
Vinewood hills has a real pitch, and storing the full rotation rather than a heading is a
deliberate design decision stated in the config header. `SetEntityHeading` straight afterwards
sets the yaw and, on several builds, zeroes the other two.

The symptom would have been every restored vehicle sitting perfectly level, which on flat ground
is invisible and on a slope is obviously wrong - so it would have been reported as "cars on
hills come back flat" rather than as anything to do with heading.

**Fix:** The heading call removed from both sites, with a comment saying why it must not come
back.

**Prevention:** The full rotation is stored on purpose. Anything that sets orientation after it
undoes that, and there is no reason to set a heading on a vehicle whose rotation has just been
set exactly.

---

## [2026-09-08 22:30] — The admin panel was atmospheric and hard to read

**Context:** First render of the Sandy Shores theme, reviewed against real data in a browser.

**Error:** The theme was right and the panel was not readable. Body text sat at 82% opacity over
a mid-tone board (`#d6c6a4`); secondary lines carrying the plate and the id were at 50%; row
separators were at 16% and invisible; and buttons were 30% white with a 40% hairline border, so
they read as labels rather than as controls.

**Root cause:** Every colour was chosen for atmosphere and none against a contrast target. A
palette assembled that way lands on "looks like the right place" and stops there, because each
individual value looks correct next to the ones beside it.

**Fix:** A contrast pass over `html/css/sandy.css`: the board several steps lighter
(`#e8dcc0`), the ink several steps darker (`#17120a`), buttons to a near-opaque plate with a
visible border, separators to 30%, secondary text to 68%, chips given a tinted fill rather than
only a 1px outline, and the paper grain halved because it was competing with the type. Body
text went from roughly 6:1 to roughly 11:1 against the sheet. Sizes up one step as well: table
12px to 13px, secondary lines 10px to 11px.

**Prevention:** A theme file is judged against a number, not against a feeling. The rule is now
written at the top of `sandy.css`: body text at 7:1 or better against the sheet, and anything
interactive carrying a border you can see without looking for it. Nothing about the hues,
the rust, the hard edges or the grain changed - the constraint is orthogonal to the style.

---

## [2026-09-08 22:10] — Twelve action buttons made every table row 300px tall

**Context:** First render of the admin panel with six vehicles in it.

**Error:** Each row was roughly three hundred pixels high and a page of twenty-five vehicles was
a page of four.

**Root cause:** `.col-actions { width: 1% }` is the standard trick for "as narrow as the
content", and it is exactly wrong when the content wraps: it makes the column as narrow as it
can be and then lets twelve buttons stack vertically inside it. `flex-wrap: wrap` on the
container completed the job.

**Fix:** Three actions inline - go to, bring here, waypoint, which are the three an admin
actually reaches for - and the other nine behind an overflow menu anchored to the row. The
column is now a fixed 200px and `flex-wrap: nowrap`.

**Prevention:** `width: 1%` on a column whose content can wrap is a bug, not a technique. If a
cell's content must not wrap, say `white-space: nowrap` and give the column a real width.

Related, found in the same pass: table cells need `max-width: 0` for `text-overflow: ellipsis`
to have anything to clip against, because a cell's width is indefinite by default however many
percentages are on the column.

---

## [2026-09-08 21:40] — `IsModelValid` called on the server

**Context:** Writing the store loader and the Advanced Parking migration, both of which want to
know whether a model exists on this build.

**Error:** `attempt to call a nil value (global 'IsModelValid')`, on the server, during boot and
during a migration. Same for `GetDisplayNameFromVehicleModel` and `IsModelInCdimage`.

**Root cause:** All three are CLIENT natives. The server has no model index and never has, so
they simply do not exist there. The mistake was reaching for the obvious answer to "is this
model real" without checking which side can answer it.

**Fix:** Both sites are guarded on the native existing, and degrade to "we cannot know" - which
is the honest answer. Nothing is flagged as invalid, the streaming pass declines to create
anything whose model is missing, and it says so once rather than per vehicle. In the migration,
the model name is left nil and filled in by the first client that captures the vehicle.

**Prevention:** Before calling a native on the server, check that it is a server native.
`tools/check.py` does not catch this - a nil call is valid syntax - so it is a review question,
not an automated one. The tell is any native whose answer requires the game world.

---

## [2026-09-08 21:20] — The streaming pass built its candidate list twice

**Context:** Reading `server/spawn.lua` back after writing it.

**Error:** No visible symptom. `wantedSet(players)` was called once for the wanted set and again
for the ordered list, so every pass did a grid query per player, a sort and an allocation twice
per second for an answer it already had.

**Root cause:** The function returns two values and the two uses were written at different
times, several hundred lines apart, each destructuring the one it needed.

**Fix:** One call, both values.

**Prevention:** A function that returns two things and is called twice in one scope is a smell
worth grepping for. Cost me nothing to find because it is in the hot path, which is the only
reason it was noticed at all.

---

## [2026-09-08 20:55] — `Properties.MOD_SLOTS` was built inside `capture`

**Context:** `client/properties.lua`, first draft.

**Error:** A vehicle restored on a client that had never captured one came back completely
stock. Restoring a second vehicle on the same client worked correctly.

**Root cause:** The mod slot table was declared as a local inside `Properties.capture` and
assigned to `Properties.MOD_SLOTS` at the end of it. `Properties.apply` reads the same table, so
on a client where `capture` had not yet run it read nil and every `SetVehicleMod` was skipped.

The symptom reads as a race condition - correct on the second attempt, wrong on the first - and
is not one. It is initialisation order.

**Prevention:** Anything two functions share is declared at module level, not built as a side
effect of whichever one happens to run first. A table that is a constant should look like a
constant.

---

## [2026-09-08 20:30] — `goto` used as a table key, and the whole config failed to parse

**Context:** `Config.Commands`, naming the teleport-to-vehicle command.

**Error:** `config.lua:1303: unexpected symbol near 'goto'`. The entire file failed to load,
which on a config file means every default in the resource is nil and nothing works.

**Root cause:** `goto` is a reserved word in Lua 5.4, and `goto = { ... }` is a parse error
rather than a runtime one. The obvious name for a command that goes to a vehicle is also a
keyword, and reading the line a dozen times does not reveal it.

**Fix:** `['goto'] = { ... }`. Quoting keeps the obvious name, which is the smaller surprise
than renaming it.

**Prevention:** Two things came out of this and both are in `tools/check.py`:

- Check 1 parses every Lua file with a real Lua 5.4 parser via `lupa`. This is the check that
  found it, and it found it in the first run.
- Check 10 generalises it: no bare table key is a Lua reserved word, anywhere in the resource.

Run `python tools/check.py` before every commit.

---

## [2026-09-08 20:35] — The check script reported its own documentation as failures

**Context:** First run of `tools/check.py` after adding the callable-gate and ground-snap
checks.

**Error:** Five failures, all false. `bridge/shared/park.lua` was reported for gating on
`type(x) == 'function'` three times, and `client/placement.lua` for calling
`SetVehicleOnGroundProperly`.

**Root cause:** The checks skipped lines beginning with `--` but not lines inside `--[[ ]]`
blocks. Every one of the reported lines was prose in a block comment explaining why that exact
pattern is wrong. The file documenting why a type test is the wrong gate necessarily contains
the string a dozen times.

**Fix:** `strip_comments()` blanks every Lua comment before scanning, replacing bodies with
spaces so reported line numbers stay honest, and walks string literals so a `--` inside one is
not mistaken for a comment. `bridge/shared/park.lua` is exempted from the callable check by
exact path, because `Park.callable` is the implementation of the correct test.

**Prevention:** A static check that scans source text scans stripped source text. A check that
fires on its own documentation gets ignored, and a check that gets ignored is worse than no
check.

---

## [2026-09-08 19:50] — `Citizen.Await` inside `onResourceStop`

**Context:** The shutdown flush in `server/runtime.lua`.

**Error:** Found by review rather than by symptom, which is the only reason it is not a data
loss bug in production. `Persist.flush` yields between batches and awaits every statement.

**Root cause:** `Citizen.Await` needs the scheduler to run again to deliver its callback, and
during `onResourceStop` there is no guarantee it will - the resource is being torn down. An
awaited write at that moment can hang until the runtime is destroyed, and the write is lost
anyway. The same applies to the `Wait(0)` between batches.

**Fix:** `Database.fire()` sends a statement without awaiting, and `Persist.flushNow()` builds
the same batches with no yield anywhere. The shutdown path uses those. The driver has its own
queue and its own shutdown, and that queue does get drained.

**Prevention:** Nothing in `onResourceStop` yields or awaits. The periodic flush bounds the
exposure to `Config.Save.flushInterval` seconds regardless, but "the resource stops cleanly and
saves everything" is worth having rather than approximating.

---

## [2026-09-08 19:20] — Lua string concatenation in a Python string produced `endend`

**Context:** Building the Lua compile helper inside `tools/check.py`.

**Error:** `LuaSyntaxError: 'end' expected near 'endend'`.

**Root cause:** Adjacent Python string literals concatenate with no separator, so
`"...end" "end"` is `"...endend"`. In Python source the two lines look like two statements; in
the resulting string they are one token.

**Fix:** An explicit `\n` at the end of every line.

**Prevention:** When building code as a string across several Python literals, put the newline
in the literal. It is the same class of mistake as forgetting a space when joining words, and
it is invisible in the source.

---

## [2026-09-08 18:40] — A bash heredoc broke on a long Python patch script

**Context:** Applying a multi-part search-and-replace across several CSS files.

**Error:** `/usr/bin/bash: -c: line 150: unexpected EOF while looking for matching `''`.

**Root cause:** A long quoted heredoc carrying CSS with quotes, parentheses and data URIs in it,
passed through a shell that was also handling the outer command. The exact trigger was not worth
finding.

**Fix:** Write the patch script to a file with the Write tool, then run it. No shell quoting is
involved and the script is inspectable if it goes wrong.

**Prevention:** Heredocs are for short scripts. Anything with quoting in it goes in a file.

---

## Conventions for adding an entry

```markdown
## [YYYY-MM-DD HH:MM] — short title
**Context:** what was attempted
**Error:** exact message or symptom
**Root cause:** why
**Fix:** what resolved it
**Prevention:** the rule that stops it happening again
```

An entry earns its place when the root cause was not obvious from the error. A typo does not
need one; a nil call whose symptom reads as a race condition does.
