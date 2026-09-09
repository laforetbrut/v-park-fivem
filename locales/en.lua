--[[
    locales/en.lua

    English. THE BASE LANGUAGE.

    Every other locale is read against this one: a key missing from another file falls back to
    the entry here, so this file must contain every key the resource uses and no other file
    needs to. `tools/check.py` asserts that every locale is key-for-key identical to this one
    and that the format specifiers match, because a `%s` here and a `%d` in the French is a
    crash in whichever language nobody tested.

    Loaded FIRST in fxmanifest.lua for that reason.
]]

Locale.register('en', {

    -- ---------------------------------------------------------------------------------
    -- Vehicle classes
    -- ---------------------------------------------------------------------------------
    ['class.compact']      = 'Compact',
    ['class.sedan']        = 'Sedan',
    ['class.suv']          = 'SUV',
    ['class.coupe']        = 'Coupe',
    ['class.muscle']       = 'Muscle',
    ['class.classic']      = 'Sports classic',
    ['class.sports']       = 'Sports',
    ['class.super']        = 'Super',
    ['class.motorcycle']   = 'Motorcycle',
    ['class.offroad']      = 'Off-road',
    ['class.industrial']   = 'Industrial',
    ['class.utility']      = 'Utility',
    ['class.van']          = 'Van',
    ['class.cycle']        = 'Cycle',
    ['class.boat']         = 'Boat',
    ['class.helicopter']   = 'Helicopter',
    ['class.plane']        = 'Plane',
    ['class.service']      = 'Service',
    ['class.emergency']    = 'Emergency',
    ['class.military']     = 'Military',
    ['class.commercial']   = 'Commercial',
    ['class.train']        = 'Train',
    ['class.openwheel']    = 'Open wheel',

    ['vehicle.unknown']    = 'that vehicle',
    ['garage.default']     = 'your garage',

    -- ---------------------------------------------------------------------------------
    -- Refusals
    --
    -- Every one of these answers "why was my car not kept". They are worth writing
    -- carefully: a player who gets a specific reason stops asking, and one who gets
    -- "no" asks in Discord.
    -- ---------------------------------------------------------------------------------
    ['refuse.unknown']              = 'That vehicle cannot be kept.',
    ['refuse.disabled']             = 'Vehicle persistence is switched off on this server.',
    ['refuse.gone']                 = 'That vehicle no longer exists.',
    ['refuse.already_ours']         = 'That vehicle is already kept by v-park.',
    ['refuse.class_excluded']       = 'This kind of vehicle is never kept.',
    ['refuse.model_excluded']       = 'This model is never kept.',
    ['refuse.model_not_whitelisted']= 'Only certain models are kept, and this is not one.',
    ['refuse.plate_excluded']       = 'This plate is never kept.',
    ['refuse.wrecked']              = 'This vehicle is too damaged to be kept.',
    ['refuse.zone']                 = 'Vehicles are not kept here (%s).',
    ['refuse.not_owned']            = 'Only vehicles you own are kept on this server.',
    ['refuse.not_claimed']          = 'Park it first to have it kept.',
    ['refuse.ambient_disabled']     = 'Vehicles nobody has driven are not kept.',
    ['refuse.in_garage']            = 'That vehicle is listed as being in a garage.',
    ['refuse.server_full']          = 'The server is holding as many vehicles as it can.',
    ['refuse.no_plate']             = 'That vehicle has no readable plate.',
    ['refuse.owned_immediately_off'] = 'Owned vehicles are not kept on entry on this server.',
    ['refuse.position_mismatch']    = 'That vehicle is not where the message said it was (%s).',
    ['refuse.your_limit']           = 'You are keeping as many vehicles as you are allowed.',

    -- ---------------------------------------------------------------------------------
    -- Errors
    -- ---------------------------------------------------------------------------------
    ['error.no_permission']         = 'You do not have permission to do that.',
    ['error.console_only']          = 'That command only works from the server console.',
    ['error.in_game_only']          = 'That command only works in game.',
    ['error.not_ready']             = 'v-park is still starting up.',
    ['error.command_failed']        = 'That command failed. The console has the detail.',
    ['error.unknown_vehicle']       = 'No vehicle matches that id or plate.',
    ['error.not_yours']             = 'That is not your vehicle.',
    ['error.no_vehicle']            = 'Get into a vehicle, or look at one.',
    ['error.character_not_loaded']  = 'Your character is not loaded yet.',
    ['error.no_ped']                = 'Your character could not be found.',
    ['error.no_such_player']        = 'No player is online with that id.',
    ['error.not_in_world']          = 'That vehicle could not be brought into the world.',
    ['error.not_owned_no_garage']   = 'That vehicle has no owner, so it has no garage to go to.',
    ['error.no_garage_support']     = 'This framework has no garage column to write to.',
    ['error.garage_failed']         = 'The garage would not accept that vehicle.',
    ['error.panel_disabled']        = 'The admin panel is switched off in the config.',
    ['error.unknown_action']        = 'That is not an action the panel offers.',
    ['error.action_disabled']       = 'That action is switched off in the config.',
    ['error.unknown']               = 'Something went wrong.',
    ['error.no_database']           = 'That needs a database, and none is connected.',
    ['error.not_in_trash']          = 'Nothing in the trash has that id.',
    ['error.corrupt']               = 'That trash entry could not be read.',
    ['error.already_present']       = 'That vehicle already exists and was not restored again.',

    -- ---------------------------------------------------------------------------------
    -- Notifications
    -- ---------------------------------------------------------------------------------
    ['notify.parked']               = 'This vehicle will still be here after a restart.',
    ['notify.parked_detail']        = 'Keeping %s (%s). It will still be here after a restart.',
    ['notify.forgotten']            = 'This vehicle will no longer be kept. It is still here for now.',
    ['notify.saved']                = 'Saved %s.',
    ['notify.removed']              = '%s (%s) was removed.',
    ['notify.impounded']            = '%s (%s) was impounded.',
    ['notify.returned']             = '%s (%s) was returned to your garage.',
    ['notify.expiring']             = '%s will be removed in %s unless you use it.',
    ['notify.semi_expiring']        = '%s will be removed in %s now that you are away.',
    ['notify.evicted']              = 'Your oldest kept vehicle, %s, was dropped to make room.',
    ['notify.cleanup_due']          = '%s has not been driven for a while and goes back to a garage in %s.',
    ['notify.cleanup_moved']        = '%s was not driven for a long time and was returned to %s.',
    ['notify.given_vehicle']        = 'You were given %s.',
    ['notify.sent_to_garage']       = '%s was moved to %s by staff.',
    ['notify.waypoint_set']         = 'Waypoint set to %s (%s).',
    ['notify.flushed']              = '%d vehicle(s) written to the database.',

    ['notify.teleported_to']        = 'Teleported to the vehicle.',
    ['notify.brought_here']         = 'The vehicle was brought to you.',
    ['notify.repaired']             = 'The vehicle was repaired.',
    ['notify.cleaned']              = 'The vehicle was cleaned.',
    ['notify.refuelled']            = 'The vehicle was refuelled.',
    ['notify.locked']               = 'The vehicle was locked.',
    ['anchor.dropped']              = 'Anchor down. This boat will stay where it is.',
    ['anchor.raised']               = 'Anchor up.',
    ['anchor.no_vehicle']           = 'Get into the boat you want to anchor.',
    ['anchor.wrong_class']          = 'This vehicle has no anchor.',
    ['anchor.not_kept']             = 'That vehicle is not kept by v-park, so an anchor would not survive a restart.',
    ['anchor.disabled']             = 'Anchors are switched off on this server.',
    ['notify.unlocked']             = 'The vehicle was unlocked.',
    ['notify.owner_set']            = 'The owner was changed.',
    ['notify.renamed']              = 'The vehicle was renamed.',
    ['notify.deleted']              = 'The vehicle was removed. It can be restored from the trash.',
    ['notify.impounded_ok']         = 'The vehicle was impounded.',
    ['notify.returned_ok']          = 'The vehicle was returned to its garage.',
    ['notify.sent_to_garage_ok']    = 'The vehicle was sent to the garage.',
    ['notify.restored']             = 'The vehicle was restored from the trash.',

    -- ---------------------------------------------------------------------------------
    -- /vparkinfo
    -- ---------------------------------------------------------------------------------
    ['info.header']        = 'v-park %s by vyrriox',
    ['info.framework']     = 'framework: %s (%s)',
    ['info.database']      = 'database: %s, tables prefixed %s',
    ['info.keys']          = 'keys: %s',
    ['info.mode']          = 'persistence mode: %s',
    ['info.counts']        = '%d kept, %d in the world, %d waiting to be written, %d grid cells',
    ['info.neons_off']     = 'neons: not stored, no neon-capable resource found (Config.Save.fields.neons)',
    ['info.neons_on']      = 'neons: stored, handled by %s',
    ['info.zones']         = '%d blocked zone(s)',
    ['info.memory_mode']   = 'IN MEMORY: nothing survives a server restart',
    ['info.garages']       = 'garages: %s (%d found)',
    ['info.webhooks']      = 'webhooks: errors %s, staff %s, activity %s',

    -- ---------------------------------------------------------------------------------
    -- /vparkstats
    -- ---------------------------------------------------------------------------------
    ['neontest.running']   = 'forcing neons on and watching for three seconds - the answer goes to the server console',
    ['props.none']         = 'you are not in or near a vehicle',
    ['props.nothing_stored'] = '  stored    nothing: v-park is not keeping this vehicle',
    ['props.neons_guarded'] = '  guarded   the restore has not confirmed these neons, so no capture may change them',
    ['props.header']       = 'properties on %s [%s], id %s:',
    ['props.live_neons']   = '  live      neons %s  colour %s  engine %s',
    ['props.stored_neons'] = '  stored    neons %s  colour %s',
    ['props.live_damage']  = '  live      windows intact %s  doors damaged %s  body %s',
    ['props.stored_damage'] = '  stored    windows broken %s  doors broken %s  body %s',
    ['props.live_paint']   = '  live      colours %s  mod1 %s  mod2 %s  extra %s  custom %s',
    ['props.stored_paint'] = '  stored    colours %s  mod1 %s  mod2 %s  extra %s  custom %s',
    ['props.stored_deformation'] = '  stored    deformation points %s',
    ['props.live_engine']  = '  live      engine health %s',
    ['why.header']    = 'the last %d vehicles v-park did not keep, newest first:',
    ['why.empty']     = 'v-park has refused nothing since it started',
    ['why.line']      = '  %s ago  %s [%s]  %s  %s%s',
    ['diag.empty']    = 'v-park is holding nothing in the world right now',
    ['diag.header']   = 'v-park is holding %d vehicles in the world, furthest from home first:',
    ['diag.line']     = '  %s  %s [%s]  drift %s  %s',
    ['diag.not_live'] = '%s is stored but is not in the world, so there is nothing to compare',
    ['diag.vehicle']  = 'v-park on %s (%s [%s]):',
    ['diag.stored']   = '  stored    %s, %s, %s  heading %s',
    ['diag.world']    = '  world     %s, %s, %s  heading %s  (drift %s)',
    ['diag.entity']   = '  entity    %s, netId %s, readable %s, frozen %s',
    ['diag.progress'] = '  progress  ready %s, seen %s, %d retries, placed %s ago',
    ['diag.position'] = '  position  driven %s, parked %s, nudged %s -> a despawn would re-read its pose: %s',
    ['diag.placer']   = '  placer    %s  |  %s',
    ['stats.timing']  = 'timing: streaming pass %.1f ms avg / %.1f ms worst  |  capture sweep %.1f / %.1f  |  reconcile %.1f / %.1f',
    ['stats.health']  = 'restore: %d awaiting a client, %d awaiting deletion, %d re-asked',
    ['stats.header']       = 'v-park, right now:',
    ['stats.store']        = 'store: %d kept, %d live, %d pending, %d cells',
    ['stats.spawn']        = 'streaming: %d created, %d removed, %d failed, last pass %d ms',
    ['stats.placement']    = 'placement: %d exact, %d nudged, %d forced, %d grounded',
    ['stats.persist']      = 'saving: %d rows, %d batches, %d captures, last flush %d ms',
    ['stats.database']     = 'database: %d queries, %d writes, %d errors, %s ms average, %d ms worst',
    ['stats.lifecycle']    = 'lifecycle: %d expired, %d owner-absent, %d cleaned up, %d evicted, %d deleted elsewhere',

    -- ---------------------------------------------------------------------------------
    -- /vparklist
    -- ---------------------------------------------------------------------------------
    ['list.empty']         = 'You are not keeping any vehicles.',
    ['list.header']        = 'You are keeping %d vehicle(s):',
    ['list.row']           = '%s  %s (%s)  last touched %s ago%s',
    ['list.grace']         = '  [goes in %s]',
    ['list.truncated']     = '... and %d more.',

    -- ---------------------------------------------------------------------------------
    -- /vparkscan
    -- ---------------------------------------------------------------------------------
    ['scan.empty']         = 'No kept vehicles within %d metres.',
    ['scan.header']        = '%d kept vehicle(s) within %d metres:',
    ['scan.row']           = '%s  %s (%s)  %dm  %s  %s',
    ['scan.in_world']      = 'in the world',
    ['scan.stored']        = 'not spawned',

    -- ---------------------------------------------------------------------------------
    -- /vparkzones
    -- ---------------------------------------------------------------------------------
    ['zones.empty']        = 'No blocked zones are configured.',
    ['zones.header']       = '%d blocked zone(s):',
    ['zones.row']          = '%s  [%s]  from %s',

    -- ---------------------------------------------------------------------------------
    -- Garages
    -- ---------------------------------------------------------------------------------
    ['garages.header']     = '%s reports %d garage(s):',
    ['garages.row']        = '%s  %s',
    ['garages.none']       = 'No garage list could be read from any installed garage resource.',
    ['garages.none_hint']  = 'Set Config.Panel.garages and Config.Cleanup.fallbackGarage by hand.',

    -- ---------------------------------------------------------------------------------
    -- Cleanup
    -- ---------------------------------------------------------------------------------
    ['cleanup.none']           = 'No vehicles are due for cleanup.',
    ['cleanup.preview_header'] = '%d vehicle(s) would be cleaned up:',
    ['cleanup.row']            = '%s  %s  idle %s  -> %s',
    ['cleanup.done']           = '%d vehicle(s) were cleaned up.',
    ['cleanup.usage']          = 'usage: cleanup preview | cleanup run',

    -- ---------------------------------------------------------------------------------
    -- Purge and wipe
    -- ---------------------------------------------------------------------------------
    ['purge.usage']        = 'usage: purge <idle:days | type:kind | model:name | wrecked> [confirm]',
    ['purge.none']         = 'Nothing matches %s.',
    ['purge.preview']      = '%d vehicle(s) match %s. Nothing has been changed.',
    ['purge.confirm_hint'] = "Add 'confirm' to actually remove them: purge %s confirm",
    ['purge.done']         = 'Removed %d vehicle(s) matching %s.',

    ['wipe.warning']       = 'This will remove all %d kept vehicles. There is no undo beyond the trash.',
    ['wipe.confirm']       = 'Run: %s %s   (valid for 60 seconds)',
    ['wipe.done']          = 'Wiped %d vehicle(s).',

    -- ---------------------------------------------------------------------------------
    -- Debug and probe
    -- ---------------------------------------------------------------------------------
    ['debug.on']           = 'Debug logging is on (level %s).',
    ['debug.off']          = 'Debug logging is off.',
    ['debug.overlay_on']   = 'v-park debug overlay on.',
    ['debug.overlay_off']  = 'v-park debug overlay off.',
    ['probe.no_model']     = 'No vehicle to probe. Get in one, or look at one.',
    ['probe.no_dimensions']= 'That model has no dimensions the game will report.',
    ['probe.free']         = 'The space is free. A vehicle would be placed exactly here.',
    ['probe.blocked']      = 'The space is blocked by %s. The console has the detail.',

    ['reconcile.done']       = 'Removed %d stray vehicle(s) from the world.',
    ['admin.usage']        = 'usage: admin | admin garages | admin reconcile | admin cleanup preview | admin cleanup run',

    -- ---------------------------------------------------------------------------------
    -- The panel
    -- ---------------------------------------------------------------------------------
    ['panel.title']        = 'V-PARK',
    ['panel.subtitle']     = 'Vehicle registry',
    ['panel.search']       = 'Search plate, model, owner or id',
    ['panel.close']        = 'Close',

    ['panel.filter_all']     = 'All',
    ['panel.filter_near']    = 'Near me',
    ['panel.filter_live']    = 'In world',
    ['panel.filter_idle']    = 'Idle',
    ['panel.filter_wrecked'] = 'Wrecked',
    ['panel.filter_semi']    = 'Semi-persistent',
    ['panel.filter_owned']   = 'Owned',
    ['panel.filter_job']     = 'Job',
    ['panel.filter_unowned'] = 'Unowned',
    ['panel.filter_broken']  = 'Missing model',

    ['panel.sort_recent']   = 'Most recent',
    ['panel.sort_distance'] = 'Nearest',
    ['panel.sort_idle']     = 'Longest idle',
    ['panel.sort_plate']    = 'Plate',
    ['panel.sort_model']    = 'Model',

    ['panel.col_vehicle'] = 'Vehicle',
    ['panel.col_owner']   = 'Owner',
    ['panel.col_where']   = 'Where',
    ['panel.col_state']   = 'State',
    ['panel.col_actions'] = 'Actions',

    ['panel.act_goto']    = 'Go to',
    ['panel.act_bring']   = 'Bring here',
    ['panel.act_mark']    = 'Waypoint',
    ['panel.act_repair']  = 'Repair',
    ['panel.act_clean']   = 'Clean',
    ['panel.act_refuel']  = 'Refuel',
    ['panel.act_unlock']  = 'Unlock',
    ['panel.act_garage']  = 'To garage',
    ['panel.act_impound'] = 'Impound',
    ['panel.act_delete']  = 'Delete',
    ['panel.act_rename']  = 'Rename',
    ['panel.act_owner']   = 'Set owner',

    ['panel.tab_vehicles'] = 'Vehicles',
    ['panel.tab_trash']    = 'Trash',
    ['panel.tab_cleanup']  = 'Cleanup',

    ['panel.trash_empty']   = 'The trash is empty.',
    ['panel.trash_restore'] = 'Restore',
    ['panel.cleanup_run']   = 'Run cleanup now',
    ['panel.cleanup_empty'] = 'Nothing is due for cleanup.',
    ['panel.cleanup_note']  = 'These vehicles have not been driven for longer than the configured idle period. Running the cleanup sends owned vehicles back to a garage and does not delete them.',

    ['panel.in_world']   = 'In world',
    ['panel.stored']     = 'Stored',
    ['panel.wrecked']    = 'Wrecked',
    ['panel.idle_due']   = 'Due',
    ['panel.no_results'] = 'Nothing matches that.',
    ['panel.page']       = 'Page',
    ['panel.of']         = 'of',
    ['panel.total']      = 'total',

    ['panel.confirm']        = 'Confirm',
    ['panel.cancel']         = 'Cancel',
    ['panel.confirm_delete'] = 'Delete this vehicle? It can be restored from the trash.',
    ['panel.choose_garage']  = 'Send to which garage?',
    ['panel.rename_prompt']  = 'New name for this vehicle',
    ['panel.owner_prompt']   = 'Server id of the new owner',
    ['panel.refuel_prompt']  = 'Fuel level, 0 to 100',

    ['panel.summary_total']   = 'Kept',
    ['panel.summary_live']    = 'In world',
    ['panel.summary_pending'] = 'Pending write',

    ['panel.filter_online']  = 'Owner online',
    ['panel.filter_offline'] = 'Owner offline',

    ['panel.act_detail']     = 'Details',

    ['panel.selected']       = '%d selected',
    ['panel.select_all']     = 'Select page',
    ['panel.clear_selection']= 'Clear',
    ['panel.bulk_done']      = '%d done, %d failed.',
    ['panel.bulk_too_many']  = 'Select at most %d vehicles at a time.',
    ['panel.confirm_bulk']   = 'Apply "%s" to %d selected vehicles?',

    ['panel.owner_online']   = 'online',
    ['panel.owner_offline']  = 'offline',

    ['panel.detail_title']   = 'Vehicle detail',
    ['panel.detail_fitted']  = 'Fitted',
    ['panel.detail_damage']  = 'Damage',
    ['panel.detail_timing']  = 'Timing',
    ['panel.detail_colours'] = 'Colours',
    ['panel.detail_none']    = 'Nothing recorded.',
    ['panel.detail_created'] = 'Created',
    ['panel.detail_updated'] = 'Written',
    ['panel.detail_touched'] = 'Touched',
    ['panel.detail_used']    = 'Last driven',
    ['panel.detail_source']  = 'Source',
    ['panel.detail_netid']   = 'Network id',

    ['panel.matched']        = 'matched',
    ['panel.shortcuts']      = 'Shortcuts: / search, R refresh, A select page, ESC close',

    ['panel.grace']      = 'Goes in',
    ['panel.idle']       = 'Idle',
    ['panel.never_used'] = 'Never driven',

    -- ---------------------------------------------------------------------------------
    -- Optional interaction
    -- ---------------------------------------------------------------------------------
    ['interaction.park'] = 'Park here',
})
