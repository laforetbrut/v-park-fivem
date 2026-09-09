# Changelog

All notable changes to v-park. Newest first. English, then French.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [semantic versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.21] - 2026-09-09

**Rien n'était conservé du tout, et c'est la vérification de proximité de la 1.0.19 qui en était
la cause entière.**

Le panneau admin affichait `0 KEPT`. Pas seulement le véhicule acheté : rien.

### Fixed

- **The 1.0.19 proximity check refused every adoption, not just purchases.** 1.0.20 identified it as
  the reason a bought vehicle was not kept and removed it, but understated what it had been doing.

  `Persist.adopt` is reached by two paths, and the one that matters most is the settle timer: a
  player parks, walks away, and forty-five seconds later the client offers the vehicle. **By
  definition the player has walked away** - `Config.Persistence.settleSeconds` is 45, so they are a
  hundred metres off - and the check refused anything offered from more than fifteen metres. So the
  ordinary way a vehicle becomes persistent was refused every single time, with no log line, and the
  store stayed empty.

- **A disagreement about where a vehicle is now corrects the value instead of refusing the
  vehicle.** The other half of the same check survived 1.0.20: the position in the message had to be
  within ten metres of where the server reads the entity, or the offer was refused.

  Refusing was wrong for the same reason twice, and it is worth stating plainly: **a refusal loses a
  vehicle and every other outcome does not.** The server's reading can be stale - it is maintained
  by the entity's network owner, and for a vehicle another resource created with the setter native
  it can sit at the spawn point indefinitely - so a disagreement is at least as likely to mean "the
  server is behind" as "the client is lying", and one of those two readings is not worth a car.

  The unforgeable value still wins, so the exploit it exists for is stopped just as dead. But the
  vehicle is kept either way, and if the server's reading was the stale one, the first capture after
  somebody drives the car corrects it - a self-healing wrong answer rather than a missing car.

112 automated checks on a real qb-core server with oxmysql and MariaDB 11.4, and 19 static check
groups over 32 Lua files.

---

## [1.0.21] - 2026-09-09 (français)

**Rien n'était conservé du tout, et la vérification de proximité de la 1.0.19 en était la cause
entière.**

### Corrigé

- **La vérification de la 1.0.19 refusait toutes les adoptions, pas seulement les achats.** La
  1.0.20 l'avait identifiée comme la raison pour laquelle un véhicule acheté n'était pas
  conservé et l'avait retirée, mais en sous-estimant ce qu'elle faisait.

  `Persist.adopt` est atteint par deux chemins, et le plus important est le minuteur de repos : un
  joueur se gare, s'éloigne, et quarante-cinq secondes plus tard le client propose le véhicule.
  **Par définition le joueur s'est éloigné** - `settleSeconds` vaut 45, il est à cent mètres -
  et la vérification refusait tout ce qui était proposé à plus de quinze mètres. La façon
  ordinaire dont un véhicule devient persistant était donc refusée à chaque fois, sans une seule
  ligne de log, et le registre restait vide.

- **Un désaccord sur la position corrige la valeur au lieu de refuser le véhicule.** L'autre
  moitié de la même vérification avait survécu à la 1.0.20.

  Refuser était mauvais pour la même raison deux fois, et ça vaut la peine de le dire clairement :
  **un refus perd un véhicule, et aucune autre issue ne le fait.** La lecture du serveur peut être
  périmée, donc un désaccord veut au moins autant dire &laquo;&nbsp;le serveur est en
  retard&nbsp;&raquo; que &laquo;&nbsp;le client ment&nbsp;&raquo;, et une de ces deux lectures ne
  vaut pas une voiture.

  La valeur infalsifiable gagne toujours, donc l'exploit reste bloqué. Mais le véhicule est
  conservé dans les deux cas, et si c'est la lecture serveur qui était périmée, la première
  capture après que quelqu'un a conduit la voiture la corrige.

112 vérifications automatisées sur un vrai serveur qb-core avec oxmysql et MariaDB 11.4, et 19
groupes de vérifications statiques sur 32 fichiers Lua.

---

## [1.0.20] - 2026-09-09

**A vehicle bought from a dealership was not kept, because of a check 1.0.19 added yesterday. And
deformation no longer costs sixty-eight native calls to establish that a car has no dents.**

### Fixed

- **Buying a vehicle did not make it persistent.** 1.0.19 required the player offering a vehicle to
  be within fifteen metres of it, as part of closing a hole where a client could register a vehicle
  at coordinates of its choosing. That check was wrong, and its shape is one this project keeps
  making: **it depends on a position the server may not have yet.**

  A purchased vehicle is spawned at the shop's `VehicleSpawn` while the buyer is still standing at
  the display car, and `TaskWarpPedIntoVehicle` moves them on the client with the server finding out
  by sync afterwards. Measured from qb-vehicleshop's own config, the gap between a display position
  and the spawn point is **11.7 m to 22.1 m at PDM and 22.1 m to 40.7 m at the Luxury shop** - so
  every display position at one shop and most at the other are beyond fifteen metres, and the offer
  was refused whenever the ped's position had not caught up.

  The ped is out of it. What remains is the check that actually mattered: the position in the
  message must be within ten metres of where the server reads the entity to be. Both sides of that
  comparison are read on the server, neither is a value the client chose, and none of it depends on
  a sync arriving in time. The distant offer the ped check was meant to stop bought almost nothing
  anyway - adopting a vehicle does not make it the offerer's, because `Ownership.resolve` reads the
  owner from the framework row.

- **Every refusal is now recorded, and `/vparkwhy` prints the last twenty-five.** Every refusal in
  the adoption path used to be a bare `return`: a vehicle that was not kept produced no log line, no
  message and no record, so the only possible report was "it did not work" and the only possible
  answer was a guess. That is precisely the hole `/vparkwhere` filled for positions, and it cost
  five releases there before anybody could see a number.

  Each entry carries the model, the plate, who offered it, how long ago, the reason as a sentence,
  and the raw reason key for a bug report. Three reasons that had no wording of their own now have
  it, and a new static check refuses a refusal reason that is not a real locale key - reasons are
  printed through `L(reason)` with a variable, so nothing else was checking them and the player was
  shown the raw key.

### Changed

- **Reading a deformation costs one native call instead of sixty-eight, unless something changed.**
  Sampling the bodywork is `GetVehicleDeformationAtPos` across the whole grid, and it ran on every
  vehicle in range on every sweep - to establish, almost every time, that a car nobody has crashed
  has no dents.

  `Properties.capture` already solves this for the other expensive half of a snapshot: the seventy
  native calls that read mod slots, colours, extras and neons sit behind a twelve-call fingerprint
  and are re-read only when somebody has fitted something. Deformation had no equivalent, so it was
  the entire cost of a capture on a fleet that is mostly parked. It has one now, and it is one call:

  - **Body health at full means no deformed panel anywhere**, so the grid is skipped outright.
  - **Body health unchanged since the last read means the same dents**, so the last answer stands.
    Bodywork cannot deform without body health moving - it is the number the engine derives from
    exactly the damage this file samples - so the cached answer is not an approximation of the
    truth, it is the last truth.

  Keyed by entity handle, so the model is stored alongside and a mismatch throws the entry away, and
  nothing is ever cached against a fingerprint that could not be read: an entry stored with a nil
  health would match every later call, because `nil == nil`, and freeze the answer for the life of
  the handle.

- **The snapshot no longer pays for a deformation it is about to discard.** A restored vehicle whose
  body health has not moved is deliberately not re-captured, because apply is approximate and
  re-capturing a restored shape walks the damage. That decision was being made **after** the read,
  and the answer does not depend on it.

112 automated checks on a real qb-core server with oxmysql and MariaDB 11.4, and 19 static check
groups over 32 Lua files.

---

## [1.0.20] - 2026-09-09 (français)

**Un véhicule acheté en concession n'était pas conservé, à cause d'une vérification ajoutée hier
par la 1.0.19. Et lire une déformation ne coûte plus soixante-huit appels natifs pour établir
qu'une voiture n'a aucune bosse.**

### Corrigé

- **Acheter un véhicule ne le rendait pas persistant.** La 1.0.19 exigeait que le joueur qui
  propose un véhicule soit à moins de quinze mètres de celui-ci. Cette vérification était
  mauvaise, et sa forme est celle que ce projet reproduit sans cesse : **elle dépend d'une position
  que le serveur n'a peut-être pas encore.**

  Un véhicule acheté apparaît au `VehicleSpawn` du magasin alors que l'acheteur est encore devant
  la voiture d'exposition, et `TaskWarpPedIntoVehicle` le déplace côté client, le serveur
  l'apprenant ensuite par synchronisation. Mesuré dans la config de qb-vehicleshop, l'écart entre
  une position d'exposition et le point d'apparition est de **11,7 à 22,1 m au PDM et de 22,1 à
  40,7 m à la concession de luxe** : toutes les positions d'un magasin et la plupart de l'autre
  dépassent quinze mètres, et l'offre était refusée dès que la position du ped n'avait pas suivi.

  Le ped n'en fait plus partie. Il reste la vérification qui compte vraiment : la position du
  message doit être à moins de dix mètres de là où le serveur lit l'entité. Les deux côtés de
  cette comparaison sont lus sur le serveur, aucun n'est une valeur choisie par le client, et rien
  n'y dépend d'une synchronisation qui arrive à temps.

