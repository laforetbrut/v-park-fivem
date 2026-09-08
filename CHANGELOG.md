# Changelog

All notable changes to v-park. Newest first. English, then French.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.6] - 2026-09-08

A pass over the restore path against what a persistence resource is actually for: the vehicle
is where it was, it looks how it did, it does not multiply, and none of that costs the server
anything to notice.

### Fixed

- **A failed placement no longer deletes the vehicle.** This is the big one. The server creates
  a vehicle at its saved coordinates and heading - those are arguments to the creation native -
  so a vehicle the client never touches is *already* exactly where it was left. Everything the
  client does afterwards only REFINES that: correcting a buried Z, clearing ambient traffic out
  of the bay, finding the nearest free spot when the exact one is occupied.

  Every failure of that refinement used to despawn the vehicle, and the streaming pass created
  it again a second later. A client that could not take control in time, a bay the search could
  not fit into, a raise inside the placement: all three deleted a correctly placed vehicle on a
  loop. That loop is what a player sees as flicker and what a server feels as lag.

  Only one answer deletes a vehicle now, and it is the one that says the entity is not there.

- **Not being able to take control is reported as success**, because the vehicle is where it
  belongs; the placement simply was not refined. The control wait also went from three seconds
  to five.

- **A vehicle that could not be dressed is never captured.** `Properties.apply` failing leaves a
  stock car standing where a modified one belongs, and the next capture wrote that stock state
  back over the real one - losing the modifications for good, from one failed apply. An
  undressed vehicle now reports nothing at all until an apply succeeds.

- **A frozen vehicle is not re-read when it despawns.** It cannot have moved: a frozen entity is
  not simulated and the wake handlers unfreeze it before a player can touch it. Reading it
  anyway was a slow drift - placement settles an entity by a few centimetres, collision
  streaming in nudges it, and each of those was written down on every despawn. A car parked and
  passed a hundred times moved a little further each time. The server now learns about a wake
  from the client - on entry, and from every snapshot - and re-reads the pose only for a vehicle
  that could actually have gone somewhere.

- **The orphan mode is re-asserted once the entity definitely exists.** `SET_ENTITY_ORPHAN_MODE`
  with KeepEntity is what guarantees the server will not collect a parked vehicle, and it was
  being set against an entity that was still orphaned. One native per restore removes the doubt.

- **A client that cannot see the entity at all gets a twenty-second backoff.** The usual cause is
  a scope problem that fixes itself when somebody walks closer; asking the same client the same
  question every second in the meantime is the same create-delete churn in a different place.

- **The reconciliation sweep stopped reading a statebag off every vehicle on the server.**
  `GetAllVehicles` returns ambient traffic too - hundreds of entities on a busy server - and the
  sweep was reading a statebag off each of them every fifteen seconds to find entities its own
  index already knew about. The statebag answers one question the index cannot, which is only
  meaningful in the first two minutes after a restart, so that is when it is asked.

---

## [1.0.6] - 2026-09-08 (français)

Une revue du chemin de restauration au regard de ce à quoi sert vraiment un script de
persistance : le véhicule est là où il était, il ressemble à ce qu'il était, il ne se multiplie
pas, et rien de tout cela ne coûte quoi que ce soit au serveur.

### Corrigé

- **Un placement qui n'a pas pu être affiné ne supprime plus le véhicule.** C'est le point
  central. Le serveur crée le véhicule à ses coordonnées et son cap enregistrés - ce sont des
  arguments du natif de création - donc un véhicule que le client ne touche jamais est **déjà
  exactement là où il avait été laissé**. Tout ce que fait le client ensuite ne fait
  qu'affiner : corriger un Z enterré, dégager le trafic ambiant, chercher la place libre la
  plus proche quand l'emplacement exact est occupé.

  Chaque échec de cet affinage supprimait le véhicule, et la passe de streaming le recréait au
  tick suivant. Un client qui n'obtenait pas le contrôle à temps, une place que la recherche ne
  trouvait pas, une erreur dans le placement : les trois supprimaient un véhicule correctement
  placé, en boucle. Cette boucle, c'est le clignotement, et le va-et-vient création/suppression
  derrière est l'essentiel de ce qu'un serveur ressent comme du lag.

  Une seule réponse supprime désormais un véhicule : celle qui dit que l'entité n'est pas là.

