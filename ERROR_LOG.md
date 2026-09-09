# Error log

Every non-trivial error hit while building v-park, with what actually caused it.

Newest first. The point of this file is that the next person - including a future me - reads it
before working in the same area, so every entry names the file and states the rule that came
out of it.

---

## [2026-09-09 03:55] - A security check refused a legitimate purchase

**Context:** the user reported that buying a vehicle from a dealership did not make it persistent,
one release after 1.0.19 added proximity proofs to the adoption path.

**Error:** `Persist.adopt` refused the offer when the offering player's ped was more than fifteen
metres from the entity being offered. A purchased vehicle is created at the shop's `VehicleSpawn`
while the buyer is still standing at the display car, and `TaskWarpPedIntoVehicle` moves them
client-side with the server learning the new position by sync afterwards. Measured from
qb-vehicleshop's shipped config: display-to-spawn is 11.7-22.1 m at PDM and 22.1-40.7 m at the
Luxury shop, so every display position at one shop and most at the other exceed the threshold. The
offer was refused whenever the ped's position had not synced yet, which is a race.

**Root cause:** the same mistake as the bug 1.0.19 was written to fix, in the opposite direction.
1.0.19 correctly identified that a check comparing two client-supplied values proves nothing - and
then replaced it with a check that depends on a SERVER-side value the server does not reliably have
yet. This project has now been bitten three times by reading a position the server has not been
told about: 1.0.15 (the despawn read), 1.0.18 (the nearest-client search using a stale stored
position), and this.

**Fix:** the ped is out of the check. What remains is the payload position compared against the
entity's server-side position, which is the proof that actually matters - the payload position is
the value that becomes a row - and which does not depend on any sync arriving in time. The ped
check bought almost nothing anyway: adopting a vehicle does not make it the offerer's, because
`Ownership.resolve` reads the owner from the framework row.

**Prevention:** before a check uses a position, ask which machine owns that entity and whether the
server has been told. A ped's position after a client-side teleport, and a vehicle's position after
its owner has walked away, are both values the server holds a stale copy of. Second: every refusal
in the adoption path was a silent `return`, so this took a measurement of a third-party config to
diagnose rather than one command. They are all recorded now and `/vparkwhy` prints them.

---

## [2026-09-09 03:10] - The client's own rule was never enforced on the server

**Context:** auditing all sixteen server-side net events after 1.0.17 found two of them accepting a
vehicle id on trust. The point of the audit was that 1.0.17's hole was found by luck rather than by
looking.

**Error:** three more of the same kind. `Persist.applySnapshot` accepted a position for any vehicle
a client had been asked to snapshot, and the server asks each client about every vehicle near it and
supplies the ids - so a modified client could relocate a stranger's parked car anywhere, without
needing to know an id at all. `Persist.adopt` took a position from the client and never compared it
to the entity, so a vehicle could be registered as persisted at arbitrary coordinates.
`vpark:server:restored` cleared the `pending` flag before checking the answer came from the
nominated client, which is both a denial of service and, via a re-nomination race, an ordinary bug.

**Root cause:** for the snapshot, a rule that existed and was documented in the right place - the
client omits a position until somebody has driven the vehicle, and says exactly why - but lived only
on the side that cannot enforce it. A rule enforced by the sender is not a rule. For adopt, the same
mistake as the original 1.0.17 hole: a check that compares two values the client supplied, which
proves they are consistent and nothing else.

**Fix:** the snapshot position is accepted only when the SERVER believes the vehicle has been
driven. The adopted position is compared against the entity's own server-side position. `pending` is
cleared after the placer check, matching `restoreFailed`, which had always been right.

**Prevention:** when a client-side comment explains why the client does not send something, that is
a rule and it belongs on the server too - the comment is evidence that somebody has already reasoned
about it and stopped one step short. And when auditing a message handler, write down which values
came from the client before deciding what has been proven: if every input to a check is one of them,
the check is a consistency test, not an authorisation.

---

## [2026-09-09 02:40] - A capture asked the one client that could not answer

**Context:** looking for what was left after the position guarantee finally held, specifically what
happens when a player disconnects while driving.

**Error:** two faults in the capture sweep. A vehicle being driven was captured on one sweep slice
in four, so up to 30 seconds of driving existed nowhere but on the client. And the sweep asked the
client nearest the vehicle's STORED position - which for a car being driven is where the drive
started - so a vehicle driven beyond the streaming radius was asked of somebody who could not see
it. They answered nothing about it and that is not an error, so nothing was logged. Separately,
`Persist.onPlayerDropped` marked dirty by `placer` rather than by occupant, so a player who
disconnected in somebody else's restored vehicle flushed nothing.

**Root cause:** an optimisation applied to a set it did not describe. Slicing exists because a
parked car is provably identical to its last capture, and it was applied to the whole live set
including the one member of that set the argument does not cover. The nearest-client search has the
same shape: `pos_x` is where the vehicle is for every vehicle in the set except the ones that are
moving, which are exactly the ones being asked about.

**Fix:** a driven vehicle is in every slice, and it is asked of its occupant, which is exact rather
than an estimate. `onPlayerDropped` marks both placer and occupant. The spawn position is recorded
so a stale server-side read is detectable rather than guessed at from flags.

**Prevention:** when a rule is justified by a property of the data - a parked car does not change -
check whether the set the rule is applied to actually has that property throughout. The exception
here was one vehicle per player, which is small enough to be invisible in testing and is the only
one anybody would notice.

---

## [2026-09-09 01:55] - A net event took a vehicle id on trust

**Context:** reading the parked and touched handlers with fresh eyes after the position work was
finally correct, looking for what could still go wrong.

**Error:** `vpark:server:parked` accepted a position for any vehicle id from any client. Its one
proximity test compared the reporting player's ped to the position CARRIED IN THE MESSAGE, and the
sender chooses that value - so sending your own coordinates passed from anywhere on the map. Ids
are not secret: `vpark:id` is a replicated statebag every client in scope reads and keeps. Any
persistent vehicle whose id had ever been seen could be relocated permanently to the sender's
feet. `vpark:server:touched` required no proof at all and wrote a database row per call.

**Root cause:** a validation written against the wrong adversary. The check was there to catch a
report that contradicted itself - a client claiming a position nowhere near itself - and it does
that. It was then read as though it established proximity to the VEHICLE, which it never did,
because every value in it either comes from the sender or is compared against a value from the
sender. A check whose inputs are all attacker-controlled proves nothing no matter how it reads.