- **Chaque refus est désormais enregistré, et `/vparkwhy` affiche les vingt-cinq derniers.** Chaque
  refus dans le chemin d'adoption était un `return` nu : un véhicule non conservé ne produisait
  aucune ligne de log, aucun message et aucune trace. Le seul rapport possible était
  &laquo;&nbsp;ça n'a pas marché&nbsp;&raquo; et la seule réponse possible une supposition. C'est
  exactement le trou que `/vparkwhere` a comblé pour les positions, et il avait coûté cinq
  versions.

  Chaque entrée porte le modèle, la plaque, qui a proposé, il y a combien de temps, la raison en
  phrase et la clé brute pour un rapport de bug. Une nouvelle vérification statique refuse une
  raison de refus qui n'est pas une vraie clé de traduction.

### Modifié

- **Lire une déformation coûte un appel natif au lieu de soixante-huit, sauf si quelque chose a
  changé.** L'échantillonnage de la carrosserie tournait sur chaque véhicule à portée, à chaque
  balayage, pour établir presque toujours qu'une voiture que personne n'a accidentée n'a pas de
  bosse.

  `Properties.capture` résout déjà ça pour l'autre moitié coûteuse d'un instantané : les
  soixante-dix appels qui lisent les modifications, les couleurs, les extras et les néons sont
  derrière une empreinte de douze appels. La déformation n'avait pas d'équivalent. Elle en a une
  maintenant, et c'est un seul appel :

  - **Santé de la carrosserie au maximum = aucun panneau déformé**, la grille est sautée.
  - **Santé inchangée depuis la dernière lecture = les mêmes bosses**, la dernière réponse tient.
    La carrosserie ne peut pas se déformer sans que cette santé bouge, donc la réponse en cache
    n'est pas une approximation de la vérité : c'est la dernière vérité.

- **L'instantané ne paie plus une déformation qu'il va jeter.** Un véhicule restauré dont la santé
  n'a pas bougé n'est volontairement pas recapturé, et cette décision était prise **après** la
  lecture.

112 vérifications automatisées sur un vrai serveur qb-core avec oxmysql et MariaDB 11.4, et 19
groupes de vérifications statiques sur 32 fichiers Lua.

---

## [1.0.19] - 2026-09-09

**An audit of all sixteen server-side net events, after 1.0.17 found two of them taking a vehicle
id on trust.**

1.0.17 closed a hole in the parked report by luck: it was found by rereading the file, not by
looking for it. So this release went through every net event the server registers and asked the
same question of each one - which of these values came from the client, and what has actually been
proven. Three more of the same kind came out, one of them wider than the original.

### Security

- **The capture path could relocate any parked vehicle, and it did not even need an id.** The
  server asks a client for snapshots of the vehicles near it and hands over the list of ids to
  report on. The client answers with each vehicle's position, and nothing checked that position
  against anything.

  The client already works the right way and says so in `Stream.snapshot`: position and rotation
  are omitted entirely until somebody has sat in the vehicle, because every vehicle near a player
  is woken, a woken vehicle is simulated, and a simulated vehicle on a camber rolls. **That rule
  was only ever enforced on the client, which means it was not enforced.** A modified client could
  put a stranger's parked car anywhere on the map, and unlike the 1.0.17 hole it did not have to
  know an id first - the server supplied them.

  The same rule now applies on the side that decides: a position is accepted only for a vehicle
  the server itself believes somebody has driven, and getting in has been proven since 1.0.17. No
  honest behaviour changes at all; it is the client's own documented rule, written where a lie
  cannot get past it.

- **A vehicle could be adopted at coordinates of the sender's choosing.** `Persist.adopt` takes a
  network id, a plate, a model and a position, all from the client, and nothing read any of them
  off the entity. So a player standing next to any adoptable vehicle could register it as
  persisted at any coordinates on the map, permanently - inside a wall, under the sea, in the sky.

  Two proofs now, both read on the server: the offering player must be within fifteen metres of
  the entity they are offering, and the position in the message must be within ten metres of where
  that entity actually is. An honest offer is generated from that very entity and is within
  centimetres, so nothing real is refused.

- **Any client could stop a stuck vehicle from ever being collected.** `vpark:server:restored`
  cleared the vehicle's `pending` flag **before** checking that the answer came from the client the
  server had actually asked. That flag is how the twenty-second sweep finds a vehicle whose
  nominated client never answered, so clearing it for an answer about to be discarded leaves the
  vehicle in the world undressed and unplaced, counting towards the entity ceiling. Enough of them
  and the streaming pass returns early every time and the resource stops spawning anything, with
  nothing in the console to say why.

  There was an honest route to the same place, which is the worse half: the comment right below the
  line already described a re-nomination racing with the previous client's late answer, and that
  late answer was clearing the **new** nomination's flag. `vpark:server:restoreFailed` had always
  done it in the correct order; this one had not.

### Changed

- **One distance test, not three.** The proximity proofs added in 1.0.17 and here were three copies
  of the same three lines. They are one function now, with the two rules built on top of it, so
  they cannot drift apart.

### Audited and found sound

Recorded so the next pass does not repeat the work: all six panel events gate on
`Actions.requireAdmin`. `vpark:server:captured` requires a live request token, that the token was
issued to the answering client, and that each id reported was one that client was asked about.
`vpark:server:describedCurrent` is bound to a token issued to that player. `vpark:server:restored`
and `vpark:server:restoreFailed` both require the answering client to be the nominated placer.

---

## [1.0.19] - 2026-09-09 (français)

**Un audit des seize net events du serveur, après que la 1.0.17 en a trouvé deux qui faisaient
confiance à un id de véhicule.**

La 1.0.17 a bouché un trou par chance : il a été trouvé en relisant le fichier, pas en le
cherchant. Cette version passe donc en revue chaque net event enregistré par le serveur avec la
même question : lesquelles de ces valeurs viennent du client, et qu'est-ce qui a réellement été
prouvé ? Trois autres du même genre en sont sortis, dont un plus large que l'original.

### Sécurité

- **Le chemin de capture pouvait déplacer n'importe quel véhicule garé, sans même avoir besoin
  d'un id.** Le serveur demande à un client des instantanés des véhicules autour de lui et lui
  fournit la liste des ids. Le client répond avec la position de chacun, et rien ne vérifiait
  cette position.

  Le client fonctionne déjà correctement et le dit dans `Stream.snapshot` : la position est omise
  tant que personne ne s'est assis dedans, parce que tout véhicule près d'un joueur est
  réveillé, et un véhicule réveillé sur un dévers roule. **Cette règle n'était appliquée que
  côté client, donc elle n'était pas appliquée.** Un client modifié pouvait mettre la voiture
  garée de n'importe qui n'importe où sur la carte, et contrairement au trou de la 1.0.17 il
  n'avait même pas besoin de connaître un id : le serveur les fournissait.

  La même règle s'applique maintenant du côté qui décide : une position n'est acceptée que pour
  un véhicule dont le serveur lui-même croit que quelqu'un l'a conduit. Aucun changement de
  comportement honnête.

- **Un véhicule pouvait être adopté à des coordonnées choisies par l'expéditeur.** Tout ce que
  `Persist.adopt` reçoit vient du client, et rien n'était relu depuis l'entité. Un joueur à
  côté de n'importe quel véhicule adoptable pouvait donc l'enregistrer comme persistant à
  n'importe quelles coordonnées, définitivement : dans un mur, sous la mer, dans le ciel.

  Deux preuves désormais, lues toutes les deux sur le serveur : le joueur qui propose doit être à
  moins de quinze mètres de l'entité, et la position du message à moins de dix mètres de là où
  cette entité se trouve vraiment.

- **N'importe quel client pouvait empêcher un véhicule bloqué d'être jamais récupéré.**
  `vpark:server:restored` effaçait le drapeau `pending` **avant** de vérifier que la réponse
  venait du client effectivement désigné. Ce drapeau est ce par quoi le balayage de vingt
  secondes retrouve un véhicule dont le client n'a jamais répondu. Assez de ces véhicules et le
  plafond d'entités est atteint, la passe sort immédiatement, et le script arrête de faire
  apparaître quoi que ce soit sans rien dire dans la console.

  Il y avait un chemin honnête vers le même résultat, et c'est la pire moitié : le commentaire
  juste en dessous décrivait déjà une redésignation en course avec la réponse tardive du client
  précédent, et cette réponse tardive effaçait le drapeau de la **nouvelle** désignation.
  `vpark:server:restoreFailed` l'avait toujours fait dans le bon ordre ; celui-ci non.

### Modifié

- **Un seul test de distance, plus trois.** Les preuves de proximité de la 1.0.17 et d'ici
  étaient trois copies des mêmes trois lignes. C'est une seule fonction maintenant.

### Audité et trouvé correct

Noté pour que la prochaine passe ne refasse pas le travail : les six événements du panneau
passent tous par `Actions.requireAdmin`. `vpark:server:captured` exige un jeton valide, émis pour
le client qui répond, et que chaque id rapporté lui ait été demandé.
`vpark:server:describedCurrent` est lié à un jeton émis pour ce joueur. `vpark:server:restored`
et `vpark:server:restoreFailed` exigent tous les deux que le client soit le placeur désigné.

---

## [1.0.18] - 2026-09-09

**Disconnecting at the wheel lost the drive, and the placement search is race-free at last.**

### Fixed

