#!/usr/bin/env python3
"""Behavioral regressions using Lua 5.4 with mocked FiveM natives. Author: vyrriox."""
from pathlib import Path
import unittest
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[1]


class Regressions(unittest.TestCase):
    def setUp(self):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute("""
            function noop() end
            Config = { Database = { autoSchema = true, prefix = 'test_', trashRetentionDays = 0 },
                Log = {}, Compat = { garages = 'auto' } }
            Park = { log = noop, warn = noop, error = noop, debug = noop, now = function() return 100 end,
                vec = function(x,y,z) return {x=x,y=y,z=z} end, try = function(fn) return fn() end }
            function upvalue(fn, name)
                for i = 1, 100 do
                    local key, value = debug.getupvalue(fn, i)
                    if not key then break end
                    if key == name then return value end
                end
                error('missing upvalue ' .. name)
            end
            function CreateThread() end
            netEvents = {}
            function RegisterNetEvent(name, fn) netEvents[name] = fn end
            handlers = {}
            function AddEventHandler(event, fn)
                handlers[event] = handlers[event] or {}
                table.insert(handlers[event], fn)
            end
            function AddStateBagChangeHandler() end
            function DoesEntityExist() return true end
            states = { [0] = true, [1] = false, [2] = true, [20] = false }
            integerNatives = false
            function boolResult(value)
                if integerNatives then return value and 1 or 0 end
                return value
            end
            function DoesExtraExist(_, index) return boolResult(states[index] ~= nil) end
            function IsVehicleExtraTurnedOn(_, index) return boolResult(states[index] == true) end
            waits = 0
            function Wait(ms) assert(ms == 50); waits = waits + 1 end
            function NetworkHasControlOfEntity() return true end
            function NetworkRequestControlOfEntity() end
            writes = {}
            function SetVehicleExtra(_, index, disable)
                assert(type(disable) == 'number')
                table.insert(writes, {index, disable})
                states[index] = disable == 0
            end
            Bridge = {}
            Schema = {enabled = function() return false end}
            SetVehicleFixed = noop
        """)
        self.load('shared/appearance.lua')

    def load(self, relative):
        self.lua.execute((ROOT / relative).read_text(encoding='utf-8'))

    def test_extras_capture_boolean_and_integer_natives(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            for _, mode in ipairs({false, true}) do
                integerNatives = mode
                local extras = Properties.captureExtras(42)
                assert(extras['0'] == 0 and extras['1'] == 1)
                assert(extras['2'] == 0 and extras['20'] == 1)
                assert(extras['3'] == nil, 'numeric zero must not mean an extra exists')
                assert(Properties.extrasMatch(42, extras))
                states[1] = true
                assert(not Properties.extrasMatch(42, extras))
                states[1] = false
            end
        """)

    def test_extras_restore_legacy_numbers_and_imported_booleans(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            local apply = upvalue(Properties.apply, 'applyExtras')
            for _, mode in ipairs({false, true}) do
                integerNatives = mode
                apply(42, {extras = {['0'] = 1, ['1'] = 0, ['2'] = '1', ['20'] = '0'}})
                assert(not states[0] and states[1] and not states[2] and states[20])
                writes = {}
                apply(42, {extras = {['0'] = true, ['1'] = false, ['2'] = true, ['20'] = false,
                    ['-1'] = 0, ['1.5'] = 0, garbage = false}})
                assert(states[0] and not states[1] and states[2] and not states[20])
                assert(#writes == 4)
                assert(writes[1][2] == 1 and writes[2][2] == 1 and writes[3][2] == 0)
                local captured = Properties.captureExtras(42)
                states = { [0] = false, [1] = true, [2] = false, [20] = true }
                apply(42, {extras = captured})
                assert(Properties.extrasMatch(42, captured), 'restore must round-trip exactly')
            end
            SetVehicleExtra = noop
            assert(not pcall(apply, 42, {extras = {['1'] = 0}}), 'refused extra must fail its group')
        """)

    def test_delayed_and_never_available_extras(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            local apply = upvalue(Properties.apply, 'applyExtras')
            apply(42, {extras = {['1'] = 0}})
            assert(waits == 0, 'ready model must not wait')
            states[3] = nil
            Wait = function(ms)
                assert(ms == 50)
                waits = waits + 1
                if waits == 3 then states[3] = false end
            end
            apply(42, {extras = {['3'] = 0}})
            assert(waits == 3 and states[3], 'late extra must be restored')
            waits = 0
            Wait = function(ms) assert(ms == 50); waits = waits + 1 end
            local ok, err = pcall(apply, 42, {extras = {['4'] = 1}})
            assert(not ok and tostring(err):find('extras 4', 1, true))
            assert(waits == 9, 'retry budget must be bounded at 450 ms')
        """)

    def test_extra_retry_keeps_control_and_rechecks_linked_extras(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            local apply = upvalue(Properties.apply, 'applyExtras')
            local originalWrite = SetVehicleExtra
            NetworkHasControlOfEntity = function() return waits >= 2 end
            SetVehicleExtra = function(...)
                assert(NetworkHasControlOfEntity(), 'cannot write without control')
                originalWrite(...)
            end
            apply(42, {extras = {['1'] = 0}})
            assert(waits == 2 and states[1])
            waits = 0
            NetworkHasControlOfEntity = function() return true end
            local disturb = true
            SetVehicleExtra = function(vehicle, index, disable)
                originalWrite(vehicle, index, disable)
                if index == 2 and disable == 0 and disturb then
                    states[1] = false
                    disturb = false
                end
            end
            apply(42, {extras = {['1'] = 0, ['2'] = 0}})
            assert(waits == 1 and states[1] and states[2], 'recheck the full set after writes')
            NetworkHasControlOfEntity = function() return false end
            assert(not pcall(apply, 42, {extras = {['1'] = 0}}))
            DoesEntityExist = function() return false end
            assert(not pcall(apply, 42, {extras = {['1'] = 0}}))
        """)

    def test_tyre_states_round_trip_across_repeated_restores(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            local apply = upvalue(Properties.apply, 'applyDamage')
            local tyres = {}
            IsVehicleTyreBurst = function(_, index, rimOnly)
                local level = tyres[index] or 0
                return boolResult(rimOnly and level >= 2 or not rimOnly and level >= 1)
            end
            IsVehicleWheelBrokenOff = function(_, index) return boolResult(tyres[index] == 3) end
            SetVehicleTyreBurst = function(_, index, onRim) tyres[index] = onRim and 2 or 1 end
            BreakOffVehicleWheel = function(_, index) tyres[index] = 3 end
            for _, mode in ipairs({false, true}) do
                integerNatives = mode
                for cycle = 1, 4 do
                    apply(42, {tyres = {['0'] = 1, ['1'] = 2, ['2'] = 3}})
                    assert(tyres[0] == 1 and tyres[1] == 2 and tyres[2] == 3, 'onRim mapping is reversed')
                    local captured = Properties.captureTyres(42)
                    assert(captured['0'] == 1 and captured['1'] == 2 and captured['2'] == 3)
                    assert(captured['3'] == nil)
                    tyres = {}
                    apply(42, {tyres = captured})
                end
            end
        """)

    def test_failed_extras_keep_server_undressed_guard(self):
        source = (ROOT / 'client/stream.lua').read_text(encoding='utf-8')
        start = source.index('        local dressed = true')
        end = source.index('        local result = Placement.place', start)
        self.lua.execute("\n            entity = 42\n            data = {id = 'sample', properties = {extras = {['1'] = 0}}}\n            unverified = {}\n            Properties = {}\n        ")
        assess = self.lua.eval('function() ' + source[start:end] + ' return dressed end')
        self.lua.execute('Properties.apply = function() return true, {extras = true} end')
        self.assertFalse(assess())
        self.assertTrue(self.lua.eval('unverified.sample.extras'))
        self.lua.execute('Properties.apply = function() return true, {} end')
        self.assertTrue(assess())
        self.lua.execute('Properties.apply = function() return false end')
        self.assertFalse(assess())
        # Exercise the real property guard, restore acknowledgment and foreign snapshot path.
        self.load('client/properties.lua')
        self.lua.execute("""
            Schema.enabled = function(group) return group == 'extras' end
            SetVehicleModKit, SetVehicleEngineOn, SetVehicleDoorsShut = noop, noop, noop
            GetEntityModel = function() return 123 end
            IsVehicleWindowIntact = function() return true end
            data.properties.extras = {['4'] = 0}
        """)
        self.assertFalse(assess())
        self.assertTrue(self.lua.eval('unverified.sample.extras'))
        self.lua.execute("""
            live = {entity=42, placer=7, undressed=true}
            saved = {properties={extras={['4']=0}}, vehicle_type='automobile'}
            Park.ticks = function() return 1000 end
            Park.trace = noop
            Park.timing = function() return {} end
            Store = {live=function() return live end, get=function() return saved end,
                update=function(_, patch)
                    for key, value in pairs(patch) do saved[key] = value end
                    return false
                end}
            Entity = function() return {state={set=noop}} end
        """)
        self.load('server/spawn.lua')
        self.load('server/persist.lua')
        self.lua.execute("""
            source = 7
            netEvents['vpark:server:restored']('sample', {ok=true, dressed=false})
            assert(live.undressed, 'failed extras must keep the server guard')
            Persist.applySnapshot('sample', {properties={extras={['4']=1}}}, false, 8)
            assert(saved.properties.extras['4'] == 0, 'another client must not overwrite the choice')
        """)
        self.lua.execute('states[4] = false')
        self.assertTrue(assess())
        self.lua.execute("""
            source = 8
            netEvents['vpark:server:restored']('sample', {ok=true, dressed=true})
            assert(live.undressed, 'only the nominated client may clear the guard')
            source = 7
            netEvents['vpark:server:restored']('sample', {ok=true, dressed=true})
            assert(not live.undressed, 'successful restore must clear the guard')
        """)

    def test_frozen_vehicle_recaptures_changed_extras(self):
        self.load('client/properties.lua')
        self.load('client/stream.lua')
        self.lua.execute("""
            local tracked = upvalue(Stream.snapshot, 'tracked')
            tracked.sample = {entity = 42, frozen = true, captureClean = true,
                lastHealth = 1000, lastExtras = Properties.captureExtras(42)}
            GetVehicleBodyHealth = function() return 1000 end
            Deformation = {shouldRecapture = function() return false end}
            local captures = 0
            Properties.capture = function() captures = captures + 1; return nil end
            Stream.snapshot('sample')
            assert(captures == 0, 'unchanged vehicle should keep the shortcut')
            states[1] = true
            Stream.snapshot('sample')
            assert(captures == 1, 'external extra change must bypass the shortcut')
        """)

    def neon_client(self):
        self.load('client/properties.lua')
        self.load('client/neons.lua')
        self.lua.execute("""
            Schema.enabled = function() return true end
            tick, owner, engine, control = 0, 7, false, true
            Park.ticks = function() return tick end
            PlayerId = function() return 7 end
            NetworkGetEntityOwner = function() return owner end
            NetworkHasControlOfEntity = function() return boolResult(control) end
            NetworkGetNetworkIdFromEntity = function() return 9 end
            GetIsVehicleEngineRunning = function() return boolResult(engine) end
            lamps, rgb = {false,false,false,false}, {0,0,0}
            IsVehicleNeonLightEnabled = function(_, index) return boolResult(lamps[index+1]) end
            GetVehicleNeonLightsColour = function() return table.unpack(rgb) end
            writes, requests, events, jobs, dirty = 0, 0, {}, {}, 0
            SetVehicleNeonLightsColour = function(_, r,g,b)
                assert(control and owner == 7, 'only the owner may change colour')
                writes = writes + 1; rgb = {r,g,b}
            end
            SetVehicleNeonLightEnabled = function(_, index, value)
                assert(control and owner == 7, 'only the owner may change switches')
                assert(type(value) == 'boolean'); lamps[index+1] = value
                writes = writes + 1
            end
            NetworkRequestControlOfEntity = function() requests = requests + 1 end
            Wait = function(ms) assert(ms == 200); tick = tick + ms end
            CreateThread = function(fn) jobs[#jobs+1] = fn end
            TriggerServerEvent = function(...) events[#events+1] = {...} end
            bag = {}
            Entity = function() return {state=bag} end
            changed = function() dirty = dirty + 1 end
            wanted = {neonEnabled={true,false,true,false},neonColor={40,90,160}}
            function runJobs()
                local pending = jobs; jobs = {}
                for _, fn in ipairs(pending) do fn() end
            end
            function observe(ms)
                tick = tick + (ms or 0)
                Properties.observeNeons('sample', 42, changed)
            end
        """)

    def test_neon_capture_normalizes_booleans_and_validates_rgb(self):
        self.neon_client()
        self.lua.execute("""
            for _, mode in ipairs({false,true}) do
                integerNatives = mode
                lamps, rgb = {true,false,true,false}, {40,90,160}
                assert(Schema.sameNeons(Properties.captureNeons(42), wanted))
            end
            assert(not Schema.neonState({neonEnabled={1,0,1}}))
            assert(not Schema.neonState({neonEnabled={1,0,1,0},neonColor={256,0,0}}))
            assert(not Schema.neonState({neonEnabled={1,0,1,0},neonColor={1.5,0,0}}))
            assert(not Schema.neonState({neonEnabled={1,0,1,0},neonColor={0/0,0,0}}))
            wanted.neonColor[1] = 41
            assert(not Properties.neonsMatch(42, wanted), 'RGB-only edits must differ')
        """)

    def test_neons_require_control_and_stability_after_colour_and_switch_writes(self):
        self.neon_client()
        self.lua.execute("""
            control = false
            Wait = function(ms)
                tick = tick + ms
                if tick == 200 then control = true end
                if tick == 400 then lamps[1] = false; rgb = {1,2,3} end
            end
            assert(Properties.applyNeons(42, wanted, true))
            assert(requests == 1 and tick == 800)
            assert(Schema.sameNeons(Properties.captureNeons(42), wanted))
            -- A refused RGB write is a failure even if all four switches agree.
            SetVehicleNeonLightsColour = noop
            rgb = {1,2,3}; tick = 0
            Wait = function(ms) tick = tick + ms end
            assert(not Properties.applyNeons(42, wanted, true))
            assert(tick == 1800, 'neon verification must have a bounded budget')
        """)

    def test_neon_owner_waits_for_statebag_then_restores_saved_selection(self):
        self.neon_client()
        self.lua.execute("""
            observe(); assert(not Properties.savedNeons('sample',42))
            assert(#jobs == 0 and dirty == 0, 'late bag must not turn defaults into saved data')
            bag['vpark:neons'] = wanted; bag['vpark:hold'] = true
            observe(); assert(#jobs == 0, 'initial placement owns the transaction')
            bag['vpark:hold'] = nil
            observe(); assert(#jobs == 1 and not Properties.savedNeons('sample',42))
            runJobs()
            assert(Schema.sameNeons(Properties.savedNeons('sample',42), wanted))
            assert(#events == 1 and events[1][1] == 'vpark:server:verified')
            assert(events[1][4] == 9 and Schema.sameNeons(events[1][5], wanted))
            local before = writes
            observe(200); observe(200)
            assert(writes == before and #jobs == 0, 'stable parked neons must not be rewritten')
        """)

    def test_neons_save_colour_only_and_all_off_edits_without_a_driver(self):
        self.neon_client()
        self.lua.execute("""
            bag['vpark:neons'] = wanted
            observe(); runJobs()
            rgb = {255,50,20}
            observe(); observe(499); assert(dirty == 0)
            observe(1); assert(dirty == 1)
            local saved = Properties.savedNeons('sample',42)
            assert(saved.neonColor[1] == 255 and saved.neonEnabled[1])
            -- An old bag while the server receives the new snapshot must not undo the edit.
            observe(600); assert(rgb[1] == 255 and #jobs == 0)
            bag['vpark:neons'] = saved
            observe(); assert(#jobs == 0)
            lamps = {false,false,false,false}
            observe(); observe(500)
            assert(dirty == 2 and not Properties.savedNeons('sample',42).neonEnabled[1])
            assert(Properties.savedNeons('sample',42).neonColor[1] == 255)
        """)

    def test_neon_engine_transition_restores_choice_and_retries_are_bounded(self):
        self.neon_client()
        self.lua.execute("""
            bag['vpark:neons'] = wanted
            observe(); runJobs()
            engine = true; lamps = {false,false,false,false}
            observe(); assert(#jobs == 1)
            runJobs(); assert(Schema.sameNeons(Properties.captureNeons(42),wanted))
            assert(dirty == 0, 'engine reset must not save all-off over the selected lights')
            Properties.forgetNeons('sample')
            SetVehicleNeonLightEnabled = noop
            lamps = {false,false,false,false}
            for i=1,3 do observe(2000); runJobs() end
            local count = writes
            observe(2000); assert(#jobs == 0 and writes == count)
            assert(not Properties.savedNeons('sample',42), 'failed restore must remain withheld')
        """)

    def test_neon_ownership_loss_cancels_inflight_restore_without_stealing_control(self):
        self.neon_client()
        self.lua.execute("""
            bag['vpark:neons'] = wanted
            observe()
            Wait = function(ms) tick = tick + ms; owner = 8; control = false end
            runJobs()
            assert(#events == 0 and requests == 0 and not Properties.savedNeons('sample',42))
            local before = writes
            observe(); assert(writes == before)
            owner, control, integerNatives = 7, false, true
            observe(); assert(#jobs == 0, 'numeric zero is not control')
            control = true
            Wait = function(ms) tick = tick + ms end
            observe(); runJobs()
            assert(Schema.sameNeons(Properties.savedNeons('sample',42),wanted))
        """)

    def test_neon_forget_invalidates_queued_job_and_missing_saved_group_can_be_captured(self):
        self.neon_client()
        self.lua.execute("""
            bag['vpark:neons'] = wanted
            observe(); Properties.forgetNeons('sample'); runJobs()
            assert(writes == 0 and #events == 0)
            bag['vpark:neons'] = false
            observe(); assert(Properties.savedNeons('sample',42))
            rgb = {1,2,3}; observe(); observe(500)
            assert(dirty == 1 and Properties.savedNeons('sample',42).neonColor[3] == 3)
        """)

    def test_extras_rebuild_before_health_damage_and_deformation(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            Schema.enabled = function(group)
                return group == 'extras' or group == 'health' or group == 'damage' or group == 'deformation'
            end
            order, visible, autoDisabled = {}, false, true
            local function note(name) order[#order+1] = name end
            SetVehicleModKit, SetVehicleEngineOn, SetVehicleDoorsShut = noop, noop, noop
            GetEntityModel = function() return 123 end
            IsVehicleWindowIntact = function() return true end
            SetVehicleAutoRepairDisabled = function(_, value) autoDisabled = value end
            SetVehicleFixed = function()
                assert(not autoDisabled, 'extra-triggered repair must be allowed during rebuild')
                visible = states[1]; note('repair')
            end
            SetVehicleBodyHealth = function(_, value) assert(value == 650); note('health') end
            SetVehicleEngineHealth = function(_, value) assert(value == 400); note('engine') end
            SetVehicleTyreBurst = function() note('tyre') end
            SetVehicleDoorBroken = function() note('door') end
            SmashVehicleWindow = function() note('window') end
            Deformation = {write=function() note('deformation') end}
            local props = {extras={['1']=0},bodyHealth=650,engineHealth=400,
                tyres={['0']=1},doors={0},windows={0},deformation={d={1}}}
            local ok, failed = Properties.apply(42,props,{rebuildExtras=true,deferNeons=true})
            assert(ok and not next(failed) and visible and autoDisabled)
            assert(table.concat(order,',') == 'repair,health,engine,window,door,tyre,deformation')
            order = {}; Properties.apply(42,props,{deferNeons=true})
            assert(order[1] == 'health', 'ordinary live property apply must not repair the vehicle')
            SetVehicleFixed = function() error('refused repair') end
            local _, bad = Properties.apply(42,props,{rebuildExtras=true,deferNeons=true})
            assert(bad.extras and autoDisabled, 'failure must restore the auto-repair guard')
        """)

    def neon_server(self):
        self.load('shared/schema.lua')
        self.load('shared/appearance.lua')
        self.lua.execute("""
            Park.ticks = function() return 1000 end
            Park.trace = noop
            Park.timing = function() return {} end
            owner = 7
            NetworkGetEntityOwner = function() return owner end
            Config.Save = {fields={neons=true}}
            saved = {id='sample',properties={neonEnabled={true,false,true,false},neonColor={40,90,160}},
                vehicle_type='automobile'}
            live = {entity=42, netId=9, placer=7}
            Store = {get=function() return saved end, live=function() return live end,
                update=function(_, patch)
                    for key,value in pairs(patch) do saved[key] = value end
                    return true
                end}
            published, bag = 0, {}
            bag.set = function(_, key, value, replicated)
                assert(replicated == true); bag[key] = value
                if key == 'vpark:neons' then published = published + 1 end
            end
            Entity = function() return {state=bag} end
        """)
        self.load('server/spawn.lua')
        self.load('server/persist.lua')
        self.lua.execute('Persist.guardSize = noop')

    def test_neon_server_owner_updates_are_saved_and_replicated_spectators_are_ignored(self):
        self.neon_server()
        self.lua.execute("""
            local original = Schema.neonState(saved.properties)
            local edit = {neonEnabled={false,false,false,false},neonColor={100,110,120}}
            Persist.applySnapshot('sample',{properties=Schema.neonState(edit)},false,8)
            assert(Schema.sameNeons(saved.properties,original) and published == 0)
            Persist.applySnapshot('sample',{properties=Schema.neonState(edit)},false,7)
            assert(Schema.sameNeons(saved.properties,edit) and published == 1)
            assert(Schema.sameNeons(bag['vpark:neons'],edit))
            local recolour = Schema.neonState(edit); recolour.neonColor = {1,2,3}
            Persist.applySnapshot('sample',{properties=Schema.neonState(recolour)},false,7)
            assert(saved.properties.neonColor[1] == 1 and published == 2)
            Persist.applySnapshot('sample',{properties={neonEnabled={1,0,1}}},false,7)
            assert(Schema.sameNeons(saved.properties,recolour), 'partial reading must preserve the choice')
            owner = 8
            Persist.applySnapshot('sample',{properties=Schema.neonState(original)},false,7)
            assert(Schema.sameNeons(saved.properties,recolour), 'recheck owner when a packet arrives late')
        """)

    def test_neon_failed_restore_guard_requires_matching_owner_proof(self):
        self.neon_server()
        self.lua.execute("""
            local proof = Schema.neonState(saved.properties)
            live.unverifiedNeons = true
            local edit = {neonEnabled={false,false,false,false},neonColor={1,2,3}}
            Persist.applySnapshot('sample',{properties=Schema.neonState(edit)},false,7)
            assert(Schema.sameNeons(saved.properties,proof))
            source = 8
            netEvents['vpark:server:verified']('sample','neons',9,proof)
            assert(live.unverifiedNeons)
            source = 7
            netEvents['vpark:server:verified']('sample','neons',10,proof)
            netEvents['vpark:server:verified']('sample','neons',9,edit)
            assert(live.unverifiedNeons, 'stale entity or wrong proof must not clear protection')
            live.undressed = true
            netEvents['vpark:server:verified']('sample','neons',9,proof)
            assert(live.unverifiedNeons)
            live.undressed = nil
            netEvents['vpark:server:verified']('sample','neons',9,proof)
            assert(not live.unverifiedNeons)
            Persist.applySnapshot('sample',{properties=Schema.neonState(edit)},false,7)
            assert(Schema.sameNeons(saved.properties,edit))
        """)

    def test_neon_initial_ack_clears_guard_only_after_verified_restore(self):
        self.neon_server()
        self.lua.execute("""
            source = 7
            live.undressed, live.unverifiedNeons = true, true
            netEvents['vpark:server:restored']('sample',{ok=true,dressed=true,neonsVerified=false})
            assert(live.unverifiedNeons and not live.undressed)
            netEvents['vpark:server:restored']('sample',{ok=true,dressed=true,neonsVerified=true})
            assert(not live.unverifiedNeons)
            live.undressed, live.unverifiedNeons = true, true
            netEvents['vpark:server:restored']('sample',{ok=true,dressed=false,neonsVerified=true})
            assert(live.unverifiedNeons and live.undressed)
        """)

    def test_neon_legacy_auto_works_without_mechanic_and_explicit_false_removes_group(self):
        self.neon_server()
        self.lua.execute("""
            Config.Save.fields.neons = 'auto'
            Park.started = function() error('must not require a mechanic') end
            assert(Schema.enabled('neons'))
            Config.Save.fields.neons = false
            assert(not Schema.enabled('neons'))
            Persist.applySnapshot('sample',{properties=Schema.neonState(saved.properties),withheld={neons=true}},false,7)
            assert(saved.properties.neonEnabled == nil and saved.properties.neonColor == nil)
            assert(bag['vpark:neons'] == false)
        """)

    def test_spawn_publishes_all_off_neons_before_restoration_and_protects_them(self):
        self.neon_server()
        self.lua.execute("""
            local send = upvalue(upvalue(Spawn.create, 'dress'), 'sendRestore')
            Store.near = function() return {} end
            saved.properties.neonEnabled = {false,false,false,false}
            TriggerClientEvent = function(name, src, netId, data)
                assert(name == 'vpark:client:restore' and src == 7 and netId == 9)
                assert(live.undressed and live.unverifiedNeons)
                assert(Schema.sameNeons(bag['vpark:neons'],data.properties))
            end
            send(saved, 7, 9)
            assert(published == 1)
        """)

    def test_neons_are_verified_after_placement_finishes_and_ack_reports_failure(self):
        self.neon_client()
        source = (ROOT / 'client/stream.lua').read_text(encoding='utf-8')
        start = source.index('        local dressed = true')
        end = source.index('        if result.ok then', source.index('result.health =', start))
        self.lua.execute("""
            entity, netId = 42, 9
            data = {id='sample',properties=wanted}
            unverified = {}
            Properties.apply = function(_, _, options)
                assert(options.rebuildExtras and options.deferNeons)
                return true, {}
            end
            GetEntityModel = function() return 123 end
            Placement = {place=function()
                lamps = {false,false,false,false}; engine = false
                return {ok=true}
            end}
            Park.round = function(value) return value end
            GetVehicleBodyHealth = function() return 650 end
        """)
        restore = self.lua.eval('function() ' + source[start:end] + ' return result end')
        result = restore()
        self.assertTrue(result['dressed'] and result['neonsVerified'])
        self.assertTrue(self.lua.eval('Schema.sameNeons(Properties.captureNeons(42),wanted)'))
        self.lua.execute('SetVehicleNeonLightEnabled = noop')
        result = restore()
        self.assertFalse(result['neonsVerified'])
        self.assertTrue(self.lua.eval('unverified.sample.neons'))

    def test_frozen_neon_colour_change_bypasses_snapshot_cache(self):
        self.neon_client()
        self.load('client/stream.lua')
        self.lua.execute('jobs = {}')
        self.lua.execute("""
            bag['vpark:neons'] = wanted; observe(); runJobs()
            local tracked = upvalue(Stream.snapshot, 'tracked')
            tracked.sample = {entity=42, frozen=true, captureClean=true, lastHealth=1000,
                lastExtras=Properties.captureExtras(42),lastNeons=Properties.savedNeons('sample',42)}
            GetVehicleBodyHealth = function() return 1000 end
            Deformation = {shouldRecapture=function() return false end}
            local captures = 0
            Properties.capture = function() captures = captures + 1; return nil end
            Stream.snapshot('sample'); assert(captures == 0)
            rgb = {1,2,3}; observe(); observe(500)
            Stream.snapshot('sample'); assert(captures == 1)
        """)

    def test_foreign_snapshot_uses_only_the_owners_confirmed_neon_selection(self):
        self.neon_client()
        self.load('client/stream.lua')
        self.lua.execute('jobs = {}')
        self.load('shared/schema.lua')
        self.load('shared/appearance.lua')
        self.lua.execute("""
            local snap = upvalue(Stream.snapshot, 'foreignSnapshot')
            local foreign = upvalue(snap, 'foreign')
            foreign.sample = 42
            bag['vpark:neons'] = wanted; observe(); runJobs()
            Deformation = {shouldRecapture=function() return false end}
            Properties.captureStatebags = noop
            Properties.capture = function() return {neonEnabled={false,false,false,false},neonColor={0,0,0}} end
            GetVehicleBodyHealth = function() return 1000 end
            Park.toVec = function() return nil end
            GetEntityCoords, GetEntityRotation = function() return {x=1,y=2,z=3} end, function() return {} end
            GetEntitySpeed = function() return 0 end
            IsVehicleSeatFree = function() return false end
            GetInteriorFromEntity, GetRoomKeyFromEntity = function() return 0 end, function() return 0 end
            local captured = snap('sample',1000)
            assert(Schema.sameNeons(captured.properties,wanted) and not captured.withheld.neons)
            owner = 8
            captured = snap('sample',1000)
            assert(captured.properties.neonEnabled == nil and captured.withheld.neons)
        """)

    def test_extra_edits_on_parked_vehicles_trigger_capture_without_damage(self):
        self.neon_client()
        source = (ROOT / 'client/stream.lua').read_text(encoding='utf-8')
        start, end = source.index('local seenExtras = {}'), source.index('local function forgetForeign')
        observe = self.lua.eval('function() ' + source[start:end] + ' return observeExtras end')()
        self.lua.execute('Stream = {dirty=changed}')
        observe('sample', 42)
        self.lua.execute('states[1] = true')
        observe('sample', 42)
        self.assertEqual(self.lua.eval('dirty'), 1)
        observe('sample', 42)
        self.assertEqual(self.lua.eval('dirty'), 1)
        self.lua.execute('owner = 8; states[1] = false')
        observe('sample', 42)
        self.assertEqual(self.lua.eval('dirty'), 1)

    def test_server_rejects_partial_and_spectator_extra_snapshots(self):
        self.neon_server()
        self.lua.execute("""
            saved.properties.extras = {['0']=0,['1']=1}
            Persist.applySnapshot('sample',{properties={extras={['0']=1,['1']=0}}},false,8)
            assert(saved.properties.extras['0'] == 0 and saved.properties.extras['1'] == 1)
            Persist.applySnapshot('sample',{properties={extras={['1']=0}}},false,7)
            assert(saved.properties.extras['0'] == 0 and saved.properties.extras['1'] == 1)
            Persist.applySnapshot('sample',{properties={extras={['0']=1,['1']=0}}},false,7)
            assert(saved.properties.extras['0'] == 1 and saved.properties.extras['1'] == 0)
        """)

    def test_capture_sweep_prefers_network_owner_over_nearer_spectator(self):
        self.lua.execute('jobs = {}; CreateThread = function(fn) jobs[#jobs+1] = fn end')
        self.neon_server()
        self.lua.execute("""
            local function find(fn, visited)
                visited = visited or {}
                if visited[fn] then return end; visited[fn] = true
                for i=1,100 do
                    local name,value = debug.getupvalue(fn,i)
                    if not name then break end
                    if name == 'sweep' then return value end
                    if type(value) == 'function' then
                        local answer = find(value,visited); if answer then return answer end
                    end
                end
            end
            local sweep
            for _, fn in ipairs(jobs) do sweep = find(fn); if sweep then break end end
            assert(sweep)
            Config.Save.sweepSlices = 1
            saved.bucket, saved.pos_x, saved.pos_y = 0, 10, 10
            Store.allLive = function() return {sample=live} end
            Spawn.onlinePlayers = function() return {
                {src=8,bucket=0,x=10,y=10},{src=7,bucket=0,x=80,y=10}}
            end
            Park.observe = noop
            local recipient
            TriggerClientEvent = function(name, src) assert(name == 'vpark:client:capture'); recipient = src end
            sweep(); assert(recipient == 7, 'capture should come from the actual simulator')
            owner = -1
            sweep(); assert(recipient == 8, 'missing owner keeps the nearest-client fallback')
        """)

    def test_schema_fresh_old_current_and_missing_metadata(self):
        self.load('server/database.lua')
        self.lua.execute("""
            local build = upvalue(Database.boot, 'buildSchema')
            for _, fixture in ipairs({{0,false}, {0,true}, {1,true}, {2,true}}) do
                local version, exists = fixture[1], fixture[2]
                local columns, alters, seenCreate = {}, 0, false
                Database.columns = function() return columns end
                Database.meta = function(key, value)
                    if key == 'schema_version' then
                        if value ~= nil then
                            assert(columns.vehicle_type, 'never advance metadata before repair')
                            version = value
                        end
                        return version
                    end
                end
                Database.execute = function(sql)
                    if sql:find('CREATE TABLE IF NOT EXISTS `test_vehicles`', 1, true) then
                        assert(sql:find('`vehicle_type`', 1, true), 'fresh schema lacks column')
                        seenCreate = true
                        if not exists then columns.vehicle_type = 'varchar'; exists = true end
                    elseif sql:find('ALTER TABLE', 1, true) then
                        assert(sql:find('`test_vehicles`', 1, true), 'must respect prefix')
                        columns.vehicle_type = 'varchar'
                        alters = alters + 1
                    end
                end
                build()
                assert(seenCreate and columns.vehicle_type and version == 2)
                assert(alters == (fixture[2] and 1 or 0))
                build()
                assert(alters == (fixture[2] and 1 or 0), 'repair must be idempotent')
            end
        """)

    def test_failed_schema_repair_does_not_mark_success(self):
        self.load('server/database.lua')
        self.lua.execute("""
            local build = upvalue(Database.boot, 'buildSchema')
            Database.columns = function() return {} end
            Database.execute = function() return nil end
            Database.meta = function(_, value)
                assert(value == nil, 'failed migration advanced metadata')
                return 0
            end
            local ok, err = pcall(build)
            assert(not ok and tostring(err):find('could not be added', 1, true))
        """)

    def test_quasar_nested_flat_invalid_and_menu_fallback(self):
        self.load('bridge/server/garages.lua')
        self.lua.execute("""
            local bay = {x=10,y=20,z=30,w=90}
            local menu = {x=100,y=200,z=300}
            assert(Bridge.garagePoint({coords={spawnCoords=bay,menuCoords=menu}}).x == 10)
            assert(Bridge.garagePoint({coords={spawnCoords={},menuCoords=menu}}).x == 100)
            assert(Bridge.garagePoint({spawnPoint=bay}).z == 30)
            assert(Bridge.garagePoint({coords={spawnCoords={x='bad',y=1,z=2}}}) == nil)
            assert(Bridge.garagePoint({coords={spawnCoords={x=1,y=2}}}) == nil)
            exports = { ['qs-advancedgarages'] = { GetGarages = function()
                return {sample={coords={spawnCoords=bay}}, broken=false, empty={coords={}}}
            end } }
            local garages = Bridge.garageReaders[1].read()
            assert(#garages == 1 and garages[1].id == 'sample' and garages[1].point.x == 10)
            exports['qs-advancedgarages'].GetGarages = function()
                return {{id='flat', label='Flat', spawnPoint=bay}}
            end
            assert(Bridge.garageReaders[1].read()[1].id == 'flat')
        """)

    def test_garage_restart_refreshes_cache_and_zones(self):
        self.load('bridge/server/garages.lua')
        self.load('server/runtime.lua')
        self.lua.execute("""
            local reads, zones = 0, 0
            Bridge.garageReaders = {{resource='sample', read=function()
                reads = reads + 1
                return {{id=tostring(reads), point={x=1,y=2,z=3}}}
            end}}
            Park.started = function() return true end
            Bridge.resource = function() return nil end
            Zones = {compile=function(extra)
                zones = zones + 1
                assert(#extra == 1 and extra[1].radius == 5)
                return #extra
            end}
            Config.ZoneOptions = {autoGarages=true}
            assert(Runtime.garages()[1].id == '1')
            assert(Runtime.garages()[1].id == '1' and reads == 1)
            Runtime.state().ready = true
            local scheduled
            SetTimeout = function(_, fn) scheduled = fn end
            for _, fn in ipairs(handlers.onResourceStart) do fn('sample') end
            assert(reads == 1, 'resource handlers must defer the export read')
            scheduled()
            assert(reads == 2 and zones == 1 and Runtime.garages()[1].id == '2')
            Park.started = function() return false end
            for _, fn in ipairs(handlers.onResourceStop) do fn('sample') end
            Zones.compile = function(extra) assert(#extra == 0); return 0 end
            scheduled()
            assert(#Runtime.garages() == 0 and Runtime.garageResource() == nil)
        """)


if __name__ == '__main__':
    unittest.main(verbosity=2)