**Fix:** both handlers now measure the distance between the player's ped and the vehicle entity,
both read on the server, neither supplied by the message. When the entity cannot be read the row's
stored position is the reference with a wider radius, because refusing outright would risk
discarding a legitimate drive. `parked` additionally accepts the player the server watched get in,
once, when there is nothing left to measure at all.

**Prevention:** for a net event, list which values come from the client before deciding what has
been proven. If every input to a check is attacker-controlled, or is only ever compared against
another attacker-controlled input, the check is a consistency test and not an authorisation. The
smoke test now asserts the property from outside: a report that cannot be proven leaves the row
exactly where it was.

---

## [2026-09-09 18:05] — A per-client table used to answer a server-wide question

**Context:** Reported after 1.0.15: "almost, there is still one vehicle that went back to an old
place - as soon as I get out of the vehicle it should be saved".

**Error:** None.

**Root cause:** the parked report added in 1.0.14 was guarded by `Stream.byEntity`, which
answers from the client's `tracked` table. `tracked` is populated by the `vpark:client:restore`
handler, and that instruction is sent by `sendRestore` to ONE client - the one the server
nominated to dress and place the vehicle.

Every other client has nothing in `tracked` for that vehicle. So a player getting into a vehicle
that was restored for somebody else - most vehicles on a server with more than one player, and
any vehicle at all after the nominated client has driven away - failed the check silently, and
getting out sent nothing.

The behaviour was therefore "saves correctly if you happen to be the client that placed it",
which on a single-player test is most of the time and in general is not.

**Fix:** ask the vehicle instead. `vpark:id` is a replicated statebag: every client in scope has
it, and a player who has been sitting in the vehicle has had it for a long time. `tracked` is
still consulted first because on the nominated client it is a table lookup and already correct.

**Prevention:**

> **A per-client cache cannot answer a question about the world.**
>
> `tracked` is this client's view of what it was asked to restore. It was reached for as though
> it meant "vehicles v-park keeps", and those two are the same set only on one machine. The name
> did not help, and neither did testing alone - with one player, that machine is always the
> nominated one.
>
> The replicated statebag exists precisely because it is the copy every client has. When a check
> needs to be true on all of them, that is the thing to read.

---

## [2026-09-09 16:20] — The correct position, then the old one on top of it

**Context:** Reported immediately after 1.0.14: "I get out of the vehicle, I leave, I come back
and it is at an old place where it was before".

**Error:** None.

**Root cause:** 1.0.14 added `vpark:server:parked` - the client sends the pose the instant the
driver gets out - and, in the handler, set `entry.driven = true` to record that the vehicle had
been used.

`driven` is the flag that permits the despawn to read the entity's position back one last time.
So the sequence was:

    park, get out          -> correct position written by the client's report
    walk away              -> vehicle leaves the streaming radius
    despawn                -> reads the entity's SERVER-SIDE coordinates over the top

A server-side entity's position is maintained by its NETWORK OWNER. Once the driver has walked
away and ownership has lapsed, the value the server holds is stale - and it is stale at the
position the server created the entity with, which is the position from before the drive.

The release that made the parked position correct is the release that overwrote it, with the one
line it added to record success.

**Fix:** `entry.parked` marks the report as final and the despawn skips its read for such a
vehicle; getting in again clears it. And the client clears its own `driven` after sending the
report, so the capture sweep stops reporting a position that physics is still free to change.

**Prevention:**

> **When you add a better source of a fact, check what the worse sources are still allowed to
> do with it.**
>
> The parked report was strictly better information than the despawn read: newer, from the
> machine that actually knew, taken at the moment the value settled. It was added alongside the
> old path rather than in front of it, and the old path ran last.
>
> The specific trap was that the new handler set a flag meaning "this vehicle has been used",
> which happened to be the same flag that means "it is worth re-reading its position on the way
> out". One word doing two jobs, and the second job undid the first.

---

## [2026-09-09 14:40] — Nothing was written when the vehicle was actually parked

**Context:** Reported after 1.0.13, and diagnosed by the user: "sometimes the position is saved
in the wrong place - if I get out of the vehicle and leave quickly it is not saved at all".

**Error:** None.

**Root cause:** `onExit` in `client/track.lua` did nothing for a vehicle v-park already tracks.
`worthReporting` returns false for one, correctly - that check decides whether to ADOPT
something new - so the function returned before doing anything.

So the position of a vehicle that had just been parked was left to be discovered by:

- the periodic capture sweep, which is sliced into quarters and may be seconds away; or
- the final pose read on despawn, which calls `GetEntityCoords` on the SERVER.

Both fail together in the ordinary case. Park, get out, leave: the sweep has not come round, and
by the time the vehicle drops out of the streaming radius no client has it in scope, so the
server-side read returns nothing. The stored position stays whatever it was before the drive,
and the vehicle comes back where it used to live.

The irony is that 1.0.13 had just made the save path correct in principle - only a driven
vehicle reports its position - and this is the case where the driven vehicle never got to
report at all.

**Fix:** `vpark:server:parked`, sent by the client the instant the driver gets out, carrying the
pose. Accepted for a live vehicle from a player within fifty metres. The sweep and the despawn
read stay as the second and third routes.

**Prevention:**

> **Find the moment the answer stops changing, and write it down then.**
>
> Everything else in this file's history is a way of discovering a fact after it happened -
> sweeps, timeouts, reads on the way out. All of them are races against the player leaving.
> Getting out of a vehicle is the single instant at which "where is this parked" becomes true
> and stays true, and it was the one moment nothing was listening to.
>
> The tell was in the code: a function called `onExit` whose entire body was about adopting new
> vehicles, with an early return that skipped every vehicle we already cared about.

---

## [2026-09-09 12:15] — The car was where the database said; the database was wrong

**Context:** Tested on 1.0.12. `/vparkwhere` reported 6 mm and 0 mm - the placement finally
exact - and a vehicle had still moved about five metres from where it was parked. Plus
`/admincar` not making a vehicle persistent, with `/vpark` the only thing that worked.

**Error:** None.

**Root cause, the five metres:** with the placement reading six millimetres out, the vehicle was
where the record said. The record was wrong.

Every vehicle near a player is woken, because that is what makes it drivable before somebody
reaches it, and a woken vehicle is simulated. On a camber, or nudged by a vehicle streaming in
alongside, it rolls. The capture sweep read that and wrote it down as the stored position.

Twelve releases of work went into making the restore put a vehicle exactly where the record
says, and the record was being updated by physics. 1.0.11's five-centimetre threshold made each
step smaller without stopping the walk.