- **A vehicle being driven is captured four times as often, and asked of the person driving it.**
  Two things were wrong with one loop, and together they are the last way a vehicle could come back
  somewhere it used to be.

  The capture sweep cuts the live set into quarters so that three thousand parked cars are not
  hashed at once. A parked car has nothing to say - it is provably identical to its last capture -
  but a car being driven is the one thing in the set whose position is changing, and there is at
  most one per player. It is now in every slice: every 30 seconds becomes every 7.5.

  Worse, the sweep asked **the client nearest the vehicle's stored position**, which for a car being
  driven is where the drive started. Drive further than the streaming radius and the capture was
  asked of somebody who could not see the vehicle, so they answered nothing about it - silently,
  because a client that cannot see a vehicle is not an error. The occupant is now asked directly:
  they are sitting in it, which is an exact answer rather than an estimate.

- **The disconnect trigger looked at the wrong player.** `Persist.onPlayerDropped` marked dirty
  every vehicle whose **placer** was the leaving player. The placer is the client the server
  nominated to dress and place the vehicle, not the person driving it - the same confusion 1.0.16
  was made of, and they are the same client only on a single-player test. A player who got into
  somebody else's restored vehicle and then disconnected at the wheel flushed nothing at all. The
  occupant is marked now as well.

- **A stale server-side position is detected rather than guessed at.** A server-side entity's
  position is maintained by its network owner, so once the driver has walked away the value stops
  being updated - and what it is stale at is the position the server created the entity with. A
  stale read does not look like an error. It looks like an ordinary position from before the drive,
  which is what 1.0.15 wrote over a correct one.

  Three flags stood between that read and the row, and they work, but they are a heuristic about
  who might have moved the vehicle rather than a test of whether the number is real. The spawn
  position is now recorded, so the test is exact: a read that has not moved from where we put the
  car carries no information and is refused.

### Changed

- **The server names its own vehicles in the restore instruction, so the placement search no longer
  has to win a race.** A persisted vehicle standing at its saved pose was standing there when every
  other persisted vehicle nearby was saved. They coexisted, so neither is an obstacle to the other -
  but the box the client tests with is bigger than the bodywork, so two cars parked thirty
  centimetres apart overlap in it, and the search moved one of them by exactly `search.step`. That
  is the `1.250 m` reported from `/vparkwhere`, and it is why the search has shipped disabled since
  1.0.11.

  1.0.11 answered it with the `vpark:id` statebag, which is correct and was not enough: a replicated
  statebag arrives asynchronously, and several vehicles restored at once are placed before their
  neighbours' bags have landed. The server already knows the answer, with no race and nothing to
  wait for, so it says so. The statebag check stays as the second line.

  **The search is still off by default**, now for a different reason. What has not changed is the
  trade: with it on, a vehicle whose bay is genuinely occupied is placed up to `radius` away from
  where it was left, and that is what gets saved. Fifteen releases of this resource were about
  vehicles not being exactly where they were left, so exact wins by default.
  `Config.Placement.search.enabled = true` for a server where bays are genuinely contested.

- **Corrected two figures in the README** that had gone stale: the automated pass is 111 checks, not
  87, and `tools/check.py` runs seventeen groups, not fifteen.

### Prevention

- **`Store.near` returns wrappers, and reading a record field off one now fails the build.** It
  hands back `{ record, distanceSq }`, and getting that wrong fails in the worst way available:
  `wrapper.id` is nil, so a comparison against it is vacuously true and a lookup with it returns
  nil. The loop runs, finds nothing, reports nothing, and whatever depended on it quietly does not
  happen. Written after exactly that, in the neighbour list above, which was empty on every call
  before the check caught it.

- **A test procedure for the client half.** Twenty-two cases over the position guarantee, entity
  count, paint and modifications, tight spaces with the search both off and on, ownership, the
  panel, and the timing line. Every case asks for a figure rather than an impression, because
  eighteen releases of server-side checks have never once caught the bug that was actually
  reported: all of them lived in the client.

---

## [1.0.18] - 2026-09-09 (français)

**Se déconnecter au volant perdait le trajet, et la recherche de place ne dépend plus d'une course
réseau.**

### Corrigé

- **Un véhicule en cours de conduite est capturé quatre fois plus souvent, et demandé à la
  personne qui le conduit.** Deux erreurs dans la même boucle, et ensemble elles sont la
  dernière façon dont un véhicule pouvait revenir à un ancien endroit.

  Le balayage de capture découpe l'ensemble en quarts pour ne pas hacher trois mille voitures
  garées d'un coup. Une voiture garée n'a rien à dire, mais une voiture conduite est la seule
  chose dont la position change, et il y en a au plus une par joueur. Elle est maintenant dans
  chaque quart : toutes les 30 secondes devient toutes les 7,5.

  Pire, le balayage demandait **au client le plus proche de la position enregistrée**, c'est-à-dire
  là où le trajet a commencé. En roulant plus loin que le rayon de streaming, la capture était
  demandée à quelqu'un qui ne voyait pas le véhicule, et qui ne répondait donc rien à son sujet,
  en silence. C'est l'occupant qui est interrogé maintenant : il est assis dedans.

- **Le déclencheur de déconnexion regardait le mauvais joueur.** Il marquait les véhicules dont le
  **placeur** partait. Le placeur est le client désigné pour habiller et placer le véhicule, pas
  celui qui le conduit : la même confusion que la 1.0.16. Un joueur qui montait dans le véhicule
  restauré de quelqu'un d'autre puis se déconnectait au volant n'enregistrait rien du tout.

- **Une position serveur périmée est maintenant détectée, plus devinée.** Une lecture périmée ne
  ressemble pas à une erreur : elle ressemble à une position ordinaire d'avant le trajet, et c'est
  ce que la 1.0.15 a écrit par-dessus une bonne. La position de création est maintenant
  enregistrée, donc le test est exact : une lecture qui n'a pas bougé de là où on a posé la
  voiture ne porte aucune information et est refusée.

### Modifié

- **Le serveur nomme ses propres véhicules dans l'instruction de restauration**, donc la recherche
  de place n'a plus de course à gagner. Deux voitures garées à trente centimètres se chevauchent
  dans la boîte de test, et la recherche en déplaçait une de `search.step` exactement : c'est le
  `1.250 m` rapporté par `/vparkwhere`.

  La 1.0.11 avait répondu avec le statebag `vpark:id`, ce qui était juste et insuffisant : un
  statebag répliqué arrive de façon asynchrone. Le serveur connaît déjà la réponse, sans course
  et sans attente.

  **La recherche reste désactivée par défaut**, pour une autre raison désormais. Le compromis n'a
  pas changé : activée, un véhicule dont la place est vraiment occupée est posé jusqu'à `radius`
  plus loin, et c'est ça qui est enregistré. Quinze versions de ce script portaient sur des
  véhicules qui n'étaient pas exactement où on les avait laissés.

- **Deux chiffres corrigés dans le README** : 111 vérifications et non 87, dix-sept groupes et non
  quinze.

### Prévention

- **`Store.near` renvoie des enveloppes, et lire un champ d'enregistrement dessus fait maintenant
  échouer la vérification.** L'erreur échouait de la pire manière possible : silencieusement. La
  boucle tournait, ne trouvait rien, ne signalait rien.

- **Une procédure de test pour la moitié client.** Vingt-deux cas, et chacun demande un chiffre et
  pas une impression : dix-huit versions de vérifications côté serveur n'ont jamais attrapé le bug
  qui a été rapporté, parce qu'ils vivaient tous dans le client.

---

## [1.0.17] - 2026-09-09

**It works, so this release does not change what it does. It hardens it, measures it, and closes
a hole found while reading it.**

Fifteen releases went into one property: a vehicle comes back exactly where it was left. That
property now holds, and everything here exists to keep it holding - a guard around the fields
three releases were lost to, numbers where there were guesses, and a diagnostic that answers from
the console instead of needing somebody standing next to the car.

### Security

- **A client can no longer speak for a vehicle it is not standing next to.** `vpark:server:parked`
  and `vpark:server:touched` are net events, so any client can trigger them for any id - and an id
  is not a secret, because `vpark:id` is a replicated statebag that every client in scope reads and
  keeps.

  The parked handler checked that the reported position was within 50 m of the reporting player.
  That looks like a proximity check and is not one: **the sender chooses the reported position**, so
  sending your own coordinates passed it from anywhere on the map. Any persistent vehicle whose id
  you had ever seen could be dragged to your feet, permanently. `touched` needed no proof at all,
  which made it a way to mark a vehicle driven and have the despawn overwrite a correct position
  with a stale one - the 1.0.16 bug turned into a tool - and it wrote a database row on every call,
  so it was one write per message from an unauthenticated client.

  Both now require a proof the sender cannot fabricate: **the distance between the player's ped and
  the vehicle entity, both read on the server**. Neither value comes from the message. It is
  readable exactly when a client has the vehicle in scope, which is exactly when somebody is in it
  or beside it, so the honest path always passes.

  When the entity cannot be read, the row's own position is used as the reference with a wider
  radius, rather than refusing. That is the deliberately safer half of the trade: refusing would be
  stricter and would risk discarding a real drive, which is the worst bug this resource has had.

### Added

- **`/vparkdiag [id|plate]`, the console half of `/vparkwhere`.** With no argument, every vehicle in
  the world ordered by how far it has drifted from its stored place, worst first. With one, the
  whole record: stored pose, actual pose, the distance between them, entity and net id, and the
  four flags that decide whether that vehicle's position is allowed to be written down at all.

  `/vparkwhere` needs a player standing next to the vehicles and reports what the client sees.
  Neither is available while reading a log after the fact, and the flags only exist on the server.

