# Changelog

All notable changes to v-park. Newest first. English, then French.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.3] - 2026-09-08

The admin panel. Two things appeared on the right-hand side of it and both were in the wrong
place, one of them badly enough to make part of the panel unusable.

### Fixed

- **The detail sheet covered the panel instead of sitting beside it.** It was absolutely
  positioned at `top: 0; right: 0; bottom: 0`, which put it on top of the summary counts in the
  masthead, on top of the filter and sort controls, and on top of the entire actions column of
  every visible row. The comment above it said the list stayed visible. Half of it did.

  It is now **docked** in a flex row beside the table, so it cannot cover anything: the table
  reflows into the space that is left. Opening a detail costs the width of the sheet and
  nothing else.

- **The detail sheet was barely visible.** It used `--sheet` - the same paper as the table
  behind it - separated by a single hairline border, so on a warm low-contrast board it read as
  more table rather than as a panel. It now sits on its own darker board with a hard edge, the
  way the masthead and the footer already did.

  Its contents were low-contrast too: 12.5px labels in the table's muted grey, on a surface
  that grey was never measured against. Measured and corrected - section headers 7.0:1, labels
  7.4:1, values 9.6:1 - with banded section headers, zebra rows and 13px body text matching the
  table.

- **The row overflow menu opened off the bottom of the table.** `#table-wrap` clips its
  overflow and the menu only ever opened downwards. Measured on the last row of a full page:
  **239 pixels below the visible area**, which is To garage, Impound and Delete rendered and
  unreachable. It now opens upwards when there is more room above, and takes a max-height from
  whichever side it uses. Verified at 1920x1080, 1280x720 and 1024x600, on the first, middle
  and last rows: nothing clipped on any of them.

### Changed

- **The sheet says which vehicle it is showing.** It said "Vehicle detail" and nothing else, so
  opening two in a row gave no way to tell them apart. The plate and the model are now in the
  header.
- **The row the sheet is showing is marked** with an amber bar, so scrolling the table does not
  lose track of it.
- **The sheet carries the row's actions.** Reading that a car is wrecked and repairing it were
  a table-width apart; they are now the same place.
- **A row keeps one inline action while the sheet is open**, not three, and the other two move
  into the overflow menu. Keeping all three squeezed the state chips onto three lines and took
  the row height from 52 pixels to 96 - a page of five vehicles instead of nine - to keep two
  buttons the sheet was already showing.
- **The sheet stays current.** The fifteen-second auto-refresh replaced the table underneath it
  and left the detail showing the fuel level from whenever it was opened.
- **Switching to Trash or Cleanup closes it**, rather than leaving a vehicle detail beside a
  list that vehicle is not in.

---

## [1.0.3] - 2026-09-08 (français)

Le panneau admin. Deux choses apparaissaient à droite et les deux étaient mal placées, dont une
au point de rendre une partie du panneau inutilisable.

### Corrigé

- **La fiche de détail recouvrait le panneau au lieu de se placer à côté.** Positionnée en
  absolu sur tout le bord droit, elle passait par-dessus les compteurs, les filtres, le tri et
  toute la colonne des actions. Elle est maintenant **ancrée** à côté du tableau, qui se
  redimensionne : ouvrir un détail coûte la largeur de la fiche et rien d'autre.

- **La fiche était très peu visible.** Elle utilisait le même papier que le tableau, séparée par
  un simple filet, donc elle se lisait comme une colonne vide plutôt que comme un panneau. Elle
  a maintenant son propre fond, plus sombre, avec un bord franc. Contrastes mesurés et
  corrigés : en-têtes 7,0:1, libellés 7,4:1, valeurs 9,6:1, texte à 13px comme le tableau.

- **Le menu déroulant d'une ligne sortait par le bas du tableau.** Mesuré sur la dernière ligne
  d'une page pleine : **239 pixels hors de la zone visible**, soit Vers garage, Fourrière et
  Supprimer affichés et inatteignables. Il s'ouvre désormais vers le haut quand il y a plus de
  place au-dessus. Vérifié en 1920x1080, 1280x720 et 1024x600.