**Root cause, `/admincar`:** the on-entry offer is made in `onEnter`, once, when the door closes.
`/admincar` is run from the driver's seat: the row appears in `player_vehicles` while the player
is already sitting there, and nothing asked again. The vehicle only became persistent when they
got out and the forty-five second settle timer expired, which reads as "the command did
nothing".

**Fix:** Position and rotation are omitted from a capture until somebody has sat in the vehicle,
and the despawn's final pose read follows the same rule - `driven`, not merely `seen`. And the
entry offer repeats while somebody is seated in a vehicle that is not persisted, every fifteen
seconds.

**Prevention:**

> **A value that is read back and written down is a feedback loop, and it needs a gate that
> physics cannot open.**
>
> The restore path was made exact five separate times. None of that could hold while the save
> path accepted any position the entity happened to have, because the two are a loop: restore
> reads the record, physics moves the entity, capture writes the entity back into the record.
> The gate had to be "a person did this", and nothing smaller would have worked.
>
> And: **an event handler is not a state check.** `onEnter` answers "did somebody get in", which
> is not the same question as "is this vehicle theirs" - and the second one can change its answer
> while the first is not firing.

---

## [2026-09-09 09:30] — Two questions that could not be answered, both answered anyway

**Context:** Tested on 1.0.11. The same three vehicles, the same two deltas, to the millimetre:

    0TL1YS402S8YV  off by 1.250 m   dx +0.000  dy -1.250  dz +0.000
    0TL1YSE03933L  off by 1.250 m   dx +1.250  dy +0.000  dz +0.000

and `/car` still making vehicles persistent after `keysGrantOwnership` had been turned off.

**Error:** None. Both features working as designed.

**Root cause, the position:** 1.0.11 excluded vehicles carrying `vpark:id` from the blocking
test, which was the right diagnosis. It did not work because the check reads a REPLICATED
statebag, and a replicated statebag arrives asynchronously. Several vehicles restored at once
are placed before their neighbours' bags have landed on that client, so the filter finds nil and
the neighbour counts as an obstacle. The fix depended on winning a network race.

Stepping back one level: what can occupy a bay a vehicle was parked in? Ambient traffic, which
`clearAmbient` has already deleted by the time the probe runs. Another of our vehicles, which
coexisted with this one by construction. Or a car somebody is driving, which will leave. Moving
our vehicle is wrong in all three. The search was answering a question that has no case in which
its answer is wanted.

**Root cause, `/car`:** `Ownership.isJobVehicle` fell back to "there is no owner row and the
driver holds a job". The comment directly above it listed what that catches - "a job spawner, a
dealership demo or an admin command" - and it treated all three as job vehicles. On a server
where staff hold a job, every `/car` became a permanent row.

**Fix:** `Config.Placement.search.enabled = false`; a vehicle whose bay is occupied is placed
exactly where it was and left frozen. `isJobVehicle` returns false without a
`jobPlatePattern`, because nothing else can distinguish a cruiser from a conjured Premier.

**Prevention:**

> **When a fix has to win a race to be correct, go up a level instead of tightening it.**
>
> 1.0.11's filter was the right idea and could never have been reliable, because the information
> it needed arrives when the network feels like it. The question to ask at that point is not
> "how do I get the statebag sooner" but "why am I asking at all" - and the answer was that the
> whole feature had no case in which it helped.
>
> The other one is the same shape: a heuristic whose own comment lists a counter-example is not
> a heuristic, it is a guess with documentation.

---

## [2026-09-09 05:10] — Widening ownership on a premise I never checked

**Context:** Reported alongside the position measurements: "when I do /car premier it makes it
persistent, that is not normal - it should be when I do /admincar in the car".

**Error:** None. Working exactly as configured.

**Root cause:** `Config.Ownership.keysGrantOwnership`, added in 1.0.2 and on by default.

It was added to fix a real report - a car the player had given themselves with `/admincar` was
not being kept - and the reasoning written into the config comment was:

    `/admincar`, a dealership demo, a job spawner [...] none of those write a row in
    `player_vehicles`

I never checked that. `/admincar` on qb-core is `qb-adminmenu`'s SaveCar, and its server half is:

    MySQL.insert('INSERT INTO player_vehicles (license, citizenid, vehicle, hash, mods, plate,
                  state) VALUES (?, ?, ?, ?, ?, ?, ?)')

It writes the row. The vehicle was owned by the framework's own definition and
`matchOwnedByPlate` was always going to keep it. The original report had some other cause, and
the fix for it was a widening of what "owned" means that was never needed.

What the widening did keep was everything else. `/car` spawns a vehicle and hands over the keys
without registering it to anybody, and so does every dealership test drive, job spawner and
admin spawn menu on most servers. All of them became permanent rows.

**Fix:** `keysGrantOwnership = false`. The framework's register is the authority on ownership,
which is what it is for. The option stays for a server whose key resource genuinely is the only
record of who owns what.

**Prevention:**

> **A config comment that states a fact about another resource is a claim, and claims get
> checked.**
>
> The comment asserting that `/admincar` writes no row was the entire justification for the
> setting, it was three lines long, it was confident, and reading the command would have taken
> a minute. Instead it shipped as a default and turned every spawned car on the server into a
> permanent row for nine releases.
>
> The tell: the fix widened a definition to solve a specific report, without first confirming
> the report was not explained by the definition that already existed.

---

## [2026-09-09 03:20] — Our own parked cars were treated as obstacles

**Context:** The first report in this file to arrive as measurements rather than as a
description. `/vparkwhere` on three cars parked together:

    0TL1XPC029AV2  PREMIER  off by 1.250 m   dx -1.250  dy +0.000  dz +0.000
    0TL1XPN03STI2  PREMIER  off by 0.017 m   dx -0.005  dy +0.016  dz -0.001
    0TL1XP201FY36  PREMIER  off by 0.003 m   dx +0.003  dy +0.001  dz -0.001

**Error:** None. Two separate faults, and the numbers separate them.

**Root cause, the 1.25 m:** exactly `Config.Placement.search.step`, on one axis, with nothing on
the other two. That is not drift, it is the search having moved the vehicle one ring outwards
because the probe reported the bay blocked - and then `result.moved` sending the new position
back to be saved.

