--[[
    locales/fr.lua

    Français.

    Key-for-key identical to `en.lua`, with matching format specifiers. `tools/check.py`
    enforces both: a key missing here falls back to English, which is survivable, but a `%d`
    here where English has a `%s` is a crash for every French-speaking player and nobody else,
    which is the kind of bug that survives a whole release.

    The file is UTF-8 WITHOUT a byte order mark. A BOM breaks the Lua parse, and the check
    script fails on one - see ERROR_LOG.md.
]]

Locale.register('fr', {

    -- ---------------------------------------------------------------------------------
    -- Classes de véhicules
    -- ---------------------------------------------------------------------------------
    ['class.compact']      = 'Citadine',
    ['class.sedan']        = 'Berline',
    ['class.suv']          = 'SUV',
    ['class.coupe']        = 'Coupé',
    ['class.muscle']       = 'Muscle',
    ['class.classic']      = 'Sportive classique',
    ['class.sports']       = 'Sportive',
    ['class.super']        = 'Super',
    ['class.motorcycle']   = 'Moto',
    ['class.offroad']      = 'Tout-terrain',
    ['class.industrial']   = 'Industriel',
    ['class.utility']      = 'Utilitaire',
    ['class.van']          = 'Fourgon',
    ['class.cycle']        = 'Vélo',
    ['class.boat']         = 'Bateau',
    ['class.helicopter']   = 'Hélicoptère',
    ['class.plane']        = 'Avion',
    ['class.service']      = 'Service',
    ['class.emergency']    = 'Urgences',
    ['class.military']     = 'Militaire',
    ['class.commercial']   = 'Commercial',
    ['class.train']        = 'Train',
    ['class.openwheel']    = 'Monoplace',

    ['vehicle.unknown']    = 'ce véhicule',
    ['garage.default']     = 'votre garage',

    -- ---------------------------------------------------------------------------------
    -- Refus
    -- ---------------------------------------------------------------------------------
    ['refuse.unknown']              = "Ce véhicule ne peut pas être conservé.",
    ['refuse.disabled']             = "La persistance des véhicules est désactivée sur ce serveur.",
    ['refuse.gone']                 = "Ce véhicule n'existe plus.",
    ['refuse.class_excluded']       = "Ce type de véhicule n'est jamais conservé.",
    ['refuse.model_excluded']       = "Ce modèle n'est jamais conservé.",
    ['refuse.model_not_whitelisted']= "Seuls certains modèles sont conservés, et celui-ci n'en fait pas partie.",
    ['refuse.plate_excluded']       = "Cette plaque n'est jamais conservée.",
    ['refuse.wrecked']              = "Ce véhicule est trop endommagé pour être conservé.",
    ['refuse.zone']                 = "Les véhicules ne sont pas conservés ici (%s).",
    ['refuse.not_owned']            = "Seuls les véhicules qui vous appartiennent sont conservés sur ce serveur.",
    ['refuse.not_claimed']          = "Garez-le d'abord pour qu'il soit conservé.",
    ['refuse.ambient_disabled']     = "Les véhicules que personne n'a conduits ne sont pas conservés.",
    ['refuse.in_garage']            = "Ce véhicule est indiqué comme étant au garage.",
    ['refuse.server_full']          = "Le serveur conserve déjà autant de véhicules qu'il le peut.",
    ['refuse.your_limit']           = "Vous conservez déjà le nombre maximum de véhicules autorisé.",

    -- ---------------------------------------------------------------------------------
    -- Erreurs
    -- ---------------------------------------------------------------------------------
    ['error.no_permission']         = "Vous n'avez pas la permission de faire cela.",
    ['error.console_only']          = "Cette commande ne fonctionne que depuis la console du serveur.",
    ['error.in_game_only']          = "Cette commande ne fonctionne qu'en jeu.",
    ['error.not_ready']             = "v-park est encore en cours de démarrage.",
    ['error.command_failed']        = "La commande a échoué. Le détail est dans la console.",
    ['error.unknown_vehicle']       = "Aucun véhicule ne correspond à cet identifiant ou à cette plaque.",
    ['error.not_yours']             = "Ce véhicule ne vous appartient pas.",
    ['error.no_vehicle']            = "Montez dans un véhicule, ou regardez-en un.",
    ['error.character_not_loaded']  = "Votre personnage n'est pas encore chargé.",
    ['error.no_ped']                = "Votre personnage est introuvable.",
    ['error.no_such_player']        = "Aucun joueur connecté ne porte cet identifiant.",
    ['error.not_in_world']          = "Ce véhicule n'a pas pu être fait apparaître.",
    ['error.not_owned_no_garage']   = "Ce véhicule n'a pas de propriétaire, donc pas de garage où aller.",
    ['error.no_garage_support']     = "Ce framework n'a pas de colonne de garage où écrire.",
    ['error.garage_failed']         = "Le garage a refusé ce véhicule.",
    ['error.panel_disabled']        = "Le panneau admin est désactivé dans la configuration.",
    ['error.unknown_action']        = "Cette action n'est pas proposée par le panneau.",
    ['error.action_disabled']       = "Cette action est désactivée dans la configuration.",
    ['error.unknown']               = "Quelque chose s'est mal passé.",
    ['error.no_database']           = "Cela nécessite une base de données, et aucune n'est connectée.",
    ['error.not_in_trash']          = "Rien dans la corbeille ne porte cet identifiant.",
    ['error.corrupt']               = "Cette entrée de corbeille est illisible.",
    ['error.already_present']       = "Ce véhicule existe déjà et n'a pas été restauré une seconde fois.",

    -- ---------------------------------------------------------------------------------
    -- Notifications
    -- ---------------------------------------------------------------------------------
    ['notify.parked']               = "Ce véhicule sera toujours là après un redémarrage.",
    ['notify.parked_detail']        = "Conservation de %s (%s). Il sera toujours là après un redémarrage.",
    ['notify.forgotten']            = "Ce véhicule ne sera plus conservé. Il est encore là pour l'instant.",
    ['notify.saved']                = "Sauvegarde de %s.",
    ['notify.removed']              = "%s (%s) a été retiré.",
    ['notify.impounded']            = "%s (%s) a été mis en fourrière.",
    ['notify.returned']             = "%s (%s) a été renvoyé dans votre garage.",
    ['notify.expiring']             = "%s sera retiré dans %s si vous ne l'utilisez pas.",
    ['notify.semi_expiring']        = "%s sera retiré dans %s maintenant que vous êtes absent.",
    ['notify.evicted']              = "Votre plus ancien véhicule conservé, %s, a été retiré pour faire de la place.",
    ['notify.cleanup_due']          = "%s n'a pas été conduit depuis un moment et retourne au garage dans %s.",
    ['notify.cleanup_moved']        = "%s n'a pas été conduit depuis longtemps et a été renvoyé à %s.",
    ['notify.given_vehicle']        = "On vous a donné %s.",
    ['notify.sent_to_garage']       = "%s a été envoyé à %s par le staff.",
    ['notify.waypoint_set']         = "Point de passage placé sur %s (%s).",
    ['notify.flushed']              = "%d véhicule(s) écrit(s) en base de données.",

    ['notify.teleported_to']        = "Téléporté jusqu'au véhicule.",
    ['notify.brought_here']         = "Le véhicule a été amené jusqu'à vous.",
    ['notify.repaired']             = "Le véhicule a été réparé.",
    ['notify.cleaned']              = "Le véhicule a été nettoyé.",
    ['notify.refuelled']            = "Le véhicule a été ravitaillé.",
    ['notify.locked']               = "Le véhicule a été verrouillé.",
    ['notify.unlocked']             = "Le véhicule a été déverrouillé.",
    ['notify.owner_set']            = "Le propriétaire a été changé.",
    ['notify.renamed']              = "Le véhicule a été renommé.",
    ['notify.deleted']              = "Le véhicule a été retiré. Il est récupérable depuis la corbeille.",
    ['notify.impounded_ok']         = "Le véhicule a été mis en fourrière.",
    ['notify.returned_ok']          = "Le véhicule a été renvoyé dans son garage.",
    ['notify.sent_to_garage_ok']    = "Le véhicule a été envoyé au garage.",
    ['notify.restored']             = "Le véhicule a été restauré depuis la corbeille.",

    -- ---------------------------------------------------------------------------------
    -- /vparkinfo
    -- ---------------------------------------------------------------------------------
    ['info.header']        = "v-park %s par vyrriox",
    ['info.framework']     = "framework : %s (%s)",
    ['info.database']      = "base de données : %s, tables préfixées %s",
    ['info.keys']          = "clés : %s",
    ['info.mode']          = "mode de persistance : %s",
    ['info.counts']        = "%d conservés, %d dans le monde, %d en attente d'écriture, %d cellules",
    ['info.zones']         = "%d zone(s) bloquée(s)",
    ['info.memory_mode']   = "EN MÉMOIRE : rien ne survit à un redémarrage du serveur",
    ['info.garages']       = "garages : %s (%d trouvés)",
    ['info.webhooks']      = "webhooks : erreurs %s, staff %s, activité %s",

    -- ---------------------------------------------------------------------------------
    -- /vparkstats
    -- ---------------------------------------------------------------------------------
    ['stats.header']       = "v-park, en ce moment :",
    ['stats.store']        = "registre : %d conservés, %d actifs, %d en attente, %d cellules",
    ['stats.spawn']        = "streaming : %d créés, %d retirés, %d échecs, dernier passage %d ms",
    ['stats.placement']    = "placement : %d exacts, %d décalés, %d forcés, %d au sol",
    ['stats.persist']      = "sauvegarde : %d lignes, %d lots, %d captures, dernière écriture %d ms",
    ['stats.database']     = "base : %d requêtes, %d écritures, %d erreurs, %s ms de moyenne, %d ms au pire",
    ['stats.lifecycle']    = "cycle de vie : %d expirés, %d propriétaire absent, %d nettoyés, %d évincés, %d supprimés ailleurs",

    -- ---------------------------------------------------------------------------------
    -- /vparklist
    -- ---------------------------------------------------------------------------------
    ['list.empty']         = "Vous ne conservez aucun véhicule.",
    ['list.header']        = "Vous conservez %d véhicule(s) :",
    ['list.row']           = "%s  %s (%s)  dernier contact il y a %s%s",
    ['list.grace']         = "  [part dans %s]",
    ['list.truncated']     = "... et %d de plus.",

    -- ---------------------------------------------------------------------------------
    -- /vparkscan
    -- ---------------------------------------------------------------------------------
    ['scan.empty']         = "Aucun véhicule conservé dans un rayon de %d mètres.",
    ['scan.header']        = "%d véhicule(s) conservé(s) dans un rayon de %d mètres :",
    ['scan.row']           = "%s  %s (%s)  %dm  %s  %s",
    ['scan.in_world']      = "dans le monde",
    ['scan.stored']        = "non chargé",

    -- ---------------------------------------------------------------------------------
    -- /vparkzones
    -- ---------------------------------------------------------------------------------
    ['zones.empty']        = "Aucune zone bloquée n'est configurée.",
    ['zones.header']       = "%d zone(s) bloquée(s) :",
    ['zones.row']          = "%s  [%s]  depuis %s",

    -- ---------------------------------------------------------------------------------
    -- Garages
    -- ---------------------------------------------------------------------------------
    ['garages.header']     = "%s signale %d garage(s) :",
    ['garages.row']        = "%s  %s",
    ['garages.none']       = "Aucune liste de garages n'a pu être lue depuis une ressource de garage installée.",
    ['garages.none_hint']  = "Renseignez Config.Panel.garages et Config.Cleanup.fallbackGarage à la main.",

    -- ---------------------------------------------------------------------------------
    -- Nettoyage
    -- ---------------------------------------------------------------------------------
    ['cleanup.none']           = "Aucun véhicule n'a besoin d'être nettoyé.",
    ['cleanup.preview_header'] = "%d véhicule(s) seraient nettoyés :",
    ['cleanup.row']            = "%s  %s  inactif %s  -> %s",
    ['cleanup.done']           = "%d véhicule(s) ont été nettoyés.",
    ['cleanup.usage']          = "utilisation : cleanup preview | cleanup run",

    -- ---------------------------------------------------------------------------------
    -- Purge et effacement
    -- ---------------------------------------------------------------------------------
    ['purge.usage']        = "utilisation : purge <idle:jours | type:catégorie | model:nom | wrecked> [confirm]",
    ['purge.none']         = "Rien ne correspond à %s.",
    ['purge.preview']      = "%d véhicule(s) correspondent à %s. Rien n'a été modifié.",
    ['purge.confirm_hint'] = "Ajoutez 'confirm' pour les retirer réellement : purge %s confirm",
    ['purge.done']         = "%d véhicule(s) correspondant à %s ont été retirés.",

    ['wipe.warning']       = "Cela retirera les %d véhicules conservés. Il n'y a pas de retour possible au-delà de la corbeille.",
    ['wipe.confirm']       = "Exécutez : %s %s   (valable 60 secondes)",
    ['wipe.done']          = "%d véhicule(s) effacé(s).",

    -- ---------------------------------------------------------------------------------
    -- Débogage et sonde
    -- ---------------------------------------------------------------------------------
    ['debug.on']           = "Journalisation de débogage activée (niveau %s).",
    ['debug.off']          = "Journalisation de débogage désactivée.",
    ['debug.overlay_on']   = "Superposition de débogage v-park activée.",
    ['debug.overlay_off']  = "Superposition de débogage v-park désactivée.",
    ['probe.no_model']     = "Aucun véhicule à sonder. Montez dedans, ou regardez-en un.",
    ['probe.no_dimensions']= "Ce modèle n'a pas de dimensions que le jeu accepte de donner.",
    ['probe.free']         = "La place est libre. Un véhicule serait placé exactement ici.",
    ['probe.blocked']      = "La place est bloquée par %s. Le détail est dans la console.",

    ['reconcile.done']       = "%d véhicule(s) parasite(s) retiré(s) du monde.",
    ['admin.usage']        = "utilisation : admin | admin garages | admin reconcile | admin cleanup preview | admin cleanup run",

    -- ---------------------------------------------------------------------------------
    -- Le panneau
    -- ---------------------------------------------------------------------------------
    ['panel.title']        = "V-PARK",
    ['panel.subtitle']     = "Registre des véhicules",
    ['panel.search']       = "Rechercher plaque, modèle, propriétaire ou id",
    ['panel.close']        = "Fermer",

    ['panel.filter_all']     = "Tous",
    ['panel.filter_near']    = "Près de moi",
    ['panel.filter_live']    = "Dans le monde",
    ['panel.filter_idle']    = "Inactifs",
    ['panel.filter_wrecked'] = "Épaves",
    ['panel.filter_semi']    = "Semi-persistants",
    ['panel.filter_owned']   = "Possédés",
    ['panel.filter_job']     = "Métier",
    ['panel.filter_unowned'] = "Sans propriétaire",
    ['panel.filter_broken']  = "Modèle manquant",

    ['panel.sort_recent']   = "Plus récents",
    ['panel.sort_distance'] = "Plus proches",
    ['panel.sort_idle']     = "Inactifs le plus longtemps",
    ['panel.sort_plate']    = "Plaque",
    ['panel.sort_model']    = "Modèle",

    ['panel.col_vehicle'] = "Véhicule",
    ['panel.col_owner']   = "Propriétaire",
    ['panel.col_where']   = "Où",
    ['panel.col_state']   = "État",
    ['panel.col_actions'] = "Actions",

    ['panel.act_goto']    = "S'y rendre",
    ['panel.act_bring']   = "Faire venir",
    ['panel.act_mark']    = "Point GPS",
    ['panel.act_repair']  = "Réparer",
    ['panel.act_clean']   = "Nettoyer",
    ['panel.act_refuel']  = "Ravitailler",
    ['panel.act_unlock']  = "Déverrouiller",
    ['panel.act_garage']  = "Vers garage",
    ['panel.act_impound'] = "Fourrière",
    ['panel.act_delete']  = "Supprimer",
    ['panel.act_rename']  = "Renommer",
    ['panel.act_owner']   = "Propriétaire",

    ['panel.tab_vehicles'] = "Véhicules",
    ['panel.tab_trash']    = "Corbeille",
    ['panel.tab_cleanup']  = "Nettoyage",

    ['panel.trash_empty']   = "La corbeille est vide.",
    ['panel.trash_restore'] = "Restaurer",
    ['panel.cleanup_run']   = "Lancer le nettoyage",
    ['panel.cleanup_empty'] = "Rien à nettoyer.",
    ['panel.cleanup_note']  = "Ces véhicules n'ont pas été conduits depuis plus longtemps que la période d'inactivité configurée. Lancer le nettoyage renvoie les véhicules possédés dans un garage et ne les supprime pas.",

    ['panel.in_world']   = "Dans le monde",
    ['panel.stored']     = "Stocké",
    ['panel.wrecked']    = "Épave",
    ['panel.idle_due']   = "Dû",
    ['panel.no_results'] = "Rien ne correspond.",
    ['panel.page']       = "Page",
    ['panel.of']         = "sur",
    ['panel.total']      = "au total",

    ['panel.confirm']        = "Confirmer",
    ['panel.cancel']         = "Annuler",
    ['panel.confirm_delete'] = "Supprimer ce véhicule ? Il sera récupérable depuis la corbeille.",
    ['panel.choose_garage']  = "Envoyer vers quel garage ?",
    ['panel.rename_prompt']  = "Nouveau nom pour ce véhicule",
    ['panel.owner_prompt']   = "Identifiant serveur du nouveau propriétaire",
    ['panel.refuel_prompt']  = "Niveau de carburant, 0 à 100",

    ['panel.summary_total']   = "Conservés",
    ['panel.summary_live']    = "Dans le monde",
    ['panel.summary_pending'] = "En attente d'écriture",

    ['panel.filter_online']  = "Propriétaire connecté",
    ['panel.filter_offline'] = "Propriétaire absent",

    ['panel.act_detail']     = "Détails",

    ['panel.selected']       = "%d sélectionné(s)",
    ['panel.select_all']     = "Sélectionner la page",
    ['panel.clear_selection']= "Effacer",
    ['panel.bulk_done']      = "%d effectué(s), %d en échec.",
    ['panel.bulk_too_many']  = "Sélectionnez au plus %d véhicules à la fois.",
    ['panel.confirm_bulk']   = "Appliquer « %s » aux %d véhicules sélectionnés ?",

    ['panel.owner_online']   = "connecté",
    ['panel.owner_offline']  = "absent",

    ['panel.detail_title']   = "Détail du véhicule",
    ['panel.detail_fitted']  = "Équipements",
    ['panel.detail_damage']  = "Dégâts",
    ['panel.detail_timing']  = "Chronologie",
    ['panel.detail_colours'] = "Couleurs",
    ['panel.detail_none']    = "Rien d'enregistré.",
    ['panel.detail_created'] = "Créé",
    ['panel.detail_updated'] = "Écrit",
    ['panel.detail_touched'] = "Contact",
    ['panel.detail_used']    = "Dernière conduite",
    ['panel.detail_source']  = "Origine",
    ['panel.detail_netid']   = "Id réseau",

    ['panel.matched']        = "correspondant(s)",
    ['panel.shortcuts']      = "Raccourcis : / rechercher, R actualiser, A sélectionner la page, ÉCHAP fermer",

    ['panel.grace']      = "Part dans",
    ['panel.idle']       = "Inactif",
    ['panel.never_used'] = "Jamais conduit",

    -- ---------------------------------------------------------------------------------
    -- Interaction optionnelle
    -- ---------------------------------------------------------------------------------
    ['interaction.park'] = "Se garer ici",
})