- **Ne pas obtenir le contrôle est rapporté comme un succès**, parce que le véhicule est au bon
  endroit ; seul l'affinage n'a pas eu lieu. L'attente passe de trois à cinq secondes.

- **Un véhicule qui n'a pas pu être habillé n'est jamais capturé.** Un `Properties.apply` en
  échec laisse une voiture d'origine là où une voiture modifiée devrait être, et la capture
  suivante écrivait cet état par-dessus le vrai, perdant les modifications définitivement.

- **Un véhicule gelé n'est pas relu à sa disparition.** Il ne peut pas avoir bougé. Le relire
  quand même était une dérive lente : le placement le tasse de quelques centimètres, le
  streaming de collision le bouscule, et tout cela était réécrit à chaque disparition, si bien
  qu'une voiture garée et croisée cent fois s'éloignait un peu à chaque passage. Le serveur
  apprend maintenant du client quand un véhicule est réveillé, et ne relit la pose que d'un
  véhicule qui a pu réellement bouger.

- **Le mode orphelin est réaffirmé une fois l'entité réellement existante.** C'est lui qui
  garantit que le serveur ne ramassera pas un véhicule garé.

- **Un client qui ne voit pas du tout l'entité obtient un délai de vingt secondes** avant une
  nouvelle tentative.

- **La passe de réconciliation ne lit plus un statebag sur chaque véhicule du serveur**, trafic
  ambiant compris, pour retrouver des entités que son propre index connaît déjà.

---

## [1.0.5] - 2026-09-08

**Vehicles appeared and then disappeared a few seconds later, in the wrong place.** A
regression in 1.0.4, and the fix is one line of judgement rather than one line of code.

### Fixed

- **A server-setter entity must not be waited on, and 1.0.4 waited on it.**

  1.0.4 changed vehicle creation to `CREATE_VEHICLE_SERVER_SETTER`, which was right, and kept
  the "wait for `DoesEntityExist`" loop that the old RPC path needed, which was wrong. The CFX
  documentation on server setter natives:

  > Server setter natives immediately and guaranteed register an entity with the server, but
  > the entity is initially **orphaned** - it will not be simulated nor exist in the game world
  > until a suitable client is within scope.

  So `DoesEntityExist` on a setter entity is false **by design** until a client takes
  ownership. Waiting three seconds for it and then deleting the vehicle meant deleting it at
  about the moment a client had streamed it in:

  ```
  [v-park] WARN: 0TL1SZG01HDUH did not become a usable entity in time - removing it
  [v-park] WARN: could not spawn 0TL1SZG01HDUH (model PREMIER): the entity never became usable
  ```

  And while they were there they were in the wrong place, because the restore instruction that
  dresses and places them is sent after that check and never was.

  The setter path is no longer waited on at all. The waiting a vehicle genuinely needs already
  happens on the **client**, in the restore handler, which waits up to twelve seconds for the
  entity to arrive before dressing and placing it - the client being the machine the entity is
  waiting for. The RPC fallback still waits, because on that path the wait is the correct
  answer; its budget went from three seconds to five.

- **A vehicle that had not reached a client yet could have its row deleted.** The
  external-delete detector reads `DoesEntityExist` as "something else removed this", and an
  orphaned entity answers false for the whole of its first few seconds. Past
  `Config.Lifecycle.externalDeleteGrace` - five seconds by default - it would have concluded
  the vehicle was gone and **deleted the row**. That is not a flicker, it is losing somebody's
  car. A vehicle now has to have been *seen* to exist at least once before it can be considered
  externally deleted.

- **One failed native no longer throws the whole vehicle away.** The configuration ran under a
  single `pcall`, so a pose write refused by an orphaned entity took the identity statebag down
  with it and the vehicle was discarded as unconfigurable. It is now two halves: the
  world-facing natives are best effort, and only the statebag that identifies the vehicle
  decides whether the creation worked. Nothing is lost by that - the position and heading were
  arguments to the creation native, and the client's placement pass sets the full pose a moment
  later anyway.

---

## [1.0.5] - 2026-09-08 (français)

**Les véhicules apparaissaient puis disparaissaient quelques secondes plus tard, au mauvais
endroit.** Régression de la 1.0.4.

### Corrigé