The blocker was another of our own vehicles. 1.0.8 removed map geometry from this test because
the map cannot have changed since the vehicle was parked; the same argument applies to our own
fleet and had not been made. A persisted vehicle at its saved pose was standing there when every
other persisted vehicle nearby was saved, so they coexisted by construction. And the box tested
is the model's bounding box, which includes the mirrors and the exporter's margin, so two cars
parked thirty centimetres apart overlap in it - meaning neighbours were blocking each other
routinely rather than rarely.

**Root cause, the millimetres:** both cars had been restored correctly and then woken, which
every vehicle near a player is. A woken vehicle is simulated, and simulation settles it by
millimetres. Every one of those settlements was captured and written back as the new stored
position, so the next restore placed the car at the settled position and it settled again.

**Fix:** A vehicle carrying a `vpark:id` is not a blocker, checked where the overlap is found
rather than while reading the vehicle pool - a handful of statebag reads per placement instead
of one per vehicle on the street. And a capture whose position differs by less than five
centimetres, or whose rotation by less than half a degree, leaves the stored values alone.

**Prevention:**

> **Ask for the number before proposing the mechanism.**
>
> Five releases went into "not quite in the right place" and produced five plausible mechanisms,
> each fixed, each leaving the symptom. The first measurement identified two real faults in
> minutes, because `1.250` is not a plausible amount of drift - it is a constant from the
> config, and a constant names its own source.
>
> The diagnostic should have been the first release, not the sixth.

---

## [2026-09-09 01:40] — Setting the position of an entity we had just frozen

**Context:** Reported after 1.0.9: the colours were finally correct, and "no vehicle reappears in
the right place". Not some - none.

**Error:** None. Silent, and total.

**Root cause:** `FREEZE_ENTITY_POSITION` fixes an entity's matrix. A position written to a frozen
entity is not reliably applied, because the freeze is holding the very thing the write is trying
to change.

`client/placement.lua` froze the entity at the top of `placeInner` and then wrote coordinates to
it four times over the next hundred lines. It had always done that.

What changed is that it used to get away with it. Before 1.0.7 a restored vehicle arrived
unfrozen and fell, the placement's own `FreezeEntityPosition` was the first freeze that entity
had seen, and the writes after it landed well enough. 1.0.7 fixed the falling by freezing the
vehicle on arrival through a replicated statebag - correctly - and in doing so removed the
accident that had been making the placement appear to work.

The result was that every vehicle stayed wherever `CreateVehicleServerSetter` had created it,
which is close enough to the saved position to look like a small drift rather than a total
failure. That is why five releases of reasoning about drift found five plausible mechanisms and
fixed none of them: the mechanism was that the writes were not being applied at all.

**Fix:** One `setPose` helper - unfreeze, write, zero linear and angular velocity, freeze again,
with no yield in the window - and every one of the four call sites goes through it. Plus
`/vparkwhere`, which reports the delta per vehicle per axis.

**Prevention:**

> **When a fix makes an unrelated symptom worse, the fix is usually correct and has removed an
> accident that something else was relying on.**
>
> The freeze-on-arrival in 1.0.7 was right, and it broke placement everywhere. Reading that as
> "1.0.7 introduced a positioning bug" would have led to reverting the correct change. Reading
> it as "something was depending on entities being unfrozen" led to the actual fault, which had
> been in the file since the first release.
>
> And the smaller rule: **`FreezeEntityPosition` is not a flag you set once and forget.** It is
> a lock on the entity's matrix, and every write to that matrix has to take it off first.

---

## [2026-09-08 23:15] — Two natives for one paint, and the wrong one ran last

**Context:** Reported after 1.0.8: "they still change colour on their own, that must not
happen", and "they are still not quite in their place".

**Error:** None. Both silent.

**Root cause, the colour:** `SET_VEHICLE_MOD_COLOR_1` and `SET_VEHICLE_COLOURS` write the same
paint through two different APIs. `applyColours` called them in that order - colours first, mod
colours second - so the mod colours were the last word.

And they were being given arguments from three different places:

    SetVehicleModColor_1(vehicle, properties.paintType1, properties.color1, 0)

`GET_VEHICLE_MOD_COLOR_1` returns three values: the paint type, the colour WITHIN that paint
type, and the pearlescent colour. The capture stored only the first. So the second argument came
from `GetVehicleColours`, which is a different colour space, and the third was a literal zero -
resetting the pearlescent colour on every restore, immediately after `SetVehicleExtraColours`
had set it correctly two lines earlier.

The capture sweep then read the resulting colour off the vehicle and wrote it to the database.
Every restore was a fresh corruption and every save made it permanent, which is exactly what
"they change colour on their own" describes and why it never converged.

**Root cause, the position:** a vehicle moves a few centimetres between its coordinates being
set and the freeze taking hold - collision streaming in underneath it, a vehicle materialising
alongside, the suspension settling. 1.0.7 added a check for this that ran once, BEFORE the
freeze, and only acted past half a metre. Half a metre is enormous for something whose whole
promise is exactness, and before the freeze is before most of the movement.

**Fix:** The full `modColor1` and `modColor2` tuples are captured and applied, before the index
colours, with `SetVehicleExtraColours` last so the pearlescent colour is authoritative. The pose
is re-asserted after the freeze, twice, past two centimetres.

**Prevention:**

> **When two natives write the same state, the code has to say which one is authoritative, out
> loud, in the order it calls them.**
>
> `applyColours` called both, in an order nobody had chosen deliberately, with the losing one
> given careful arguments and the winning one given approximations. It read as thorough - two
> APIs covered rather than one - and thoroughness was the bug.
>
> The tell was there to be found: the function set the pearlescent colour and then overwrote it
> with zero, four lines apart, in a file whose header is about getting the apply order right.

---

## [2026-09-08 21:30] — Probing something that could not have changed

**Context:** Reported after 1.0.7: "vehicles are still not in their place, or they float in the
air, and yet they have space".

**Error:** None. Two configuration defaults, each defensible on its own.

**Root cause:** `Config.Placement.probe.blockedBy.world` was `true`, so the placement traced six
rays through the map to decide whether the saved pose was free.

**That question has a known answer.** The vehicle was parked at that exact pose, so the map
allowed it, and the map has not changed. The probe could only ever return a false positive - and
it did so constantly, because it runs at roughly forty centimetres above the road and a kerb, a
camber, a speed bump or a garage threshold is taller than that.

On its own that would have been a minor annoyance. `Config.Placement.search.verticalRetry` was
`3.5`, and the search's candidate list is ordered by preference, with the vertical retries
FIRST. So a kerb-side car reported blocked, and the first alternative offered was the same spot
three and a half metres in the air - where nothing is ever in the way, so the probe called it
clear. The vehicle was placed there, `freezeUntilTouched` froze it, and `result.moved` sent the
airborne position back to the server to be written to the database.

