# Changelog

All notable changes to v-park. Newest first. English, then French.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

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