- **`/vparkstats` reports an average and a worst case, not just the last reading.** For the
  streaming pass, the capture sweep and the reconciliation. The duration of the last pass is very
  nearly no information: a loop that is fine ninety-nine times and terrible on the hundredth reads
  as fine, and the one reading that mattered has been overwritten by the time anybody looks.

- **A health line in `/vparkstats` and `/vparkdiag`:** how many vehicles are waiting on a client,
  waiting to be deleted, and queued for another restore attempt. The difference between a resource
  that is busy and one that is stuck.

### Prevention

- **A live entry's fields are now a documented list, and an undocumented one fails the build.**
  Every one of the fourteen says who sets it, who reads it and what clears it. 1.0.16 was caused by
  setting `driven` to mean `this has been used`, not knowing `driven` was also the flag permitting
  the despawn to re-read the entity's position: the correct parked position was written and then
  overwritten with a stale one seconds later. One word doing two jobs, and the second undid the
  first. That is not a mistake anybody makes reading fourteen undocumented booleans off a table.

- **A locale line and its call site must agree on how many values there are.** `L` wraps
  `string.format` in a pcall and returns the raw template when the format fails, which is right at
  runtime and means a call site passing the wrong number of values does not raise, does not log and
  does not stop working. It quietly prints `lifecycle: %d expired, %d owner-absent`.

- **Two new integration sections.** That a full write cycle over a row never touches its position,
  to the millimetre, over four unrelated writes and a despawn. And that a report which cannot be
  proven leaves the row exactly where it was.

104 automated checks on a real qb-core server with oxmysql and MariaDB 11.4, and 17 static check
groups over 32 Lua files.

---

## [1.0.17] - 2026-09-09 (français)

**Ça fonctionne, donc cette version ne change pas ce que le script fait. Elle le blinde, elle le
mesure, et elle ferme un trou trouvé en le relisant.**

Quinze versions pour une seule propriété : un véhicule revient exactement où il a été laissé.
Cette propriété tient maintenant, et tout ce qui suit existe pour qu'elle continue de tenir : une
barrière autour des champs qui ont coûté trois versions, des chiffres là où il y avait des
suppositions, et un diagnostic qui répond depuis la console au lieu d'exiger quelqu'un debout à
côté de la voiture.

### Sécurité

- **Un client ne peut plus parler au nom d'un véhicule à côté duquel il ne se trouve pas.**
  `vpark:server:parked` et `vpark:server:touched` sont des net events : n'importe quel client peut
  les déclencher pour n'importe quel id, et un id n'est pas un secret, puisque `vpark:id` est un
  statebag répliqué que tous les clients à portée lisent et gardent.

  Le handler vérifiait que la position **rapportée** était à moins de 50 m du joueur. Ça ressemble
  à un test de proximité mais ce n'en est pas un : **c'est l'expéditeur qui choisit la position
  rapportée**, donc envoyer ses propres coordonnées passait le test depuis n'importe où sur la
  carte. N'importe quel véhicule persistant dont on avait vu l'id une fois pouvait être traîné à
  ses pieds, définitivement. `touched` n'exigeait aucune preuve, ce qui en faisait un moyen de
  marquer un véhicule comme conduit et de laisser le despawn écraser une position correcte par une
  périmée, et il écrivait une ligne en base à chaque appel.

  Les deux exigent maintenant une preuve que l'expéditeur ne peut pas fabriquer : **la distance
  entre le ped du joueur et l'entité du véhicule, lues toutes les deux sur le serveur**. Aucune des
  deux valeurs ne vient du message.

  Quand l'entité est illisible, c'est la position de la ligne en base qui sert de référence avec un
  rayon plus large, plutôt qu'un refus. C'est la moitié volontairement plus prudente du compromis :
  refuser serait plus strict et risquerait de jeter un vrai trajet, ce qui est le pire bug que ce
  script ait eu.

### Ajouté

- **`/vparkdiag [id|plaque]`, la moitié console de `/vparkwhere`.** Sans argument, tous les
  véhicules du monde classés par écart avec leur place enregistrée, le pire en premier. Avec un
  argument, la fiche complète : pose enregistrée, pose réelle, distance entre les deux, entité et
  netId, et les quatre drapeaux qui décident si la position de ce véhicule peut être écrite.

- **`/vparkstats` affiche une moyenne et un pire cas, plus seulement la dernière mesure.** La durée
  de la dernière passe ne dit presque rien : une boucle correcte quatre-vingt-dix-neuf fois et
  catastrophique la centième se lit comme correcte.

- **Une ligne de santé** : combien de véhicules attendent un client, attendent une suppression, ou
  sont en attente d'une nouvelle tentative de restauration. La différence entre un script occupé et
  un script bloqué.

### Prévention

- **Les champs d'une entrée vivante sont une liste documentée, et un champ non documenté fait
  échouer la vérification.** La 1.0.16 venait de là : `driven` servait à deux choses, et la seconde
  défaisait la première.

- **Une ligne de traduction et son appel doivent être d'accord sur le nombre de valeurs.** `L`
  encapsule `string.format` dans un pcall et renvoie le modèle brut en cas d'échec, donc un appel
  qui passe le mauvais nombre de valeurs n'échouait pas, ne se signalait pas, et affichait
  simplement `lifecycle: %d expired`.

- **Deux nouvelles sections de test d'intégration.** Qu'un cycle d'écriture complet ne touche jamais
  la position, au millimètre. Et qu'un rapport qui ne peut pas être prouvé laisse la ligne où elle
  était.

104 vérifications automatisées sur un vrai serveur qb-core avec oxmysql et MariaDB 11.4, et 17
groupes de vérifications statiques sur 32 fichiers Lua.

---

## [1.0.16] - 2026-09-09

**Getting out of a vehicle only saved its position on one client in the server.**

1.0.14 made the client report a vehicle's pose the instant the driver gets out, and asked
`Stream.byEntity` whether the vehicle was one v-park keeps. That table is populated by the
`vpark:client:restore` handler - and **that instruction is sent to exactly one client**, the one
the server nominated to dress and place the vehicle. Every other client's copy is empty for it.

So a player getting into a vehicle that was restored for somebody else - which is most vehicles
on a server with more than one player, and any vehicle at all once the nominated client has
driven off - was invisible to the check. Getting out of it reported nothing, and the parked
position was never sent. It worked when the player happened to be the placer and did nothing
when they were not, which is "almost, but one of them still went back to an old place".

### Fixed

- **The vehicle's own statebag is the question now.** `vpark:id` is replicated: every client in
  scope has it, and a player who has just spent time sitting in the vehicle has certainly had it
  for a while. The tracked table is still asked first, because on the nominated client it is a
  table lookup and already the answer.

  Both the parked report and the "somebody got in" message go through it, so they now fire for
  every player in every vehicle v-park keeps.

- **A vehicle that is already ours skips the adoption path on exit.** It used to fall through to
  the settle timer, which ends in an offer the server refuses as already ours - harmless, and a
  message per parked vehicle for no reason.

---

## [1.0.16] - 2026-09-09 (français)

**Sortir d'un véhicule n'enregistrait sa position que sur un seul client du serveur.**

La 1.0.14 fait rapporter la pose par le client dès que le conducteur sort, et demandait à
`Stream.byEntity` si le véhicule était suivi par v-park. Or cette table est remplie par le
handler `vpark:client:restore` - et **cette instruction n'est envoyée qu'à un seul client**,
celui que le serveur a désigné pour habiller et placer le véhicule. Chez tous les autres, elle
est vide pour ce véhicule.

Un joueur qui monte dans un véhicule restauré pour quelqu'un d'autre - c'est-à-dire la plupart
des véhicules dès qu'il y a plus d'un joueur, et n'importe lequel une fois que le client désigné
est parti - était donc invisible pour ce test. Sortir n'envoyait rien. Ça marchait quand le
joueur se trouvait être le placeur, et ne faisait rien sinon : « presque, mais il y en a encore
un qui est revenu à un ancien endroit ».

### Corrigé

- **C'est le statebag du véhicule qui répond maintenant.** `vpark:id` est répliqué : tous les
  clients à portée l'ont, et un joueur qui vient de passer du temps assis dedans l'a
  certainement depuis longtemps. La table locale reste consultée en premier, parce que sur le
  client désigné c'est une simple lecture de table et déjà la réponse.
- **Un véhicule déjà à nous saute le chemin d'adoption à la sortie.**

---

## [1.0.15] - 2026-09-09

**The parked position was being written correctly and then overwritten with the old one seconds
later.** A regression in 1.0.14, in the line that release added.

### What happened

1.0.14 made the client send a vehicle's pose the instant the driver gets out, which was right.
It also set `driven` on the server entry when that report arrived, to record that the vehicle
had been used - and `driven` is the flag that lets **the despawn read the entity's position back
one last time**.

So the sequence was: park, get out, correct position written. Walk away, the vehicle leaves the
streaming radius, and the despawn reads the entity's server-side coordinates over the top of it.

**A server-side entity's position is maintained by its network owner.** Once the driver has
walked away and ownership has lapsed, the value the server holds is stale - and what it is stale
at is the position the server created the entity with, which is the position from **before the
drive**.

The vehicle came back where it used to live. Which is the symptom 1.0.14 set out to fix, caused
by 1.0.14.

### Fixed

- **A parked report is the last word.** It is the pose from the machine that was driving, taken
  at the moment the answer stopped changing, and nothing may overwrite it. The despawn skips its
  read for a vehicle that has been reported parked. Getting in again clears the mark, because
  from that moment the vehicle can move and the report is no longer the truth.