### Changé

- La fiche indique **quel véhicule** elle montre (plaque et modèle dans l'en-tête).
- La ligne concernée est **marquée** d'une barre ambre.
- La fiche **reprend les actions** de la ligne.
- Une ligne garde **une action directe** quand la fiche est ouverte, les autres passent dans le
  menu ; les garder toutes les trois faisait passer la hauteur de ligne de 52 à 96 pixels.
- La fiche **reste à jour** avec le rafraîchissement automatique.
- Passer sur Corbeille ou Nettoyage **la referme**.

---

## [1.0.2] - 2026-09-08

Three bugs, all of them serious, all of them reported from a live server. Two were introduced
by 1.0.1.

### Fixed

- **Vehicles multiplied without limit when approaching a group of them.** 1.0.1 fixed one cause
  of this and missed the real one.

  `Spawn.create` recorded the vehicle sixty lines after creating it. In between sat the routing
  bucket, the coordinates, the rotation, the orphan mode, the culling radius and half a dozen
  statebag writes - and `SetEntityCoords` and `SetEntityRotation` on a freshly created
  server-side entity **raise**:

  ```
  script error in native 00000000635e5289: Tried to access invalid entity: 143624
  ```

  The exception propagated out before `Store.setLive` ran, so the entity existed in the world
  and nothing had recorded it. Nothing had recorded it, so the next pass created another - and
  `SetEntityOrphanMode(entity, 2)` had already told the engine never to collect any of them.
  Rising entity handles in the console (141324, 143624, 152081, 153865, 154637) are the fleet
  growing.

  **The entity is now recorded the instant it exists**, before anything can raise, and every
  native after that point runs inside a `pcall`. A configuration that fails despawns cleanly
  instead of abandoning what it made.

- **The streaming pass died on a vehicle it could not read, and stayed dead.** `Spawn.despawn`
  read the vehicle's final position *before* clearing its bookkeeping. A server-side entity
  nobody has in scope can raise on a plain `GetEntityCoords` even when `DoesEntityExist` says
  yes, so the vehicle stayed registered as live with an entity on its way out, and the pass hit
  the same vehicle and raised again every second afterwards. That is the
  `the streaming pass raised: ...` line, and it is why a server could stop streaming while
  looking perfectly healthy.

  **The bookkeeping is now cleared first and cannot fail**; the pose read is best-effort through
  accessors that cannot raise. Every create and every despawn is individually protected, so one
  vehicle that cannot be handled costs one vehicle rather than the whole pass. A pass that
  raises anyway triggers an immediate reconciliation sweep rather than waiting for the timer.

- **Vehicles loaded in the wrong colours, and were then saved that way.** A 1.0.1 regression,
  and the two halves of the report were one bug: the property cache is keyed on the entity
  handle, **and the game reuses entity handles**.

  Handle 1234 was a custom-painted Sultan. It despawned. The next vehicle created was given
  handle 1234, agreed with the cache's twelve-value fingerprint - which sampled colour
  *indices* and could not see custom RGB paint at all - and the cache handed it the Sultan's
  paint. That car was then written to the database in the wrong colour, which is why it also
  came back wrong.

  The fingerprint now includes **the model, the plate and the custom paint**, the model is
  checked separately on every cache hit, and the caches are cleared on both paths a vehicle can
  leave by - not just the one that told us it was leaving.

- **A vehicle a player held the keys to was not persistent.** Reported for `/admincar`, and true
  of every vehicle that never gets a row in the framework's owned-vehicles table: a dealership
  demo, a job spawner, a heist car handed to the crew, a mate handing over their keys. See
  *Changed* below.

- **Getting the keys after getting in never asked again.** The on-entry offer that decides
  whether to keep a vehicle was made once per vehicle per session, so a player who sat down and
  *then* got the keys was never reconsidered. It now carries the plate and a timestamp, and
  re-offers after `Config.Persistence.entryOfferRetrySeconds` (60). The plate is in there because
  the table was keyed on the entity handle, which - again - the game reuses.

- **A raise while dressing a vehicle made it flicker.** The client sent no answer at all, so the
  server waited the full twenty-second timeout, despawned the vehicle and nominated somebody
  else. Applying properties is now protected and exactly one answer leaves the restore thread
  whatever happens inside it. A car that is dressed wrong is a much smaller problem than a car
  that appears, vanishes and appears again.

- **`Persist.adopt` could produce a duplicate of the car the player was sitting in.** It wrote
  the statebag before registering the vehicle, unprotected, on a client-owned entity - the one
  kind whose statebag write can fail. If it raised, the record existed and nothing was
  registered as live, so the streaming pass created a second copy. Same fix, same order.

- **`vpark:server:restoreFailed` accepted an answer from any client**, not only the one that was
  asked. The streaming pass put the vehicle straight back, so it wasted bandwidth rather than
  destroying anything, but it is not a message to act on.

- **A failed placement lost its retry backoff.** The fifteen-second deferral was set immediately
  before the despawn that clears it, so the vehicle was retried on the very next pass - the
  retry storm the deferral exists to prevent.

### Changed

- **`Config.Persistence.mode` now defaults to `'owned'`.** It was `'all'`, which persists every
  car anybody drives; on a busy server that is a table full of stolen taxis nobody will look for
  again. Set it back to `'all'` for the old behaviour.

- **Holding the keys counts as owning it.** `Config.Ownership.keysGrantOwnership`, on by default,
  and it is what makes `'owned'` mode usable rather than strict. The framework's record is still
  asked first and still wins, so handing a mate your keys does not hand them your car. One
  export call to your key resource, at the moment somebody gets into a vehicle that is not
  persisted yet - not per save and not per streaming pass. A key resource with no readable
  server-side answer is treated as "no keys" and the vehicle falls through to the settle timer
  exactly as before.

- **`/vpark` works in `'owned'` mode.** A claim is neither an owned vehicle nor a job one, so
  strictly read the mode would refuse it - and the park command would do nothing at all on a
  stock install. `Config.Persistence.allowClaimInOwnedMode`, on by default.

- **The reconciliation sweep runs every 15 seconds** rather than every 30. It is the net that
  catches anything the creation path still manages to lose, and a stray vehicle is far more
  visible than the cost of looking for one.

### Internal

- `tools/check.py` gained a twelfth check group that asserts the shipped defaults in
  `config.lua` against the values the README, the CHANGELOG and the release notes state. A
  default that drifts from its documentation costs an operator an afternoon.

---

## [1.0.2] - 2026-09-08 (français)

Trois bugs, tous sérieux, tous remontés depuis un serveur en production. Deux ont été introduits
par la 1.0.1.

### Corrigé

- **Les véhicules se multipliaient sans fin à l'approche.** La 1.0.1 avait corrigé une cause et
  raté la vraie. `Spawn.create` enregistrait le véhicule soixante lignes après l'avoir créé, et
  `SetEntityCoords` / `SetEntityRotation` sur une entité serveur fraîchement créée **lèvent une
  erreur**. L'exception passait avant `Store.setLive` : l'entité existait dans le monde et rien
  ne l'avait notée, donc la passe suivante en créait une autre, indéfiniment. L'entité est
  maintenant enregistrée dès qu'elle existe, avant que quoi que ce soit puisse lever, et toute
  la configuration qui suit est protégée.

- **La passe de streaming mourait sur un véhicule illisible, et restait morte.** `Spawn.despawn`
  lisait la position finale avant de nettoyer sa comptabilité. Une entité serveur que personne
  n'a en portée peut lever sur un simple `GetEntityCoords`, donc le véhicule restait enregistré
  comme vivant et la passe rebutait dessus chaque seconde. La comptabilité est désormais
  nettoyée en premier et ne peut pas échouer ; la lecture est au mieux. Chaque création et
  chaque suppression est protégée individuellement.

- **Les véhicules chargeaient avec la mauvaise couleur, puis étaient sauvegardés ainsi.**
  Régression 1.0.1 : le cache de propriétés est indexé sur le handle d'entité, **et le jeu
  réutilise les handles**. Une empreinte qui ne regardait que les index de couleur ne voyait pas
  la peinture personnalisée et laissait la Sultan repeinte céder sa couleur à la voiture
  suivante. L'empreinte inclut maintenant le modèle, la plaque et la peinture personnalisée, et
  les caches sont vidés sur les deux chemins de disparition.

- **Un véhicule dont le joueur avait les clés n'était pas persistant.** Signalé avec
  `/admincar`. Voir *Changé*.

- **Obtenir les clés après être monté ne redemandait jamais.** L'offre est maintenant renouvelée
  toutes les 60 secondes (`Config.Persistence.entryOfferRetrySeconds`).

- **Une erreur pendant l'habillage faisait clignoter le véhicule** : aucune réponse n'était
  envoyée, le serveur attendait vingt secondes puis supprimait et recommençait. Exactement une
  réponse quitte désormais le fil de restauration, quoi qu'il arrive.

- **`Persist.adopt` pouvait dupliquer la voiture où le joueur était assis**, pour la même raison
  d'ordre que `Spawn.create`.

### Changé

- **`Config.Persistence.mode` vaut maintenant `'owned'` par défaut.**
- **Avoir les clés vaut propriété** (`Config.Ownership.keysGrantOwnership`). Le registre du
  framework reste prioritaire : prêter ses clés ne donne pas la voiture.
- **`/vpark` fonctionne en mode `'owned'`** (`Config.Persistence.allowClaimInOwnedMode`).
- **La passe de réconciliation tourne toutes les 15 secondes** au lieu de 30.

---

## [1.0.1] - 2026-09-09

A stability and performance release, and one fix that matters more than everything else in it.

### Fixed

- **Vehicles multiplied until the server hit its entity limit.** `CreateVehicle` returns a
  handle before the entity is registered, so `DoesEntityExist` on it answers false for a tick or
  two. The creation path tested it immediately, concluded the creation had failed, and returned
  **without deleting the entity it had just created**. `SetEntityOrphanMode(entity, 2)` then
  guaranteed nothing would ever collect it, so every streaming pass added another copy.

  The spawn budget counted successes rather than attempts, so a pass in which everything
  "failed" carried on down the whole candidate list - hundreds of creations a second instead of
  six. Once the entity limit was reached, `CreateVehicle` really did start failing and the
  console filled with a warning that had been wrong for the entire run.

  Four changes: a zero handle is the only failure and every other path owns what it made; the
  budget counts attempts; a per-vehicle failure counter with a backoff replaces the retry storm;
  and a new reconciliation sweep deletes any vehicle in the world carrying one of our ids that is
  not the entity registered for it. It runs at boot and every 30 seconds, and
  `/vparkadmin reconcile` runs it on demand - which also cleans up a server that already has
  duplicates.

- **v-park hung at boot when the database was not running.** It printed the framework line and
  then nothing: no error, no memory-mode fallback, no banner, and every timer waiting on a ready
  flag that never came. `Citizen.Await` cannot time out, so with nothing listening the very first
  handshake query never returned and the connect deadline was never reached. The handshake now
  runs in its own thread and the deadline is enforced from outside it.

- **`SetEntityHeading` after `SetEntityRotation`** flattened the pitch of a vehicle parked on a
  slope, which is precisely what storing the full rotation exists to prevent. Removed from both
  the client placement and the server creation path.

- **An unanswered restore leaked its entity**, and enough of them froze streaming permanently:
  the timeout sweep sat below the entity-ceiling early return, so once the ceiling was reached it
  never ran again. It now runs first and despawns rather than only forgetting.

- **A per-class spawn radius larger than the global one did nothing**, because the grid query
  asked for the global radius and a filter can only narrow. The query now asks for the largest
  radius in play.

### Changed - performance

- **A parked vehicle is no longer captured at all.** A frozen vehicle is not simulated, cannot be
  damaged and cannot be occupied, so one that has not been touched since its last capture is
  provably identical to what the server already has. The client returns no snapshot for it, which
  the server already treats as "no news". On a fleet that is mostly parked this is most of the
  sweep cost gone rather than reduced.

- **The expensive half of a capture is cached against a fingerprint.** Every mod slot, the
  colours, the extras and the neons are about seventy-five native calls describing things that
  only change at a mechanic. Twelve cheap calls now decide whether to re-read them.

- **One placement scans the vehicle pool once, not forty-five times.** A blocked placement probes
  the saved pose, four vertical retries and up to forty ring candidates, and each probe used to
  allocate a table of every vehicle on the server. A snapshot is taken once per placement and
  every probe reads from it.

- **The spiral search starts every candidate's shape tests before reading any of them.** Shape
  tests are asynchronous, so forty-five candidates now cost one yield instead of forty-five -
  the difference between a placement that resolves in two frames and one that visibly takes most
  of a second on a busy street.

- **The semi-persistence sweep walks an ownership index** rather than the whole store. On a
  twenty-thousand vehicle server it was twenty thousand iterations a minute to look at perhaps
  forty cruisers.

### Changed - placement

- **The world probe uses perimeter rays rather than a box shape test.** `StartShapeTestBox`'s
  size arguments are undocumented; the community reading is half-extents, and if that reading
  were wrong the tested volume would be twice the size of the car and almost every tight space
  would report as blocked. 1.0.0 had to ship that as a stated limit.

  Six rays trace the footprint - the four sides at body height and the two diagonals, so a pillar
  in the middle of an otherwise clear bay is caught. A ray is two points and nothing about it is
  open to interpretation. The stated limit is gone.

### Added

- **Owned vehicles are kept the moment somebody gets in.** No settle timer, no command. The
  forty-five second timer answers "did they leave it there or are they coming back", which is a
  real question for a car nobody owns and not a question at all for one that is already in the
  player's garage list - and making them wait meant a player who took their car out and
  disconnected thirty seconds later lost it. `Config.Persistence.ownedImmediately`.

- **The admin panel gained selection and bulk actions.** Tick rows, or press A for the whole
  page, then repair, clean, refuel, unlock, send to a garage, impound or delete the lot in one
  action with one confirmation. Capped at 100, refused rather than truncated past that, and it
  writes one audit row and one webhook post rather than a hundred.

- **A detail view.** Every fitted part, the colours, the damage breakdown including the
  deformation point count, the network id, and the four timestamps that decide when a vehicle
  expires. It opens as a side sheet, so the list stays visible.

- **Sortable column headers**, an **owner online / owner offline filter**, and **keyboard
  shortcuts**: `/` to search, `R` to refresh, `A` to select the page, arrows to page, ESC to
  back out one level at a time.

- **`/vparkadmin reconcile`**, which runs the stray-vehicle sweep on demand and reports what it
  removed.

- **`Config.Streaming.reconcileInterval`** and **`Config.Persistence.ownedImmediately`**.

- **`tools/check.py` check 11**, which fails on any `ipairs` or `pairs` over `Store.toValues`.

### Documentation

- README now says where OneSync actually lives on a txAdmin server: the txAdmin settings page.
  txAdmin's config validator comments out `set onesync` in `server.cfg` on every start, so the
  obvious place to put it is the one place it does not work.

---

## [1.0.0] - 2026-09-08

First release.

Vehicle persistence for FiveM that puts a car back **in the space it was left in**, not
approximately near it. Everything below is in the first release; there is no history to read
against yet, so this entry describes what the resource is rather than what changed.

### Added

#### The placement engine

The reason the resource exists. Four separate mechanisms move a restored vehicle away from its
saved coordinates on a stock setup, and each gets its own answer:

- **Collision streaming.** Entities are created frozen and with collision off, and physics is
  handed back only once `HasCollisionLoadedAroundEntity` answers. A vehicle created before the
  map arrives falls, ends up under the ground, and is popped out into the road; this is the
  whole of that bug.
- **Occupancy.** The target volume is probed before anything is placed - the entity pool for
  vehicles, because it is exact and hands back the blocker, and a box shape test for world
  geometry and props. Only provably disposable vehicles are cleared: empty, unowned, not ours,
  not a mission entity. Traffic generation is then suppressed there for a few seconds so the
  game does not park an NPC car in the bay four seconds later.
- **Ground snapping.** `SetVehicleOnGroundProperly` is never called, and `tools/check.py`
  asserts that it never appears outside a comment. Placement is `SetEntityCoordsNoOffset` at
  the exact saved Z; the ground is consulted only when the saved Z is provably wrong, meaning
  more than `groundTolerance` metres *below* it.
- **Interiors.** The interior id and room key are stored and forced on restore, so a vehicle in
  an MLO garage is in the room rather than outside it looking in.

Plus `freezeUntilTouched`, on by default: a restored vehicle stays frozen until a player
approaches or interacts with it. A frozen entity cannot be walked out of a tight bay by the
physics solver over twenty minutes, and is not simulated at all.

`/vparkprobe` runs the whole probe where you stand and prints the model's box, the shrink in
use, whether the space reads as free, and what the search would do instead - which is how
`Config.Placement.probe.shrink` gets tuned against a specific MLO rather than guessed at.

#### Streaming

Nothing is spawned until somebody is near it. A spatial grid indexed on a cell key computed at
write time turns "what is near this player" into nine table lookups rather than a scan, so a
database with five thousand vehicles and one player online has perhaps thirty entities in the
world.

`spawnRadius` and `despawnRadius` differ by design; the gap is hysteresis, without which a
player standing on the boundary spawns and despawns the same vehicle several times a second.

Server-side entity creation with `SetEntityOrphanMode(entity, 2)` where the build has it,
because without it the engine collects a server-created entity as soon as no player is near -
which is a spawn-delete loop at our own radius boundary.

#### Delta saving

Every record carries an FNV-1a hash of its own state and is written when that hash moves and
not otherwise. A parked car does not change, so a server with three thousand parked cars writes
zero rows a minute.

The hash deliberately excludes `updated_at`, `touched_at`, `last_used_at` and `offline_secs`,
all of which change constantly by design; including any of them would make every vehicle dirty
on every sweep, which is exactly what the hash exists to prevent.

The sweep is sliced into quarters so the cost is a trickle rather than a sawtooth, and writes
are batched into one upsert per 200 vehicles inside a transaction.

#### Deformation

Bodywork shape is sampled into data, stored, and applied locally by **every** client - which
makes two players see the same dents by construction rather than by hoping the engine agrees
with itself.

The technique is established by [Kiminaze's
VehicleDeformation](https://github.com/Kiminaze/VehicleDeformation), which is MIT and worth
reading. Four things here are deliberately different: no probe pass and no spawned copy (a
sample point that is not on bodywork reports nothing, so the filtering is free at capture
time); the flanks are included, so a car hit in the driver's door stores something; points are
stored as a grid index and a magnitude rather than as two vectors; and convergence is seeded
from the target rather than crawling up in fixed steps.

Where `VehicleDeformation` is installed, v-park defers to it and still persists what it
reports. Two resources deciding what shape a car is, on different schedules, makes the car
pulse.

`recaptureDelta` is the guard that stops the approximation compounding across save cycles.

#### Semi-persistence

Job and rental vehicles tied to their owner's presence rather than to a clock. A cruiser
survives the 06:00 restart because the officer is still on shift, and goes 45 minutes after
they log off.

The countdown is a **counter, not a timestamp**, and that is the whole design. "Delete it 45
minutes after last-seen" is wrong in exactly the case the feature exists for: a server that
restarts at 06:00 and returns at 06:03 has, by that measure, had every offline player absent
all night, and every job vehicle would be gone at boot. The counter accumulates only while the
server is running and the owner is not.

`pauseWhileServerOffline = false` gives the wall-clock behaviour for a server that wants it.

#### Cleanup by use

`touched_at` moves whenever anything happens to a vehicle and answers "is this abandoned".
`last_used_at` moves only when a person gets in, and answers "does anybody still drive this".
They are different questions and one column cannot answer both: a car parked outside its
owner's house is touched constantly and has not been driven since March.

The cleanup sweep counts from the second, sends owned vehicles back to the garage they were
taken from - learned from the framework's own column at the moment we mark the vehicle as
out - and trickles rather than clearing the map in one pass. `/vparkadmin cleanup preview`
lists exactly what would go, and changes nothing.

#### The admin panel

`/vparkadmin`. Search, filter and sort every persisted vehicle; teleport to one, bring one to
you, drop a waypoint, repair, clean, refuel, unlock, rename, transfer, send to a named garage,
impound, delete. A trash tab restores a deleted vehicle exactly - modifications, damage and
dents included. A cleanup tab previews the idle sweep.

The garage dropdown is populated from your own garage resource, so it shows your garage names.
Every action re-checks its permission on the server; a hidden button is a convenience and never
the boundary.

Theme: `sandy` - Blaine County signage, hard edges, no rounded corners anywhere. A theme is one
CSS file; nothing in `panel.css` contains a colour.

#### Migration from Advanced Parking

Advanced Parking creates its own table and does not publish the schema, and the layout has
changed across its major versions. So the migration does not assume one: it reads
`INFORMATION_SCHEMA`, maps the columns it recognises, and prints the ones it does not.

Four steps, of which the first three change nothing: `scan`, `dry`, `run`, `rollback`. The
source table is only ever READ - never written, dropped or renamed - so the old script keeps
working and both can run side by side.

`UpdatePlate`, `DeleteVehicle` and `GetVehiclePosition` are answered under the same names, so a
garage or key script that already calls them keeps working after the switch.

#### Compatibility

qb-core, qbx_core, ESX and ox_core behind three adapters. oxmysql, mysql-async and ghmattimysql
behind a promise wrapper, so one code path works across every oxmysql version rather than
depending on which of `query`, `query_async` and `.await` a build publishes.

rcore_fuel, ox_fuel, LegacyFuel, ps-fuel, cdn-fuel, qs-fuelstations, lj-fuel, x-fuel,
okokGasStation and qb-fuel, plus a one-line statebag override for anything else. rcore_fuel is
detected first because it reconciles on its own tick and would otherwise overwrite a restored
tank; its value is also re-asserted once after a delay for the same reason.

qs-vehiclekeys, qb-vehiclekeys, wasabi_carlock, mk_vehiclekeys, cd_garage and jaksam for keys.
qs-advancedgarages, qb-garages, jg-advancedgarages and others for garages. qs-inventory,
ox_inventory and qb-inventory for the plate-to-stash link, which is protected rather than
managed. v-hud, ox_lib, okokNotify and the framework's own for notifications. jim-mechanic for
the nitrous bottle, including on vehicles the framework does not own - where its own in-memory
table would otherwise lose it on every restart.

Everything is detected at runtime and everything is optional. **OneSync is the only hard
requirement**, and it is checked at boot rather than assumed.

#### Discord webhooks

Three channels: errors, staff actions, activity. Errors are deduplicated on the message with
numbers stripped and rate-limited to twelve a minute, with the suppressed count carried into
the next post - so an error inside a per-second timer posts once rather than 3600 times an
hour, which is the failure mode that makes people turn error webhooks off.

URLs come from convars by default rather than from `config.lua`, because a webhook URL is a
credential and `config.lua` ends up in a repository and in support zips.

#### Everything else

- 21 commands, all renameable, all switchable, ACE-gated with a framework-group and job
  fallback. ACE is checked first and independently of the framework.
- A trash table, so an admin deleting the wrong car is a mistake rather than a catastrophe.
- An audit table, which answers "who deleted forty cars last Tuesday".
- Blocked zones as circles, boxes and polygons, with no PolyZone dependency, plus automatic
  zones around every garage the installed garage resource knows about.
- English and French, key-for-key identical, with matching format specifiers enforced by the
  check script.
- `tools/check.py`: ten check groups over every file - Lua 5.4 syntax, byte order marks, locale
  parity, locale usage, the callable gate, the ground snap, schema-to-SQL column parity,
  manifest completeness, schema gates, and reserved words used as bare table keys.

### Known limits

Stated in full in [README.md](README.md#known-limits-stated-plainly). The short version: only
qb-core has been run in game; deformation restore is approximate by nature; a blocked space
with nothing free nearby ends in an intersection by design; Advanced Parking's schema is
introspected rather than known; and garage list auto-detection needs an export that not every
garage build publishes.

---
---

# Version française

## [1.0.0] - 2026-09-08

Première version.

Persistance des véhicules pour FiveM qui remet une voiture **dans la place où elle a été
laissée**, pas approximativement à côté.

### Ajouté

**Le moteur de placement.** Quatre mécanismes distincts déplacent un véhicule restauré sur une
installation standard, et chacun reçoit sa propre réponse : création gelée et sans collision en
attendant le chargement de la map ; sondage du volume cible avant tout placement, avec
suppression du seul trafic ambiant manifestement jetable ; aucun appel à
`SetVehicleOnGroundProperly`, jamais, ce que le script de vérification impose ; et restauration
de l'intérieur et de la pièce pour les véhicules garés dans un MLO. Plus `freezeUntilTouched` :
un véhicule restauré reste gelé jusqu'à ce qu'un joueur s'en approche.

**Le streaming.** Rien n'apparaît tant que personne n'est à proximité. Une grille spatiale
transforme « qu'y a-t-il près de ce joueur » en neuf accès de table plutôt qu'en balayage.

**La sauvegarde différentielle.** Chaque enregistrement porte un hash FNV-1a de son propre état
et n'est écrit que si ce hash bouge. Une voiture garée ne change pas : trois mille voitures
garées écrivent zéro ligne par minute.

**Les déformations.** La forme de la carrosserie est échantillonnée, stockée, et appliquée
localement par **tous** les clients, ce qui fait que deux joueurs voient les mêmes bosses par
construction. Technique établie par VehicleDeformation de Kiminaze, avec quatre différences
délibérées : pas de passe de sondage ni de copie invisible du véhicule, les flancs sont
couverts, le stockage est un index et une magnitude au lieu de deux vecteurs, et la convergence
part d'une estimation au lieu de monter par paliers fixes.

**La semi-persistance.** Véhicules de métier et de location liés à la présence de leur
propriétaire. Le décompte est un **compteur, pas un horodatage** : il n'avance que pendant que
le serveur tourne et que le propriétaire est absent, sinon un redémarrage de trois minutes
compterait comme une nuit d'absence et viderait la map au démarrage.

**Le nettoyage par usage.** `touched_at` bouge dès que quoi que ce soit arrive au véhicule ;
`last_used_at` ne bouge que quand quelqu'un monte dedans. Deux questions différentes, qu'une
seule colonne ne peut pas trancher. Le nettoyage compte depuis la seconde et renvoie les
véhicules possédés dans le garage d'où ils venaient.

**Le panneau admin.** Recherche, filtres, tri, téléportation, faire venir, réparer, nettoyer,
ravitailler, déverrouiller, renommer, transférer, envoyer au garage, fourrière, supprimer, et
restaurer depuis la corbeille. Thème Sandy Shores, bords francs, aucun coin arrondi.

**La migration depuis Advanced Parking.** Quatre étapes dont les trois premières ne changent
rien. La table source n'est jamais qu'en lecture.

**La compatibilité.** qb-core, qbx_core, ESX, ox_core ; oxmysql, mysql-async, ghmattimysql ; dix
ressources de carburant dont rcore_fuel ; six systèmes de clés dont qs-vehiclekeys ; les
garages Quasar et les autres ; qs-inventory et ox_inventory ; v-hud pour les notifications ;
jim-mechanic pour le NOS. Tout est détecté à l'exécution, tout est optionnel. **OneSync est la
seule dépendance obligatoire**, et elle est vérifiée au démarrage.

**Les webhooks Discord.** Trois canaux, dédupliqués et limités en débit, avec les URL lues
depuis des convars plutôt que depuis `config.lua`.

### Limites connues

Détaillées dans [README.md](README.md#version-française). En résumé : seul qb-core a été testé
en jeu ; la restauration des déformations est approximative par nature ; une place bloquée sans
alternative proche finit en intersection, délibérément ; et le schéma d'Advanced Parking est
inspecté plutôt que connu.