Nothing anywhere in the path would bring it down again: `groundCorrect` only ever pushed a
buried vehicle UP.

**Fix:** The world and object probes are off by default. The vertical retry is off - the
multi-storey case it was written for stopped existing in 1.0.7, when restored vehicles began
being frozen on arrival and could no longer be saved mid-fall. `groundCorrect` corrects
downwards as well as upwards, using each model's own origin-to-ground distance, and runs again
over whatever the search finally chose. `tools/check.py` fails the build if either default
drifts back.

**Prevention:**

> **Before writing a check, ask what could make its answer change since the last time it was
> true.**
>
> The world probe was the most carefully engineered part of this resource - six rays rather than
> a box test, a shrink factor tuned against the tightest legitimate spaces in the base map, a
> ray height chosen to clear the roofline in underground car parks. All of that work went into
> answering a question that was already answered by the fact that the vehicle had been parked
> there.
>
> And: **an ordered fallback list is a ranking of preferences, so the first entry had better be
> the safest one.** "Three and a half metres up" was first because it was cheapest to test, not
> because it was the outcome anybody would want.

---

## [2026-09-08 19:10] — Writing to an entity before it was ours to write to

**Context:** Reported after 1.0.6. The multiplication was gone and the vehicles were staying,
but: "they appeared under the map a few metres from where I had parked them", and "they have
also changed colour, that is not normal".

**Error:** None. Both are silent.

**Root cause:** Two faults, and the same sentence describes both: something was done to the
entity before this machine had the right to do it.

**Under the map.** A server-created entity is simulated by a client from the moment it arrives,
and the collision around it has not necessarily streamed in. So it falls. The placement pass
freezes it - but that runs after `waitForEntity`, after the model check and after the
properties, which is seconds later. The vehicle is already below the floor, and the placement
then carefully positions something that is somewhere else. The few metres of horizontal offset
are the same fall: it slid before it was caught.

**The colours.** `SetVehicleColours` and every other property native, applied to an entity the
client does not own, are applied LOCALLY and then overwritten by the owner's next
synchronisation. Network control was requested inside `Placement.place`, which runs AFTER
`Properties.apply`. A freshly created server entity has no owner, so the request usually takes
a moment - and every property written in that moment went nowhere. Then the capture sweep read
a stock car and wrote it over the stored one.

**Fix:** A `vpark:hold` statebag set in the same replicated write as the vehicle's id, and a
client handler that freezes the entity the instant it lands - on every client, because any of
them may be the one simulating the fall. Control is taken before the first property is written,
and a restore that cannot get control is not attempted at all: the vehicle stays where it is,
held, and the server asks again.

**Prevention:**

> **On the client, "do I own this entity?" is a precondition, not an error case.**
>
> Every native that writes to an entity you do not own is a no-op that returns nothing and logs
> nothing. There is no failure to catch and no line in any console; the only symptom is that
> the world does not match what the code plainly says it should. Two of the four things this
> resource exists to do were broken by it for seven releases.
>
> And: **the gap between an entity existing and being under our control is a gap in which
> physics happens.** Closing it needs something that acts on arrival rather than something that
> acts when our code gets round to it - which for a networked entity means a replicated bag,
> not a sequence of instructions.

---

## [2026-09-08 17:20] — Treating "I could not improve this" as "this is broken"

**Context:** After the orphan fix, a pass over the whole restore path against what a persistence
resource is actually for: the vehicle is where it was, it looks how it did, it does not
multiply, and noticing all of that is cheap.

**Error:** No error, in any log. This is a design fault rather than a bug, which is why five
releases went past it.

**Root cause:** The server creates a vehicle at its saved coordinates and heading - both are
arguments to the creation native - so a vehicle nothing touches afterwards is already exactly
where it was left. Everything the client does next only REFINES that placement.

`vpark:server:restored` treated every non-ok answer as a failed restore and despawned the
vehicle. Three of the client's answers are not failures at all:

- `no_control` - another client owns the entity, or the control request took longer than three
  seconds on a busy server.
- `blocked` - the exact bay is occupied and the search could not find room nearby.
- `raised` - something inside the placement threw, on a vehicle that is at the right
  coordinates and merely not refined.

All three deleted a correctly placed vehicle, and the streaming pass created it again on the
next tick. That is a create-delete loop per vehicle per second: visible as flicker, felt as
lag, and it fed every other symptom in this file, because each cycle was another chance for the
creation path to leak or the entity to be caught half-made.

Two related faults found in the same pass:

- A vehicle whose properties failed to apply was still captured, so the stock state was written
  back over the stored modifications. One failed apply lost them permanently.
- The final pose was re-read on every despawn, including for frozen vehicles that provably had
  not moved. Placement settling and collision streaming each nudge an entity by centimetres, and
  every one of those was written down - so a parked car drifted a little on every pass a player
  made.

**Fix:** Only `gone` despawns. `no_control` is reported as success with the placement marked
unrefined. An undressed vehicle reports no snapshot at all. A frozen vehicle's pose is not
re-read, and the server learns about wakes from the client so a driven vehicle still is.

**Prevention:**

> **Ask what the default outcome is when every optional step fails.**
>
> If the answer is "the vehicle is where it should be", every one of those steps can fail
> harmlessly and the resource degrades into doing its job. If the answer is "the vehicle is
> deleted", then every optional step is load-bearing and the resource is as reliable as its
> flakiest one - which here was a network control request on a busy server.
>
> The refinement was written as a step that had to succeed because it was written first, before
> the server was creating vehicles at the right coordinates itself. Nothing re-derived it once
> that changed.

---

## [2026-09-08 16:00] — The right native, and the wrong reflex kept with it

**Context:** Immediately after 1.0.4 shipped. Reported as "the vehicles appear then disappear,
and in the wrong place". The log:

    [v-park] WARN: 0TL1SZG01HDUH did not become a usable entity in time - removing it
    [v-park] WARN: could not spawn 0TL1SZG01HDUH (model PREMIER): the entity never became usable

**Error:** No error. The resource was doing exactly what it had been told to.

**Root cause:** 1.0.4 correctly replaced `CreateVehicle` with
`CREATE_VEHICLE_SERVER_SETTER`, and incorrectly kept the wait that the old native needed.

The CFX documentation:

> Server setter natives immediately and guaranteed register an entity with the server, but the
> entity is initially orphaned - it will not be simulated nor exist in the game world until a
> suitable client is within scope.