- **Une entité créée par le natif setter ne doit pas être attendue, et la 1.0.4 l'attendait.**
  La documentation CFX est explicite : ces natifs enregistrent l'entité immédiatement, mais
  elle reste **orpheline** et n'existe pas dans le monde tant qu'aucun client n'est à portée.
  `DoesEntityExist` est donc faux par construction, et attendre trois secondes puis supprimer
  revenait à supprimer le véhicule au moment précis où un client venait de l'afficher. Et il
  était au mauvais endroit parce que l'instruction de restauration, qui l'habille et le place,
  n'était jamais envoyée.

  L'attente qui compte a toujours lieu côté **client**, qui patiente déjà jusqu'à douze
  secondes. Le chemin RPC de secours attend toujours, lui, et passe de trois à cinq secondes.

- **Un véhicule pas encore parvenu à un client pouvait voir sa ligne supprimée.** Le détecteur
  de suppression externe lisait `DoesEntityExist` comme « autre chose l'a supprimé ». Passé le
  délai de grâce de cinq secondes, il aurait effacé la ligne. Ce n'est pas un scintillement,
  c'est perdre la voiture de quelqu'un. Un véhicule doit maintenant avoir été **vu** au moins
  une fois avant de pouvoir être considéré comme supprimé de l'extérieur.

- **Un natif en échec ne fait plus jeter tout le véhicule.** La configuration passait par un
  seul `pcall` : une écriture de pose refusée emportait avec elle le statebag d'identité. Elle
  est désormais en deux moitiés, et seule celle qui identifie le véhicule décide du succès.

---

## [1.0.4] - 2026-09-08

**The vehicles multiplied because the wrong native was creating them.** 1.0.1, 1.0.2 and 1.0.3
each fixed something real downstream of that and none of them found it.

### The cause

Server-side `CreateVehicle` is an **RPC**. It returns a handle immediately, but the entity is
not created until a client has been asked to make it and has answered. Until that round trip
finishes the handle refers to nothing, and every native against it fails:

```
script error in native 000000009e35dab6: Tried to access invalid entity: 135949
script error in native 00000000635e5289: Tried to access invalid entity: 135949
[v-park] WARN: 0TL1R3201WDS5 was created but could not be configured - removing it
script error in native 00000000faa3d236: Tried to access invalid entity: 135949
```

That third line is the delete failing for the same reason the configuration did. So each
attempt left an entity in the world - **undressed, with a random plate, and carrying no
`vpark:id` statebag, because setting it was the step that failed.** The reconciliation sweep
looked only at that statebag, so it could not see a single one of them.

They piled up on the vehicle's saved coordinates. Teleporting to your car put you among a stack
of unmarked copies of it, and getting into one gave you a different colour, a different plate
and no keys - which is exactly how it was reported.

### The fix

- **Vehicles are created with `CREATE_VEHICLE_SERVER_SETTER`.** The CFX documentation is
  explicit that server setter natives "immediately and guaranteed register an entity with the
  server". There is no window, so there is nothing to race. It also supports every vehicle type
  rather than automobiles alone, which is a second bug fixed by the same line: a boat or a
  helicopter created through the RPC path is exactly the kind of vehicle that never became
  real.

- **Where the setter native is unavailable, the RPC path waits for the entity** instead of
  assuming it is there - `while not DoesEntityExist(vehicle)`, with a timeout. That is what
  1.0.1 should have concluded from `DoesEntityExist` answering false, rather than concluding
  the check was worthless.

- **Every handle is written down before anything else touches it.** A new `ours` index, keyed
  by entity handle, written the instant the native returns. The reconciliation sweep asks it
  first and the statebag second, so an entity that failed before it could be marked is still
  findable - which is precisely the entity the bug was producing.

- **A delete that does not take is retried.** `DoesEntityExist` answers false for an entity
  that is not ready yet as well as for one that is gone, so a failed delete looked like a
  successful one. A condemned handle now stays condemned until `GetAllVehicles` stops listing
  it, which is the only source of truth that does not lie in that state.

- **An entity we created can never be adopted as a new vehicle.** A player who got into one
  before it was dressed looked, to the client, exactly like somebody getting into an ambient
  car - so a second row was written for a vehicle that already had one, under whatever plate
  the model spawned with. Then both rows streamed.

- **The retry backoff escalates and stops.** 10s, 20s, 40s, 80s, then it says so once and gives
  up. A flat ten seconds is an infinite loop with a delay in it when the cause is deterministic.