- **The client stops reporting a position after it has reported the parked one.** The rule from
  1.0.13 is that only a driven vehicle says where it is, because a merely woken one is simulated
  and rolls. `driven` was set when the player got in and nothing cleared it, so after they got
  out the vehicle carried on reporting a position physics was still free to change. The pose
  sent at the door is the answer; everything after it is drift.

---

## [1.0.15] - 2026-09-09 (français)

**La position au stationnement était bien écrite, puis écrasée quelques secondes plus tard par
l'ancienne.** Régression de la 1.0.14, dans la ligne que cette version avait ajoutée.

### Ce qui se passait

La 1.0.14 fait envoyer la pose par le client à l'instant où le conducteur sort, ce qui est
juste. Elle posait aussi `driven` sur l'entrée serveur à la réception de ce rapport - et
`driven` est justement le drapeau qui autorise **la relecture de la position de l'entité à la
disparition**.

La séquence était donc : se garer, sortir, bonne position écrite. S'éloigner, le véhicule quitte
le rayon de streaming, et la disparition relit les coordonnées serveur par-dessus.

**La position serveur d'une entité est tenue à jour par son propriétaire réseau.** Une fois le
conducteur parti et la propriété perdue, la valeur que le serveur détient est périmée - et elle
est périmée à la position avec laquelle le serveur a créé l'entité, c'est-à-dire celle **d'avant
le trajet**.

Le véhicule revenait donc à son ancien emplacement. Exactement le symptôme que la 1.0.14
prétendait corriger, causé par la 1.0.14.

### Corrigé

- **Un rapport de stationnement a le dernier mot.** Rien ne peut l'écraser. La disparition ne
  relit plus la position d'un véhicule déjà rapporté garé. Remonter dedans lève la marque.
- **Le client cesse de rapporter sa position après le rapport de stationnement.** `driven` était
  posé à l'entrée et rien ne l'effaçait, donc après la sortie le véhicule continuait de rapporter
  une position que la physique pouvait encore changer.

---

## [1.0.14] - 2026-09-09

**A vehicle is written down the moment it is parked**, by the client that was driving it.

### The gap

Getting out of a persisted vehicle did nothing at all. `worthReporting` answers false for a
vehicle v-park already tracks, which is correct - that check is about whether to ADOPT something
new - so nothing was sent, and where the vehicle had just been left was discovered later by one
of two things:

- **the periodic capture sweep**, which runs in quarters and may be seconds away;
- **the final pose read when the vehicle despawns**, which asks the SERVER for the entity's
  coordinates.

Both fail in the same case, and it is the ordinary one: park, get out, walk or drive away. The
sweep has not come round yet, and by the time the vehicle leaves the streaming radius no client
has it in scope any more - so the server-side read returns nothing and the stored position stays
whatever it was **before the drive**.

The vehicle then comes back where it used to live rather than where it was left. Reported as
exactly that: "sometimes the position is saved in the wrong place, and if I leave the vehicle
and go quickly it is not saved at all".

### The fix

The client that was driving is the one machine that certainly knows where the vehicle ended up,
and getting out is the instant that answer stops changing. It now sends the pose then: one small
message, once, per vehicle parked.

The server accepts it only for a vehicle that is live and only from a player within fifty metres
- generous, because a bike is left at speed and the ped lands some way from it, and checked at
all so that a client cannot report a position for a vehicle on the other side of the map. That
bounds what a client can do to something it could have done by driving the vehicle there, which
is not damage.

The capture sweep and the despawn read both stay. They are now the second and third ways of
learning something that has usually already been reported.

---

## [1.0.14] - 2026-09-09 (français)

**Un véhicule est enregistré à l'instant où il est garé**, par le client qui le conduisait.

### Le trou

Sortir d'un véhicule persistant ne faisait rien du tout. `worthReporting` répond faux pour un
véhicule que v-park suit déjà - ce qui est correct, ce test sert à décider d'ADOPTER quelque
chose de nouveau - donc rien n'était envoyé, et l'endroit où le véhicule venait d'être laissé
était découvert plus tard par l'un de deux moyens :

- **le balayage de capture périodique**, qui tourne par quarts et peut être à des secondes ;
- **la relecture de pose à la disparition**, qui demande les coordonnées au SERVEUR.

Les deux échouent dans le même cas, et c'est le cas ordinaire : se garer, sortir, partir. Le
balayage n'est pas encore passé, et quand le véhicule quitte le rayon de streaming plus aucun
client ne l'a en portée - donc la lecture serveur ne renvoie rien et la position enregistrée
reste celle **d'avant le trajet**.

Le véhicule revient donc là où il habitait avant, pas là où il a été laissé.

### La correction

Le client qui conduisait est la seule machine qui sait avec certitude où le véhicule a fini, et
la sortie est l'instant où cette réponse cesse de changer. Il envoie donc la pose à ce
moment-là : un petit message, une fois, par véhicule garé.

Le serveur ne l'accepte que pour un véhicule vivant et depuis un joueur à moins de cinquante
mètres. Le balayage et la relecture à la disparition restent en place, comme deuxième et
troisième moyens d'apprendre une chose déjà rapportée la plupart du temps.

---

## [1.0.13] - 2026-09-09

The placement is settled. `/vparkwhere` on 1.0.12 reported 6 mm and 0 mm, and a vehicle had
still moved about five metres from where it was parked - which means the vehicle was exactly
where the database said, and the database had been told the wrong thing.

### A vehicle nobody has driven does not report where it is

Every vehicle near a player is **woken** - that is what makes it drivable before somebody
reaches it - and a woken vehicle is simulated. Simulated on a camber, or nudged by traffic
streaming in beside it, it rolls. The capture sweep read the roll and wrote it down as the new
stored position, and the next restore put the car there, correctly, six millimetres out.

The stored position answers "where did somebody leave this", and **only a person driving it can
change that answer**. Position and rotation are now omitted from a capture entirely until
somebody has sat in the vehicle. The server treats an absent field as "no news" and keeps the
pose the vehicle was parked in.

Everything else is still reported for a woken vehicle: damage, fuel, dirt and modifications all
change without anybody getting in. And the final pose read when a vehicle despawns follows the
same rule - only for one that was driven, not merely woken.

The five-centimetre threshold added in 1.0.11 stays, but it was treating a symptom: it made the
drift smaller per cycle rather than stopping it.

### `/admincar` makes the vehicle persistent

The offer that asks the server "is this vehicle somebody's, and should it be kept" was made once,
when the door closed. That is the wrong and only moment, because **ownership can arrive while
somebody is sitting there**: `/admincar` is run from the driver's seat and writes the row from
under us, and so does a dealership finishing a sale or a mate handing the keys over.

Nothing asked again, so the vehicle became the player's and v-park did not notice until they got
out and the forty-five second settle timer expired. `/admincar` looked like it did nothing and
`/vpark` was the only thing that worked.

The offer now repeats while somebody is seated in a vehicle that is not persisted, every
`Config.Persistence.entryOfferRetrySeconds` - lowered from 60 to 15, because it is one small
event and only while somebody is sitting in a car that is not theirs.

---

## [1.0.13] - 2026-09-09 (français)

Le placement est réglé. `/vparkwhere` sur la 1.0.12 donnait 6 mm et 0 mm, et un véhicule avait
quand même bougé de cinq mètres - ce qui veut dire qu'il était exactement là où la base le
disait, et qu'on avait dit n'importe quoi à la base.

### Un véhicule que personne n'a conduit ne rapporte pas sa position

Tout véhicule proche d'un joueur est **réveillé** - c'est ce qui le rend conduisible avant qu'on
l'atteigne - et un véhicule réveillé est simulé. Sur un dévers, ou bousculé par du trafic qui
apparaît à côté, il roule. La capture lisait ce roulement et l'écrivait comme la nouvelle
position enregistrée.

La position enregistrée répond à « où quelqu'un a-t-il laissé ce véhicule », et **seule une
personne qui le conduit peut changer cette réponse**. Position et rotation sont désormais
totalement omises d'une capture tant que personne ne s'est assis dedans. Le serveur traite un
champ absent comme « rien de neuf » et conserve la pose où le véhicule a été garé.

Tout le reste continue d'être rapporté : dégâts, carburant, saleté et modifications changent
sans que personne ne monte. Et la relecture de pose à la disparition suit la même règle.

### `/admincar` rend bien le véhicule persistant

L'offre qui demande au serveur « ce véhicule appartient-il à quelqu'un, faut-il le conserver »
n'était faite qu'une fois, à la fermeture de la portière. C'est le mauvais moment, et le seul,
car **la propriété peut arriver pendant qu'on est assis** : `/admincar` se tape depuis le siège
conducteur et écrit la ligne sous nos pieds.

Rien ne redemandait, donc le véhicule devenait celui du joueur sans que v-park le remarque avant
qu'il sorte et que le délai de quarante-cinq secondes expire. `/admincar` semblait ne rien faire
et `/vpark` était la seule chose qui marchait.

L'offre est maintenant répétée tant que quelqu'un est assis dans un véhicule non persisté, toutes
les `entryOfferRetrySeconds` - abaissées de 60 à 15.

---

## [1.0.12] - 2026-09-09

Two settings that were answering questions they could not answer. Both are off, and both take a
whole class of wrong behaviour with them.

### A vehicle now always comes back exactly where it was