`DoesEntityExist` on a setter entity is therefore false BY DESIGN for as long as no client has
it in scope. Waiting three seconds for it and deleting the vehicle when it did not arrive meant
deleting the vehicle at roughly the moment a client had streamed it in - which is why they
appeared and then vanished rather than never appearing. And they were in the wrong place while
they were there, because the restore instruction that dresses and places them is sent after
that check.

Two things made it worse than a flicker:

- The configuration ran under one `pcall`, so a pose native refused by an orphaned entity took
  the identity statebag with it.
- The external-delete detector reads the same `DoesEntityExist` as "something else removed
  this", and past its five-second grace period it would have DELETED THE ROW for a vehicle that
  had simply not reached a client yet.

**Fix:** The setter path is not waited on. The waiting happens on the client, which already
waits twelve seconds for the entity in `vpark:client:restore` and is the machine the entity is
actually waiting for. Configuration is split so only the statebag half can fail the creation.
An entry must have been SEEN to exist before it can be considered externally deleted.

**Prevention:**

> **When you replace a native, re-derive everything that was built around the old one.**
>
> The wait was correct, well-reasoned, documented in a thirty-line comment, and verified against
> another implementation - for `CreateVehicle`. None of that survived the change of native, and
> none of it was re-checked, because the comment above it read as settled.
>
> The specific trap: `DoesEntityExist` answers "is this in the game world", and both natives
> make it false at first for completely different reasons. One is a race that resolves in a
> frame; the other is a documented state that resolves only when a player arrives. The same
> false meant "wait a moment" in one case and "this is normal, carry on" in the other.

---

## [2026-09-08 12:40] — Server-side `CreateVehicle` is an RPC, and that was the whole bug

**Context:** Three releases of chasing vehicle multiplication. Each one fixed something real
and none of them found the cause. The log that finally gave it away:

    script error in native 000000009e35dab6: Tried to access invalid entity: 135949
    script error in native 00000000635e5289: Tried to access invalid entity: 135949
    WARN: 0TL1R3201WDS5 was created but could not be configured - removing it
    script error in native 00000000faa3d236: Tried to access invalid entity: 135949

with the same vehicle id every time and a different entity handle every time.

**Error:** `Tried to access invalid entity`, on an entity created microseconds earlier.

**Root cause:** Server-side `CreateVehicle` is an **RPC**. It returns a handle synchronously and
the entity is not created until a client has been asked to make it and has answered. Until then
the handle refers to nothing.

Every previous release misread that window:

- **1.0.1** saw `DoesEntityExist` answer false in it and concluded the check was worthless. The
  right conclusion was that the entity was telling us it was not ready yet.
- **1.0.2** wrapped the configuration in a pcall and treated the failure as the vehicle's
  fault: warn, delete, back off, retry. The vehicle never spawned.
- **1.0.3** changed nothing here.

The fourth line above is the important one. `DeleteEntity` failed for the same reason the
configuration did, so **every attempt left an entity in the world** - undressed, with a random
plate, and carrying no `vpark:id` statebag because setting it was the step that failed. The
reconciliation sweep looked only at that statebag, so it was blind to exactly the entities the
bug produced. They accumulated on the vehicle's saved coordinates, and a player teleporting to
their car arrived in a stack of unmarked copies of it.

That is the whole reported symptom in one chain: wrong colours, wrong plate, no keys, and
vehicles spawning without end.

**Fix:** `CREATE_VEHICLE_SERVER_SETTER`, which the CFX documentation describes as immediately
and guaranteed registering the entity. No window, nothing to race. The RPC path stays as a
fallback for a build without it, and now waits for the entity rather than assuming it. Plus:
every handle recorded before anything else touches it, a condemned list that retries a delete
until `GetAllVehicles` says the entity is gone, and a refusal to adopt an entity we created.

**Prevention:**

> **When a native fails immediately after another native created the thing it operates on, ask
> whether the creating native is asynchronous before assuming the failing one is at fault.**
>
> Three releases were spent making the failure survivable, better reported and better cleaned
> up. All of that was downstream. The question that would have found it in an afternoon - "what
> does this native actually do?" - was never asked, because `CreateVehicle` looked too ordinary
> to check.
>
> The corollary: an error that is caught, logged and retried is not fixed. Every one of those
> releases made the log tidier, which made the real cause harder to see rather than easier.

---

## [2026-09-08 14:05] — The theme file set `position`, and every dialog moved

**Context:** Reported as "if you click on refuel, look, the box shifts everything and lands in
the wrong place".

**Error:** No error. The refuel dialog rendered in a narrow strip against the right edge, and
the panel itself became narrower when it opened.

**Root cause:** `html/css/panel.css` has `#modal { position: absolute; inset: 0 }`, which makes
it a full-panel overlay that centres its box. `html/css/sandy.css` - the THEME file, which
loads second - had this:

```css
#masthead, #tabs, .view, #toast, #modal { position: relative; z-index: 2; }
```

Same specificity, later file, so `relative` won. `#modal` stopped being out of flow and became
a flex ITEM of `#root`, which is `display: flex`. Measured at 1280x720: the panel went from
1178 pixels wide at x=51 to 1061 at x=0, and the dialog was squashed into 175 pixels at x=1083.

Every dialog in the resource - refuel, rename, set owner, choose a garage, confirm a delete -
had been in the wrong place since 1.0.0. The rule was written to lift interactive elements above
two decorative pseudo-element layers, which is a real need; `#modal` and `#toast` simply did not
belong in the list, because they were already positioned and already carried a z-index.

**Fix:** The stacking rule moved to panel.css and lists only elements that are in normal flow.
`tools/check.py` group 14 now fails the build if the theme file sets `position`, `display`,
`inset`, `float`, `flex`, `width`, `height`, `margin` or `padding` on anything but its own
`::before` / `::after` decorations.

**Prevention:**

> **A file whose contract is "appearance only" needs that contract enforced, not merely stated.**
>
> panel.css opens with a header explaining that the theme carries colours, textures and
> typography and that nothing else sets a literal colour. The split was documented, believed,
> and violated in the fourth rule of the theme file, and it stayed that way for four releases
> because the symptom looked like a dialog that had always been ugly.

---

## [2026-09-08 04:10] — Two panels opened on the right, both in the wrong place

**Context:** Reported after 1.0.2: "when you click on certain things a box appears on the right,
barely visible and badly placed". Two different boxes, both true.

**Error:** No error. Both rendered exactly as written.