- **A ceiling on how many vehicles can be waiting to be dressed at once.** If something is
  stopping entities from becoming ready, creating another six a second makes it worse.

### The admin panel

- **Dialogs appeared in a squashed strip on the right instead of centred.** `sandy.css` set
  `position: relative` on `#modal`, and the theme file loads after the stylesheet that made it
  `position: absolute`. The dialog stopped being an overlay and became a flex item beside the
  panel. Measured at 1280x720: the panel went from 1178 pixels wide at x=51 to 1061 at x=0, and
  the dialog was 175 pixels wide at x=1083. Refuel, rename, set owner, choose a garage and
  confirm a delete were all affected, **from 1.0.0 to 1.0.3**.

  `tools/check.py` gained a fourteenth group that fails the build if the theme file sets a
  layout property on anything but its own decorative pseudo-elements.

- **The row's overflow actions are a centred dialog, not a dropdown.** The dropdown hung off
  the right of the actions column, covered the table header and three rows, had to flip
  upwards on the lower half of the page, and never said which vehicle it was about. Ten actions
  is not a dropdown's worth of content. It now names the vehicle, cannot be clipped and cannot
  cover the table.

- **The panel resolves roleplay names.** On qb-core an owner who has never been online while
  v-park was running showed as `KLJ61534`, because `owner_name` is only written when there is
  a player to ask. The panel now resolves the name out of the framework's own player table -
  `players.charinfo` on qb-core, `users` on ESX, `characters` on ox_core - one query per page,
  cached, and the character id is kept on the second line where it is still searchable.

### Schema

Version 2 adds `vehicle_type` to `v_park_vehicles`, which is what the setter native needs and
is **not** the vehicle class. It is captured from a client and guessed from the class until
then, so nothing has to be backfilled and existing rows keep working.

---

## [1.0.4] - 2026-09-08 (français)

**Les véhicules se multipliaient parce que le mauvais natif les créait.** Les 1.0.1, 1.0.2 et
1.0.3 ont chacune corrigé quelque chose de réel en aval, et aucune n'a trouvé la cause.

### La cause

`CreateVehicle` côté serveur est un **RPC**. Il renvoie un handle immédiatement, mais l'entité
n'est créée qu'une fois qu'un client a été sollicité et a répondu. Pendant cet aller-retour, le
handle ne désigne rien et tous les natifs échouent - y compris `DeleteEntity`. Chaque tentative
laissait donc dans le monde une copie **non habillée, avec une plaque aléatoire, et sans
statebag `vpark:id`** puisque c'est précisément l'étape qui échouait. La passe de
réconciliation ne regardait que ce statebag : elle n'en voyait aucune.

Elles s'empilaient sur les coordonnées sauvegardées du véhicule. Se téléporter sur sa voiture,
c'était atterrir au milieu de ces copies, et monter dans l'une d'elles donnait une autre
couleur, une autre plaque et aucune clé. Exactement ce qui a été signalé.

### La correction

- **Les véhicules sont créés avec `CREATE_VEHICLE_SERVER_SETTER`**, qui enregistre l'entité
  immédiatement et de façon garantie. Plus de fenêtre, donc plus de course. Il gère aussi tous
  les types de véhicules et pas seulement les automobiles.
- **Sans ce natif, le chemin RPC attend l'entité** au lieu de la supposer présente.
- **Chaque handle est noté avant que quoi que ce soit d'autre le touche**, donc une entité qui
  échoue avant d'être marquée reste trouvable.
- **Une suppression qui n'aboutit pas est réessayée** jusqu'à ce que `GetAllVehicles` confirme.
- **Une entité que nous avons créée ne peut jamais être adoptée** comme un nouveau véhicule.
- **Le délai de réessai augmente puis s'arrête** : 10s, 20s, 40s, 80s.

### Le panneau admin

- **Les boîtes de dialogue apparaissaient écrasées à droite au lieu d'être centrées.** Le
  fichier de thème imposait `position: relative` sur `#modal` et écrasait le `position:
  absolute` de la feuille de structure. Le dialogue devenait un élément flex à côté du panneau.
  Vrai **depuis la 1.0.0**.
- **Les actions d'une ligne sont un dialogue centré**, plus un menu déroulant collé à droite.
- **Le panneau résout les noms roleplay** depuis la table du framework (`players.charinfo` sur
  qb-core), l'identifiant restant affiché en seconde ligne.

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