The placement search is **off by default**. It answers "the saved bay is occupied, where is the
nearest free spot", and 1.0.11 was the fifth release in a row to have reports of vehicles
coming back about a metre from where they were parked. Measured, with `/vparkwhere`:

```
0TL1YS402S8YV  off by 1.250 m   dx +0.000  dy -1.250  dz +0.000
0TL1YSE03933L  off by 1.250 m   dx +1.250  dy +0.000  dz +0.000
```

1250 mm is exactly `Config.Placement.search.step`. That was not drift. That was this feature
working as designed.

**The question is wrong, not the answer.** Ask what can actually be occupying a bay a vehicle
was parked in, and there are only three possibilities:

- **Ambient traffic.** Already handled - `clearAmbient` deletes it before the probe runs. If the
  search is being reached, this was not it.
- **Another of our persisted vehicles.** They coexisted, because both were standing there when
  both were saved. A false positive, and a common one: the box tested is the model's bounding
  box, which includes the mirrors and the exporter's margin, so two cars parked thirty
  centimetres apart overlap in it.
- **A car somebody is driving.** Temporary. It will leave.

In none of those three is moving *our* vehicle the right answer.

1.0.11 tried to fix the second case by ignoring vehicles carrying our statebag. That was correct
and it was not enough: a replicated statebag arrives asynchronously, and several vehicles
restored at once are placed before their neighbours' bags have landed. **A fix that depends on
winning a network race is not a fix.**

A vehicle whose bay is occupied is now placed exactly where it was and left frozen. Two cars
briefly overlapping, both frozen, is a smaller problem than a car that is never where its owner
left it, and the first person to drive one out resolves it.

### `/car` no longer makes a vehicle persistent

Recognising a job vehicle was "there is no owner row and the driver holds a job". The comment
above that rule listed what it catches: a job spawner, a dealership demo, **and an admin
command** - and it treated all three as job vehicles. So on a server where staff hold a job,
which is most of them, every car spawned with `/car` became a permanent row the moment somebody
sat in it.

Nothing about an unregistered vehicle distinguishes a police cruiser taken from the Mission Row
spawner from a Premier an admin conjured. Both are unregistered, both are being driven by
somebody with a job. **The only thing that can tell them apart is a recognisable plate**, which
is what `Config.Ownership.jobPlatePattern` is for.

Without a pattern the question has no answer, so it answers no. Job vehicles are kept on a
server that configures one, and nothing is swept up on a server that does not.

Together with `keysGrantOwnership` going off in 1.0.11, a vehicle is persistent when the
framework says it belongs to somebody - which is what `/admincar` does and what `/car` does not.

---

## [1.0.12] - 2026-09-09 (français)

Deux réglages qui répondaient à des questions auxquelles ils ne pouvaient pas répondre. Les deux
sont désactivés, et chacun emporte avec lui toute une classe de mauvais comportements.

### Un véhicule revient maintenant toujours exactement à sa place

La recherche de placement est **désactivée par défaut**. Elle répond à « la place sauvegardée
est occupée, où est la plus proche libre », et la 1.0.11 était la cinquième version d'affilée
avec des véhicules revenant à un mètre environ de leur place. Mesuré : 1250 mm, soit exactement
`search.step`. Ce n'était pas une dérive, c'était cette fonction qui marchait comme prévu.

**C'est la question qui est mauvaise, pas la réponse.** Ce qui peut occuper une place où un
véhicule était garé se résume à trois cas : du trafic ambiant, déjà supprimé avant la sonde ; un
autre de nos véhicules, qui coexistait donc faux positif ; une voiture conduite par quelqu'un,
donc temporaire. Dans aucun des trois déplacer **notre** véhicule n'est la bonne réponse.

La 1.0.11 avait tenté de corriger le deuxième cas en ignorant les véhicules portant notre
statebag. C'était juste et insuffisant : un statebag répliqué arrive de façon asynchrone, et
plusieurs véhicules restaurés en même temps sont placés avant que les bags de leurs voisins ne
soient arrivés. **Un correctif qui dépend de gagner une course réseau n'est pas un correctif.**

Un véhicule dont la place est occupée est désormais posé exactement où il était, et laissé gelé.

### `/car` ne rend plus un véhicule persistant

Reconnaître un véhicule de métier, c'était « pas de ligne propriétaire et le conducteur a un
métier ». Le commentaire au-dessus de cette règle énumérait ce qu'elle attrape : un spawner de
métier, un essai de concession, **et une commande admin** - et elle traitait les trois comme des
véhicules de métier.

Rien dans un véhicule non enregistré ne distingue une voiture de police d'une Premier invoquée
par un admin. **Seule une plaque reconnaissable le peut**, ce à quoi sert `jobPlatePattern`.
Sans motif, la question n'a pas de réponse, donc elle répond non.

---

## [1.0.11] - 2026-09-09

Fixed from measurements rather than from reasoning. `/vparkwhere`, added in 1.0.10, reported
this on three cars parked together:

```
0TL1XPC029AV2  PREMIER  off by 1.250 m   dx -1.250  dy +0.000  dz +0.000  heading -0.00
0TL1XPN03STI2  PREMIER  off by 0.017 m   dx -0.005  dy +0.016  dz -0.001  heading -0.00
0TL1XP201FY36  PREMIER  off by 0.003 m   dx +0.003  dy +0.001  dz -0.001  heading +0.00
```

Two different faults, and the numbers name both.

### One vehicle moved exactly one search step

1250 mm on a single axis and nothing on the other two is not drift. It is exactly
`Config.Placement.search.step`, which means the probe reported the bay blocked and the search
moved the car one ring outwards - and then `moved` sent that position back to the server, which
saved it.

The blocker was **another one of our own vehicles**. 1.0.8 took map geometry out of this test on
the grounds that it cannot have changed since the vehicle was parked. Our own fleet cannot have
changed either: a persisted vehicle standing at its saved pose was standing there when every
other persisted vehicle nearby was saved. **They coexisted.** Two cars parked in adjacent bays
are not in each other's way and never were - and the box this probe tests is bigger than the
body, because it contains the mirrors and a margin the exporter added, so two cars parked thirty
centimetres apart overlap in it.

**A vehicle carrying one of our ids is no longer a blocker.** What is left is what genuinely can
have arrived: ambient traffic, and cars other players are driving. The check is made where the
overlap is found rather than while the vehicle pool is being read, so it costs a handful of
statebag reads per placement instead of one per vehicle on the street.

### The other two were drifting a few millimetres at a time

Seventeen millimetres and three. Both cars had been restored correctly and then **woken** -
every vehicle near a player is - and a woken vehicle is simulated again, and simulation settles
it. Each of those settlements was being written back as the new stored position, and the next
restore put the car there, and it settled again.

Individually invisible, cumulatively exactly the complaint. **A stored position now changes when
somebody drives the car, not because physics breathed on it**: a capture whose position differs
by less than five centimetres, or whose rotation differs by less than half a degree, leaves the
stored value alone. Both thresholds are below what anybody can see and far above anything
settling produces, and a genuine drive clears them in the first metre.

### A place the search invented is never written down

The two fixes above stop the search being triggered wrongly. This one stops a wrong trigger from
ever becoming permanent.

The search runs when the saved bay is occupied, and it answers with the nearest spot that is
not. **That is a way to avoid two cars overlapping for the next few minutes. It is not where the
vehicle belongs** - and saving it meant the vehicle never went home again, because the invented
spot became the saved spot and the next restore started from there.

A `nudged` placement no longer updates the stored position, and the vehicle is flagged so the
despawn does not write it back either when the player walks away. The car may stand aside until
the obstruction goes, and the database still knows where it lives. A ground correction is still
written, because that is a real correction to a Z that was wrong.

### `/car` no longer makes a vehicle persistent

`Config.Ownership.keysGrantOwnership` is **off**, and the reason it was ever on was a mistake.

1.0.2 turned it on to fix a real report: a car given with `/admincar` was not being kept. The
reasoning was that `/admincar` does not register the vehicle to anybody, so a strict reading of
`mode = 'owned'` would never keep it.

That reasoning was wrong. `/admincar` on qb-core is `qb-adminmenu`'s SaveCar, and its server half
runs `INSERT INTO player_vehicles`. It writes the row. The vehicle is owned by the framework's
own definition and was always going to be kept; nothing needed widening.

What the widening did instead was keep everything else - `/car`, dealership test drives, job
spawners, admin spawn menus - because all of them hand over the keys without registering the
vehicle to anybody. **The framework's register is the authority on who owns a car.** That is
what it is for.

---

## [1.0.11] - 2026-09-09 (français)

Corrigé à partir de mesures et non de raisonnement. `/vparkwhere`, ajouté en 1.0.10, a donné
ceci sur trois voitures garées ensemble : une à **1,250 m** d'écart sur un seul axe, les deux
autres à 17 et 3 millimètres.

### La première avait bougé d'exactement un pas de recherche

1250 mm sur un seul axe et rien sur les deux autres, ce n'est pas une dérive : c'est exactement
`Config.Placement.search.step`. La sonde a donc déclaré la place bloquée et la recherche a
décalé la voiture d'un cran - puis cette position a été renvoyée au serveur et sauvegardée.

Le bloqueur était **un autre de nos propres véhicules**. La 1.0.8 avait sorti la carte de ce
test au motif qu'elle ne peut pas avoir changé depuis que la voiture était garée. Notre propre
flotte non plus : un véhicule persistant à sa pose sauvegardée était déjà là quand tous les
autres ont été sauvegardés. **Ils coexistaient.** Deux voitures dans des places voisines ne se
gênent pas et ne se sont jamais gênées - et la boîte testée est plus grande que la carrosserie.