**Root cause:**

The **detail sheet** was `position: absolute; top: 0; right: 0; bottom: 0` inside `#panel`. That
is the full height of the panel, over the masthead's summary counts, over the filter and sort
controls, and over the actions column of every visible row. The comment above it in
`index.html` claimed the list stayed visible; half of it did, and not the useful half.

It also used `--sheet`, the same paper as the table behind it, with one hairline border between
them. On a deliberately warm, low-contrast theme that is not enough separation for a 380px
column: it read as an empty stretch of table.

The **row overflow menu** was `position: absolute; top: calc(100% + 3px)` inside the row, and
`#table-wrap` is `overflow-y: auto`. It only ever opened downwards. Measured on the last row of
a full page at 1280x720: 239 pixels of the menu below the visible area, which is the last five
entries - To garage, Impound, Delete among them - rendered and unreachable. The comment beside
it reasoned carefully about horizontal clipping and never mentioned vertical.

**Fix:** The views and the sheet live in a `#stage` flex row, so the sheet is docked and the
table reflows into what is left. The sheet gets its own darker board, banded section headers,
zebra rows and measured contrast. The menu gets an `.is-up` variant chosen by measuring the
space above and below the button, plus a max-height from whichever side it uses.

**Prevention:**

> **An overlay has to be measured against what it lands on, not just positioned.** Both of these
> were written with a clear intention - "a side sheet so the list stays visible", "anchored to
> the column edge" - and neither was ever opened next to the thing it would cover. A comment
> stating the intention is not evidence that the intention was met.
>
> The practical rule that came out of it: a panel that has something to say about a row belongs
> **beside** the table in a flex row, not on top of it in absolute coordinates. Docking cannot
> cover anything by construction, and it needs no reasoning about which edges are safe.

---

## [2026-09-08 21:40] — Vehicles still multiplied, because the entity was recorded sixty lines too late

**Context:** Reported from the same live server that reported the 1.0.1 multiplication. The
1.0.1 fix was real and was not the cause. The console showed

    restored 0TL0W3I0170BZ (80JTQ816) from the trash
    script error in native 00000000635e5289: Tried to access invalid entity: 143624
    the streaming pass raised: ...

with the entity number climbing on every repetition: 141324, 143624, 152081, 153865, 154637.

**Error:** `Tried to access invalid entity`, raised out of the streaming pass, once a second.

**Root cause:** Two places, one rule broken twice.

`Spawn.create` called `CreateVehicle` at the top of the function and `Store.setLive` sixty lines
later. In between sat the routing bucket, the coordinates, the rotation, the orphan mode, the
culling radius and half a dozen statebag writes. `SetEntityCoords` and `SetEntityRotation` on a
freshly created server-side entity raise - the entity is registered but has no synchronisation
state until a client has it in scope. The exception propagated out before `Store.setLive` ran,
so the entity existed in the world and nothing had recorded it. `Store.isLive` then said no on
the next pass, which created another one, and `SetEntityOrphanMode(entity, 2)` had already told
the engine never to collect any of them.

`Spawn.despawn` had the mirror image: it read the vehicle's final position **before** clearing
its bookkeeping. The same raise left the vehicle registered as live with an entity on its way
out, nothing ever cleared it, and the pass hit that vehicle and died on it every tick
afterwards - which is a resource that has stopped streaming while looking perfectly healthy.

`Persist.adopt` had it a third time, writing the statebag before `Store.setLive` and without a
pcall, on a client-owned entity - the one kind whose statebag write can genuinely fail. A raise
there produced a duplicate of the car the player was sitting in.

**Fix:** The entity is recorded the instant it exists, before anything that can raise, and every
native after that point runs inside a pcall. `Spawn.despawn` clears `Store.setLive`, `pending`
and `deferred` first, unconditionally, and only then reads the pose through accessors that
cannot raise. Every create and every despawn in the pass is individually protected rather than
the pass being wrapped in one pcall, so one bad vehicle costs one vehicle. A pass that raises
anyway triggers an immediate reconciliation sweep.

**Prevention:**

> **Record it, then configure it. Never the other way round.**
>
> A server-side entity that exists and is not in `Store.live` is invisible to every part of this
> resource, and `orphanMode 2` guarantees the engine will not tidy it up either. The window
> between creating an entity and recording it must contain nothing that can raise, and in
> practice that means nothing at all.
>
> The mirror rule for removal: **clear the bookkeeping first, then touch the entity.** The worst
> case is a position that was not saved. The alternative is a resource that stops.

---

## [2026-09-08 22:05] — `DoesEntityExist` is not permission to read an entity

**Context:** Chasing the raise above.

**Error:** `script error in native 00000000635e5289: Tried to access invalid entity: 143624`
from `GetEntityCoords`, on an entity `DoesEntityExist` had just answered true for.

**Root cause:** A server-created entity that no client currently has in scope is registered
without synchronisation state. `DoesEntityExist` answers about registration; the position
natives need the state. They are two different questions and the first is not a gate for the
second.

**Fix:** `safeCoords`, `safeRotation`, `safeExists` and `safeDelete` in `server/spawn.lua`. A nil
answer means "could not read it", which every caller already handled by leaving the stored value
alone. `safeDelete` is deliberately NOT gated on existence: an entity that cannot be read may
still exist, and leaving it behind is the failure this whole release is about.

**Prevention:** On the server, treat every entity read as fallible. There is no cheap check that
makes one safe.

---

## [2026-09-08 22:30] — A vehicle loaded in another vehicle's colours, and was then saved that way

**Context:** Reported as two symptoms - "sometimes it loads in the wrong colours" and "the same
on restore". They were one bug seen at both ends.

**Error:** No error. A Bison rendered in a Sultan's custom paint, and the database agreed.

**Root cause:** A regression I introduced in 1.0.1. The property capture caches its expensive
half against a cheap fingerprint, and the cache is keyed on the entity handle - **which the game
reuses**. A vehicle that despawns frees its handle and the next one created can be given the
same number.

The fingerprint sampled twelve tuning values and none of them identified the vehicle. Worse, it
read colour *indices*, and `GetVehicleColours` keeps answering the underlying index while a
custom RGB colour is displayed, so custom paint was invisible to it entirely. Two different cars
that agreed on twelve values shared a cache entry, and the cache overwrote the freshly read
colours on the way out.

The caches were also cleared on only one of the two paths a vehicle leaves by. The
`vpark:client:forget` handler gated the clear on `DoesEntityExist`, and that event arrives
*because* the server is deleting the entity - so the check usually failed for exactly the
vehicles whose handles were about to be reused. The prune path in the wake loop did not clear
them at all.

**Fix:** The fingerprint includes the model, the plate and the custom paint. The model is
compared separately on every cache hit. Both removal paths clear both caches, unconditionally.

**Prevention:**

> **An entity handle is not an identity.** Anything keyed on one needs a value in it that says
> which vehicle it was, and the check has to be on the way OUT of the cache, not only on the way
> in.

---

## [2026-09-08 23:15] — `GetPlayerName(0)` raises, so console commands were never audited

**Context:** Spotted in the smoke test's boot log, at the end of `/vparkmigrate run`:

    script error in native 00000000406b4b20: Argument at index 0 was null.
    ERROR: a database thread raised: native 00000000406b4b20: Argument at index 0 was null.

Every check still passed, which is why it survived two releases.

**Error:** `Argument at index 0 was null` from `GetPlayerName`.

**Root cause:** `GetPlayerName(0)` does not return nil, it raises. Zero is the console, and the
console runs commands. `Bridge.name(src)` fell through to the raw native, so every audit row
written for a console-invoked command raised inside `Database.thread`, was swallowed by that
thread's pcall, and was silently never written. `/vparkmigrate run` from the server console has
never been audited in any version.

The same shape existed in `Actions.setOwner`, where the target id comes from operator input:
`/vparkowner <vehicle> 0` reached the native with a zero.

**Fix:** `Bridge.playerName(src)` - nil for anything that is not a connected player, pcall around
the native. `Bridge.name` answers `'console'` for a non-positive source. Every call site moved
over, and `tools/check.py` group 13 fails the build on a raw `GetPlayerName` outside the file
that defines the wrapper.

**Prevention:**

> **A pcall that swallows an error is not a fix, it is a place errors go to be forgotten.**
>
> `Database.thread` catching this is correct - a database thread must not take the resource down
> - but it meant a real defect logged one line and carried on for two releases. When a wrapper
> catches something, the log line has to be specific enough to act on, and somebody has to read
> it.

---

## [2026-09-09 03:20] — Vehicles multiplied until the server hit its entity limit

**Context:** Reported from a live server. The console filled with

    WARN: could not create vehicle 0TL0UEP01QT7G (model BISON)

several times a second, and copies of the same vehicle were piling up in the world.

**Error:** Two faults compounding, and the warning was a symptom of both rather than a cause.

**Root cause:** `CreateVehicle` returns a handle immediately, but the entity is not registered
synchronously - `DoesEntityExist` on that handle answers FALSE for a tick or two afterwards.
`Spawn.create` tested it straight away, concluded the creation had failed, logged a warning and
returned nil **without deleting the entity it had just successfully created**.

`SetEntityOrphanMode(entity, 2)` then guaranteed nothing would ever collect it: that native is
precisely an instruction to keep an entity nobody is near. So every streaming pass created
another copy of every vehicle, and none of them ever went away.

The second fault made it fast. The spawn budget counted SUCCESSES, so a pass in which every
creation "failed" counted zero and carried on down the entire candidate list - hundreds of
creations per second rather than the configured six.

Once the server reached its entity limit, `CreateVehicle` genuinely did start returning zero,
and the warning that had been wrong for the whole run became true.

**Fix:** Four changes.

- **A zero handle is the only failure.** Anything else is created and is ours - including ours
  to delete if we then decide not to keep it. Every early return after creation now deletes.
- **The budget counts attempts**, so a pass costs at most `spawnsPerPass` calls whether they
  work or not.
- **A per-vehicle failure counter and a ten-second backoff.** Five consecutive failures stops
  the retries for the session and says why once, instead of a wall of identical lines.
- **A reconciliation sweep**, `Spawn.reconcile`, which deletes any vehicle in the world carrying
  one of our ids that is not the entity registered for that id. That covers orphans nothing else
  will collect and duplicate copies of a vehicle we already have. It runs at boot and every
  thirty seconds, and `/vparkadmin reconcile` runs it on demand.

**Prevention:** Two rules. Never test `DoesEntityExist` on a handle in the same tick it was
created. And any function that creates an entity owns it from that moment: every path out has
to either register it or delete it, and there is no third option.

The reconciliation sweep is the belt to that braces. `orphanMode` means anything we lose track
of is ours to find again, and something has to go looking.

---

## [2026-09-09 03:45] — v-park hung at boot when the database was not running

**Context:** Found while re-running the smoke test after MariaDB had stopped.

**Error:** v-park printed `framework: qb (qb-core)` and then nothing at all. No error, no
memory-mode warning, no boot banner. Every timer in the resource waits on `Runtime.ready()`,
which never became true, so nothing ran and nothing said why.

**Root cause:** `Database.boot` polls `SELECT 1` in a loop until `connectTimeout`. But
`Citizen.Await` cannot be cancelled and cannot time out: if the database server is not listening
at all, oxmysql never invokes the callback the promise waits on, so the FIRST await never
returned and the loop's deadline was never reached.

The documented behaviour - fall back to memory and say so, loudly, once - was unreachable in
exactly the case it exists for.

**Fix:** The handshake query runs in its own thread and sets a flag; the deadline is enforced
outside it, where it can be. The orphaned thread stays parked on its await for the life of the
resource, holding one coroutine and no timer.

**Prevention:** A timeout around an await has to be enforced by something that is not itself
awaiting. Anywhere this resource waits on another resource, the wait needs a watcher rather than
a loop.

---

## [2026-09-09 03:05] — txAdmin comments out `set onesync` in server.cfg

**Context:** Enabling OneSync on the test server so the smoke test could run.

**Error:** The line was added, the server started, and OneSync was off. The config then read:

    ## [txAdmin CFG validator]: onesync MUST only be set in the txAdmin settings page.
    # set onesync on

**Root cause:** Not a v-park bug at all, and worth recording because it will reach the issue
tracker as one. txAdmin validates `server.cfg` on start and comments out settings it owns.
OneSync is one of them: on a txAdmin server it is set in the txAdmin settings page, and a line
in `server.cfg` is removed every time.

**Fix:** Nothing in the resource. For the test, `+set onesync on` on the FXServer command line,
which txAdmin does not touch. For operators, README now says where the setting actually lives.

**Prevention:** v-park's boot check already distinguishes "explicitly off" from "not set", so it
reports this accurately rather than refusing on a server that has it enabled elsewhere. That
distinction was added for a different reason and turned out to cover this one.

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