**Un véhicule portant un de nos identifiants n'est plus un bloqueur.** Reste ce qui peut
réellement être arrivé : le trafic ambiant et les voitures conduites par d'autres joueurs.

### Les deux autres dérivaient de quelques millimètres à chaque fois

Dix-sept millimètres et trois. Les deux avaient été restaurées correctement puis **réveillées** -
tout véhicule près d'un joueur l'est - et un véhicule réveillé est de nouveau simulé, donc il se
tasse. Chacun de ces tassements était réécrit comme la nouvelle position.

Invisible isolément, cumulativement exactement la plainte. **Une position enregistrée ne change
plus que si quelqu'un conduit la voiture** : une capture dont la position diffère de moins de
cinq centimètres, ou dont la rotation diffère de moins d'un demi-degré, laisse la valeur
enregistrée intacte.

### Une place inventée par la recherche n'est jamais enregistrée

Les deux correctifs ci-dessus empêchent la recherche de se déclencher à tort. Celui-ci empêche
un déclenchement à tort de devenir définitif.

La recherche répond avec l'emplacement libre le plus proche. **C'est une façon d'éviter que deux
voitures se chevauchent pendant quelques minutes, ce n'est pas la place du véhicule** - et
l'enregistrer signifiait qu'il ne rentrait plus jamais chez lui, puisque la place inventée
devenait la place sauvegardée.

Un placement décalé ne met plus à jour la position enregistrée, et le véhicule est marqué pour
que la disparition ne la réécrive pas non plus. La voiture peut se ranger à côté le temps que
l'obstacle parte, la base sait toujours où elle habite.

### `/car` ne rend plus un véhicule persistant

`Config.Ownership.keysGrantOwnership` est **désactivé**, et la raison pour laquelle il était
activé était une erreur.

La 1.0.2 l'avait activé pour corriger un vrai signalement : une voiture donnée avec `/admincar`
n'était pas conservée. Le raisonnement était que `/admincar` n'enregistre le véhicule à
personne. C'était faux : `/admincar` sur qb-core exécute `INSERT INTO player_vehicles`. Le
véhicule est possédé au sens du framework et allait de toute façon être conservé.

Ce que l'élargissement a fait, c'est conserver tout le reste - `/car`, les essais de
concessionnaire, les spawners de métier - qui donnent les clés sans enregistrer le véhicule.
**Le registre du framework fait autorité sur qui possède une voiture.**

---

## [1.0.10] - 2026-09-08

**No vehicle came back in quite the right place.** Not some of them - none of them, which is the
shape of a systematic fault rather than an edge case, and it turned out to be one line of
sequencing repeated in four places.

### Fixed

- **A position written to a frozen entity is not reliably applied.**

  `FREEZE_ENTITY_POSITION` fixes an entity's matrix. Every coordinate write in the placement was
  made against an entity that the same file had frozen a few lines earlier - so the freeze was
  holding the matrix that the write was trying to change.

  For most of this resource's life that was survivable, because a restored vehicle was not
  frozen when it arrived: it fell, the placement's freeze was the first one, and the write
  landed. 1.0.7 fixed the falling by freezing the vehicle on arrival through a replicated
  statebag - which was right, and which turned "roughly where it should be" into "wherever the
  server first created it", **on every vehicle**.

  Every pose write now goes through one helper that unfreezes, writes, kills any residual
  velocity and freezes again, with no yield in the window so the vehicle cannot fall through
  it. Four call sites: the placement, the re-assert after collision streams in, the pose hold
  and the ejection watch.

  It also zeroes angular velocity, which a frozen entity otherwise keeps and hands straight
  back the moment it is released - the reason a restored car could twitch when somebody first
  opened its door.

### New

- **`/vparkwhere`** reports, for every restored vehicle this client is tracking, how far it is
  from where the database says it should be - per axis, plus the heading difference, whether it
  is frozen, whether it was dressed, and whether this client owns it. Worst first.

  Five releases of reasoning about "they are not quite in the right place" produced five
  different theories and the same report each time. A number per vehicle per axis ends that
  argument, and it is the fastest way to tell a ground-height problem (`dz` alone) from a
  search that nudged the car (`dx` and `dy`) from a rotation that did not take.

---

## [1.0.10] - 2026-09-08 (français)

**Aucun véhicule ne revenait tout à fait à sa place.** Pas certains : aucun - ce qui est la
signature d'un défaut systématique, et c'en était un : une ligne d'enchaînement, répétée à
quatre endroits.

### Corrigé

- **Une position écrite sur une entité gelée n'est pas appliquée de façon fiable.**
  `FREEZE_ENTITY_POSITION` fige la matrice de l'entité, et toutes les écritures de position du
  placement visaient une entité que ce même fichier avait gelée quelques lignes plus haut.

  Pendant longtemps c'était supportable, parce qu'un véhicule restauré n'était pas gelé à son
  arrivée : il tombait, le gel du placement était le premier, et l'écriture prenait. La 1.0.7 a
  corrigé la chute en gelant le véhicule dès son arrivée - ce qui était juste, et ce qui a
  transformé « à peu près à sa place » en « là où le serveur l'a créé », **sur tous les
  véhicules**.

  Toutes les écritures de pose passent maintenant par un helper unique qui dégèle, écrit,
  annule la vitesse résiduelle et regèle, sans aucun `Wait` dans l'intervalle. Il annule aussi
  la vitesse angulaire, qu'une entité gelée conserve et restitue dès qu'on la libère.

### Nouveau

- **`/vparkwhere`** indique, pour chaque véhicule restauré suivi par ce client, de combien il
  s'écarte de ce que dit la base : par axe, plus l'écart de cap, s'il est gelé, s'il a été
  habillé, et si ce client le possède. Le pire en premier.

---

## [1.0.9] - 2026-09-08

**Vehicles changed colour on their own, and were never quite in the right place.**

### The colour, at last

`SET_VEHICLE_MOD_COLOR_1` and `SET_VEHICLE_COLOURS` write the same paint through two different
APIs, and whichever runs last wins. The apply ran the colours first and the mod colours second,
so the mod colours won - and they were being fed nonsense:

```lua
SetVehicleModColor_1(vehicle, paintType1, color1, 0)
--                            ^ correct   ^ from GetVehicleColours, a different colour space
--                                                ^ a literal zero, wiping the pearlescent
```

`GET_VEHICLE_MOD_COLOR_1` returns **three** values - the paint type, the colour within that
type, and the pearlescent colour - and only the first was ever stored. The other two were filled
in at apply time from somewhere else entirely, so the last thing to touch the paint on every
restored vehicle was a call with two wrong arguments out of three. The pearlescent colour in
particular was reset to 0 on every single restore, immediately after
`SetVehicleExtraColours` had just set it correctly.

Then the capture sweep read that wrong colour off the vehicle and wrote it to the database. That
is why it never settled: each restore was a fresh corruption and each save made it permanent.

**The whole triple is stored now, and applied before the index colours** - which is the order
every other property implementation in the ecosystem uses. `SetVehicleExtraColours` runs last,
so the pearlescent colour is authoritative. The tuning fingerprint samples the paint type too,
so a respray from metallic to matte in the same colour is no longer invisible to the cache.

Rows written before 1.0.9 keep working: a record with only `paintType1` sets the paint type and
leaves the colour to `SetVehicleColours`, rather than inventing the rest.

### Exactly where it was

A vehicle can move by a few centimetres between its coordinates being set and the freeze taking
hold: collision streams in underneath it and the engine resolves the intersection, a vehicle
materialises alongside and pushes it, the suspension settles. None of that is far enough to look
broken and all of it is far enough to look wrong - and once the vehicle is frozen there, that is
where it stays, and the next capture writes it down.

1.0.7 added a check for this. It ran once, **before** the freeze, and only acted past **half a
metre** - which is enormous for something that is supposed to be exact, and before the freeze is
before most of the movement.

**The pose is now re-asserted after the freeze, twice, past two centimetres.** Re-asserting a
pose on a frozen entity costs three natives and nothing else, and the vehicle is then where the
database says it is - not approximately, exactly. Only for vehicles that stay frozen: one handed
back to physics is meant to settle, and holding it would be fighting the thing we just asked
for.

---

## [1.0.9] - 2026-09-08 (français)

**Les véhicules changeaient de couleur tout seuls, et n'étaient jamais tout à fait à leur
place.**

### La couleur, enfin

`SET_VEHICLE_MOD_COLOR_1` et `SET_VEHICLE_COLOURS` écrivent la même peinture par deux API
différentes, et le dernier appelé gagne. L'application posait les couleurs d'abord et les
couleurs de mod ensuite : ces dernières gagnaient donc, et on leur passait n'importe quoi.

`GET_VEHICLE_MOD_COLOR_1` renvoie **trois** valeurs - le type de peinture, la couleur dans ce
type, et la couleur nacrée - et seule la première était enregistrée. Les deux autres étaient
inventées au moment d'appliquer. La couleur nacrée en particulier était remise à 0 à chaque
restauration, juste après avoir été correctement posée.

Puis la capture lisait cette mauvaise couleur sur le véhicule et l'écrivait en base. C'est pour
ça que ça ne se stabilisait jamais : chaque restauration était une nouvelle corruption, et
chaque sauvegarde la rendait définitive.

**Le triplet complet est désormais enregistré et appliqué avant les index de couleur.**
`SetVehicleExtraColours` passe en dernier, donc la couleur nacrée fait autorité.

### Exactement à sa place

Un véhicule peut bouger de quelques centimètres entre la pose de ses coordonnées et la prise du
gel : la collision arrive dessous et le moteur résout l'intersection, un véhicule apparaît à
côté et le pousse, la suspension se tasse. Pas assez pour paraître cassé, bien assez pour
paraître faux - et une fois gelé là, il y reste, et la capture suivante l'enregistre.

La 1.0.7 avait ajouté une vérification. Elle passait une fois, **avant** le gel, et n'agissait
qu'au-delà d'un **demi-mètre**.

**La pose est maintenant réaffirmée après le gel, deux fois, au-delà de deux centimètres.** Le
véhicule est alors là où la base dit qu'il est - pas approximativement, exactement.

---

## [1.0.8] - 2026-09-08

**Vehicles came back floating in the air, or several metres from where they were parked, in
places with plenty of room.** Two shipped defaults were wrong, and together they were much worse
than either alone.

### The two settings

**`Config.Placement.probe.blockedBy.world` was `true`.** The probe traced the vehicle's
footprint through the map to see whether anything was in the way.

It cannot be. **The vehicle was parked at that exact pose, so the map allowed it, and the map is
byte for byte the same map now.** Testing world geometry can therefore only ever produce a false
positive - and the false positives were not rare, because the probe runs at roughly forty
centimetres above the road and a kerb, a sloped driveway, a speed bump or a garage threshold is
taller than that. Every car parked against a kerb reported blocked.

**`Config.Placement.search.verticalRetry` was `3.5`.** When the probe reported blocked, the very
first candidate the search tried was the saved position three and a half metres higher.

Nothing is ever in the way three and a half metres above a parked car, so the probe called it
clear, the vehicle was placed there, `freezeUntilTouched` froze it, and `moved` sent the
airborne position back to the server to be **saved as the truth**. Nothing in the entire path
would ever bring it down again.

### Fixed

- **The world probe is off by default**, for the reason above. So is the object probe, at lower
  confidence: a prop genuinely can appear where one was not before, but a car overlapping a
  wheelie bin resolves itself the moment somebody drives it, and a car three metres in the air
  never resolves at all. Vehicles remain probed, through the entity pool, because ambient
  traffic really does park in the bay while the server is empty.

- **The vertical retry is off.** It was written for a vehicle saved mid-fall in a multi-storey
  car park, whose stored Z was a floor out. That case stopped happening in 1.0.7, when a
  restored vehicle began being frozen by a replicated statebag the instant it reaches any
  client - it cannot fall while it is being saved, so its Z cannot drift by a floor. The
  justification was gone and the failure mode was severe.

- **The ground check corrects downwards as well as up.** It only ever pushed a buried vehicle
  up; a vehicle above the ground was left alone on the reasoning that it might be on a ramp or a
  roof - and `GetGroundZFor_3dCoord` already answers with the ramp or the roof, so that
  reasoning was wrong. It now knows where each model's origin sits when its wheels are on the
  ground - about 0.6 m for a saloon, over a metre for a truck, read from the model rather than
  assumed - and anything more than `groundTolerance` above that is brought down.

  It also runs again over whatever the search finally chose, not only over the saved pose. That
  is what makes "no vehicle is ever left floating" a property of the code rather than of the
  configuration.

- **`tools/check.py` fails the build if either default drifts back.**

---

## [1.0.8] - 2026-09-08 (français)

**Les véhicules revenaient en l'air, ou à plusieurs mètres de leur place, à des endroits où il y
avait largement la place.** Deux valeurs par défaut étaient mauvaises, et ensemble bien pires
que séparément.

### Les deux réglages

**`blockedBy.world` valait `true`.** La sonde traçait l'empreinte du véhicule à travers la carte
pour voir si quelque chose gênait. C'est impossible : **le véhicule était garé exactement là, la
carte l'autorisait donc, et c'est la même carte aujourd'hui.** Ce test ne peut produire que des
faux positifs - et pas rarement, puisque la sonde travaille à environ quarante centimètres
au-dessus de la route et qu'une bordure de trottoir, une pente, un ralentisseur ou un seuil de
garage sont plus hauts que ça.

**`verticalRetry` valait `3.5`.** Quand la sonde disait « bloqué », le tout premier candidat
essayé était la position sauvegardée **trois mètres et demi plus haut**. Rien ne gêne jamais
là-haut, donc « libre », donc le véhicule y était posé, gelé, et cette position en l'air était
**renvoyée au serveur et sauvegardée comme la vérité**. Plus rien ne le redescendait jamais.

### Corrigé

- **La sonde du monde est désactivée par défaut**, pour la raison ci-dessus. Celle des objets
  aussi : une voiture qui chevauche une poubelle se règle dès qu'on la conduit, une voiture à
  trois mètres du sol ne se règle jamais. Les véhicules restent détectés, via le pool
  d'entités, parce que le trafic ambiant se gare vraiment sur la place.
- **La reprise verticale est désactivée.** Le cas pour lequel elle avait été écrite n'existe
  plus depuis la 1.0.7.
- **La correction au sol fonctionne aussi vers le bas.** Elle connaît maintenant, modèle par
  modèle, la hauteur à laquelle l'origine se trouve quand les roues touchent le sol, et elle
  repasse sur la position finalement choisie par la recherche, pas seulement sur la position
  sauvegardée.
- **`tools/check.py` fait échouer le build si l'un des deux réglages revient en arrière.**

---

## [1.0.7] - 2026-09-08

**Vehicles came back under the map, a few metres from where they were parked, and the wrong
colour.** Two causes, and both are about doing something to an entity before it was ours to
touch.

### Fixed

- **A restored vehicle fell through the map before anything could stop it.**

  A server-created entity is simulated by a client from the moment it arrives, and the
  collision around it may not have streamed in yet. So it falls - and by the time the ground
  exists, the vehicle is beneath it.

  The placement pass freezes it, but that runs after waiting for the entity, after the model
  check and after the properties: seconds later. The vehicle has already gone through the floor
  by then, and the placement then carefully positions something that is somewhere else
  entirely - which is also why it landed a few metres off rather than exactly below.

  The server now sets a **`vpark:hold` statebag as part of the same replicated write that
  carries the vehicle's id**, and every client freezes the entity the moment that bag lands.
  Every client, not just the one the server nominated, because any of them may be the one
  simulating the fall. The hold is released when the vehicle is placed, when the placement is
  given up on, and when somebody gets in - so it can never freeze a car under its driver.

  A last check after the settle delay puts a vehicle back if it moved more than half a metre
  while nobody was looking.

- **The colours were being written into the void.**

  `SetVehicleColours`, `SetVehicleMod` and every other property native applied to an entity the
  client does not own are applied LOCALLY and then overwritten by the owner's next
  synchronisation. The car looks right for a moment on the machine that dressed it, and is
  stock everywhere else - including for the player standing next to it.

  Network control was requested inside the placement, which runs *after* the properties. So on
  any vehicle where the request took a moment - which is most of them, because a freshly
  created server entity has no owner yet - the entire dress went nowhere. And the next capture
  read a stock car and wrote that over the real one.

  **Control is taken before a single property is written.** A restore that cannot get control
  is not attempted at all: the vehicle stays exactly where it is, held frozen, and the server
  asks again in four seconds, up to three times. Accepting a half-restore would mean accepting
  a stock car and then saving it.

---

## [1.0.7] - 2026-09-08 (français)

**Les véhicules revenaient sous la carte, à quelques mètres de leur place, et avec la mauvaise
couleur.** Deux causes, et les deux consistent à agir sur une entité avant qu'elle ne soit à
nous.

### Corrigé

- **Un véhicule restauré tombait à travers la carte avant que quoi que ce soit ne l'arrête.**
  Une entité créée par le serveur est simulée par un client dès son arrivée, et la collision
  autour d'elle n'est pas forcément chargée. Elle tombe, et quand le sol arrive elle est
  dessous. Le placement la gèle, mais des secondes plus tard : elle a déjà traversé le sol, et
  le placement positionne alors soigneusement quelque chose qui est ailleurs - d'où aussi les
  quelques mètres d'écart.

  Le serveur pose maintenant un statebag **`vpark:hold`** dans la même écriture répliquée que
  l'identifiant du véhicule, et chaque client gèle l'entité dès que ce bag arrive. Chaque
  client, pas seulement celui désigné, parce que n'importe lequel peut être celui qui simule la
  chute. Le hold est levé une fois le véhicule placé, quand on renonce à le placer, et dès que
  quelqu'un monte dedans.

  Une dernière vérification après le délai de stabilisation remet le véhicule en place s'il a
  bougé de plus d'un demi-mètre.

- **Les couleurs étaient écrites dans le vide.** Les natifs de propriétés appliqués à une
  entité que le client ne possède pas sont appliqués **localement** puis écrasés par la
  synchronisation du propriétaire. La voiture est correcte un instant sur la machine qui l'a
  habillée, et d'origine partout ailleurs. Le contrôle réseau était demandé dans le placement,
  qui s'exécute **après** les propriétés : sur la plupart des véhicules, tout l'habillage
  partait donc à la poubelle - et la capture suivante écrivait cette voiture d'origine
  par-dessus la vraie.

  **Le contrôle est pris avant la première propriété.** Une restauration qui ne l'obtient pas
  n'est pas tentée : le véhicule reste exactement où il est, gelé, et le serveur redemande
  quatre secondes plus tard, jusqu'à trois fois.

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
