#!/usr/bin/env python3
"""Audit regressions for persistence, polling and integration boundaries. Author: vyrriox."""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools.check_regressions import Regressions


class Audit(unittest.TestCase):
    setUp = Regressions.setUp
    load = Regressions.load

    def storage(self):
        self.lua.execute("""
            function GetCurrentResourceName() return 'v-park' end
            function IsDuplicityVersion() return true end
            clock = 1000
            function GetGameTimer() return clock end
        """)
        self.load('bridge/shared/park.lua')
        self.lua.execute("""
            Park.log, Park.warn, Park.error, Park.trace = noop, noop, noop, noop
            json = {encode=function(value) return Park.canonical(value) end}
            Schema.filter = function(value) return value end
            Database = {available=function() return true end, table=function(name) return '`test_'..name..'`' end,
                execute=function() return 1 end, fire=function() return true end}
            Config.Streaming = {cellSize=200}
            Config.Save = {triggerCooldown=10,triggers={onExit=true}}
            Config.Database.batchSize = 1
            Wait = noop
        """)
        self.load('server/store.lua')
        self.load('server/persist.lua')
        self.lua.execute("""
            saved = Store.add({id='sample',plate='TEST',model=123,class=0,owner_type='owned',
                pos_x=20,pos_y=30,pos_z=10,rot_x=0,rot_y=0,rot_z=0,bucket=0,
                body_health=900,engine_health=800,properties={bodyHealth=900},
                created_at=100,updated_at=100,touched_at=100},true)
        """)

    def test_flush_keeps_changes_received_during_sql_write(self):
        self.storage()
        self.lua.execute("""
            Database.execute = function()
                Store.update('sample',{properties={bodyHealth=500},body_health=500})
                return 1
            end
            assert(Persist.flush() == 1)
            assert(select(2,Store.dirty()) == 1, 'new state must remain queued after an older write')
            Database.execute = function() return 1 end
            assert(Persist.flush() == 1 and select(2,Store.dirty()) == 0)
        """)

    def test_flush_exception_releases_lock_and_retains_rows(self):
        self.storage()
        self.lua.execute("""
            Database.execute = function() error('simulated SQL failure') end
            pcall(Persist.flush)
            assert(select(2,Store.dirty()) == 1)
            Database.execute = function() return 1 end
            assert(Persist.flush() == 1, 'an exception must not wedge the flush lock')
        """)

    def test_shutdown_dispatch_does_not_acknowledge_unconfirmed_sql(self):
        self.storage()
        self.lua.execute("""
            Database.fire = function() return false end
            assert(Persist.flushNow() == 0 and select(2,Store.dirty()) == 1)
            Database.fire = function() return true end
            assert(Persist.flushNow() == 1 and select(2,Store.dirty()) == 1,
                'dispatch alone is not a database acknowledgment')
        """)

    def test_regular_touch_uses_acknowledged_flush(self):
        self.storage()
        self.lua.execute("""
            local fire, execute = 0, 0
            Database.fire = function() fire = fire + 1; return true end
            Database.execute = function() execute = execute + 1; return 1 end
            Database.thread = function(fn) fn() end
            assert(Persist.touch('sample','onExit'))
            assert(execute == 1 and fire == 0, 'normal saves must wait for confirmation')
        """)

    def test_metadata_changes_mark_record_dirty(self):
        self.storage()
        self.lua.execute("""
            Store.clearDirty('sample')
            assert(Store.update('sample',{plate='NEXT'}), 'plate changes need persistence')
            assert(Store.byPlate('NEXT') == saved and Store.byPlate('TEST') == nil)
            Store.clearDirty('sample')
            assert(Store.update('sample',{owner_name='vyrriox'}))
        """)

    def track(self):
        self.lua.execute("""
            jobs = {}
            CreateThread = function(fn) jobs[#jobs+1] = fn end
            function findUpvalue(fn, target, visited)
                visited = visited or {}; if visited[fn] then return end; visited[fn] = true
                for i=1,100 do
                    local name,value = debug.getupvalue(fn,i); if not name then break end
                    if name == target then return value end
                    if type(value) == 'function' then
                        local found = findUpvalue(value,target,visited); if found then return found end
                    end
                end
            end
            tick, sent, bagId = 0, 0, 'sample'
            Park.ticks = function() return tick end
            NetworkGetNetworkIdFromEntity = function() return 9 end
            Entity = function() return {state={['vpark:id']=bagId}} end
            Stream = {byEntity=function() return nil end}
            FreezeEntityPosition = noop
            TriggerServerEvent = function() sent = sent + 1 end
            Config.Persistence = {ownedImmediately=true,entryOfferBurstSeconds=30,
                entryOfferBurstRetry=3,entryOfferRetrySeconds=60}
        """)
        self.load('client/track.lua')
        self.lua.execute("""
            enter = findUpvalue(jobs[1],'onEnter')
            leave = findUpvalue(jobs[1],'onExit')
            current = findUpvalue(enter,'current')
        """)

    def test_occupied_vehicle_sends_one_entry_event_per_entry(self):
        self.track()
        self.lua.execute("""
            for i=1,100 do tick=i*500; enter(42) end
            assert(sent == 1, 'one unchanged drive must not send repeated touched events')
            assert(current.since == 500, 'retry window must be measured from the actual entry')
            local restored={frozen=true}
            Stream.byEntity=function() return restored,'sample' end
            enter(42)
            assert(restored.driven and not restored.frozen and sent==1,
                'late local tracking still wakes the occupied vehicle without another event')
        """)

    def test_entry_offer_exits_short_retry_window(self):
        self.track()
        self.lua.execute("""
            bagId = nil
            IsEntityAVehicle = function() return true end
            GetEntityModel = function() return 123 end
            GetEntityCoords = function() return {x=1,y=2,z=3} end
            GetEntityRotation = function() return {x=0,y=0,z=0} end
            GetDisplayNameFromVehicleModel = function() return 'TEST' end
            GetVehicleClass = function() return 0 end
            GetVehicleNumberPlateText = function() return 'TEST' end
            GetVehicleBodyHealth, GetVehicleEngineHealth = function() return 900 end,function() return 900 end
            GetInteriorFromEntity, GetRoomKeyFromEntity = function() return 0 end,function() return 0 end
            Rules = {check=function() return true end}
            Properties = {capture=function() return {} end,captureStatebags=noop}
            Park.coord,Park.angle,Park.plate = function(v) return v end,function(v) return v end,function(v) return v end
            enter(42); tick=3000; enter(42); assert(sent == 2)
            tick=31000; enter(42); assert(sent == 2, 'after the burst, retry waits sixty seconds')
            bagId='sample'; enter(42); enter(42)
            assert(sent == 3, 'a vehicle adopted while driving gets one persistent entry event')
        """)


    def test_failed_batch_and_forced_concurrent_flush_keep_queue(self):
        self.storage()
        self.lua.execute("""
            local entered = false
            Database.execute = function()
                if entered then return 1 end
                entered = true
                assert(Persist.flush(true) == 0, 'force must not overlap an active flush')
                return false
            end
            assert(Persist.flush() == 0 and select(2,Store.dirty()) == 1)
            Database.execute = function() return 0 end
            assert(Persist.flush() == 1 and select(2,Store.dirty()) == 0,
                'a successful unchanged upsert may affect zero rows')
        """)

    def test_record_recreated_during_write_keeps_new_revision(self):
        self.storage()
        self.lua.execute("""
            Database.execute = function()
                local record = Store.remove('sample')
                record.body_health=300
                Store.add(record,true)
                return 1
            end
            assert(Persist.flush() == 1 and select(2,Store.dirty()) == 1)
            Database.execute = function() return 1 end
            assert(Persist.flush() == 1 and select(2,Store.dirty()) == 0)
        """)

    def test_position_guard_preserves_stale_nudged_and_invalid_poses(self):
        self.storage()
        self.lua.execute("""
            pose={x=20,y=30,z=10}; rot={x=0,y=0,z=0}; speed=0
            GetEntityCoords=function() return pose end
            GetEntityRotation=function() return rot end
            GetEntitySpeed=function() return speed end
        """)
        self.load('server/spawn.lua')
        self.lua.execute("""
            local entry={entity=42,spawnX=20,spawnY=30,spawnZ=10,seen=true,driven=true}
            assert(not Spawn.savePosition('sample',entry), 'spawn coordinates are not a fresh pose')
            pose={x=25,y=35,z=11}; rot={x=1,y=2,z=90}
            assert(Spawn.savePosition('sample',entry) and saved.pos_x == 25)
            entry.nudged=true; pose={x=40,y=50,z=12}
            assert(not Spawn.savePosition('sample',entry) and saved.pos_x == 25)
            entry.nudged=false; entry.driven=false; entry.occupant=7
            assert(not Spawn.savePosition('sample',entry))
            entry.occupant=nil; speed=5
            assert(not Spawn.savePosition('sample',entry))
            speed=0; assert(Spawn.savePosition('sample',entry) and saved.pos_x == 40)
            entry.driven=true; pose={x=60,y=70,z=0/0}
            assert(not Spawn.savePosition('sample',entry) and saved.pos_x == 40)
            pose={x=60,y=70,z=12}; rot={x=0,y=nil,z=0}
            assert(not Spawn.savePosition('sample',entry) and saved.pos_x == 40)
            GetEntityCoords=function() error('entity disappeared') end
            assert(not Spawn.savePosition('sample',entry))
        """)

    def test_shutdown_continues_after_one_entity_error_without_yielding(self):
        self.lua.execute("""
            Park.resource='v-park'
            Bridge.isGarageResource=function() return false end
            Bridge.resource=function() return 'none' end
            Store={allLive=function() return {bad={entity=41},good={entity=42}} end}
            visited,dispatched=0,0
            Spawn={savePosition=function(id)
                visited=visited+1; if id=='bad' then error('entity unavailable') end
            end}
            Persist={flushNow=function() dispatched=dispatched+1; return 1 end}
            Wait=function() error('shutdown must not yield') end
        """)
        self.load('server/runtime.lua')
        self.lua.execute("""
            upvalue(Runtime.ready,'state').ready=true
            for _,fn in ipairs(handlers.onResourceStop) do fn('v-park') end
            assert(visited==2 and dispatched==1 and not Runtime.ready())
        """)

    def ownership(self):
        self.lua.execute("""
            characters={[7]='character_a',[8]='character_b'}
            jobs={}; CreateThread=function(fn) jobs[#jobs+1]=fn end
            Bridge.characterId=function(src) return characters[src] end
            Bridge.waitForCharacter=function(src) return characters[src] end
            Bridge.playerName=function(src) return characters[src] and 'vyrriox' end
            Lifecycle={onOwnerOnline=noop,onOwnerOffline=noop,warnExpiring=noop}
            Persist={onPlayerDropped=noop}
        """)
        self.load('server/ownership.lua')

    def test_character_switch_and_reused_source_never_find_old_owner(self):
        self.ownership()
        self.lua.execute("""
            source=7; netEvents['QBCore:Server:OnPlayerLoaded'](); jobs[#jobs]()
            assert(Ownership.sourceOf('character_a')==7)
            characters[7]='character_c'
            assert(Ownership.sourceOf('character_a')==nil)
            netEvents['QBCore:Server:OnPlayerLoaded'](); jobs[#jobs]()
            assert(Ownership.sourceOf('character_c')==7 and Ownership.sourceOf('character_a')==nil)
            source=0; handlers['QBCore:Server:OnPlayerUnload'][1](7)
            assert(next(Ownership.onlineMap())==nil)
        """)

    def test_framework_temporarily_missing_character_can_recover(self):
        self.ownership()
        self.lua.execute("""
            source=7; netEvents['QBCore:Server:OnPlayerLoaded'](); jobs[#jobs]()
            Bridge.playerName=function() return 'vyrriox' end
            characters[7]=nil
            assert(Ownership.sourceOf('character_a')==nil)
            characters[7]='character_a'
            assert(Ownership.sourceOf('character_a')==7)
        """)

    def test_unload_cancels_late_registration_and_network_source_is_authoritative(self):
        self.ownership()
        self.lua.execute("""
            source=7; netEvents['esx:playerLoaded'](8)
            local late=jobs[#jobs]
            handlers.playerDropped[1]()
            late(); assert(next(Ownership.onlineMap())==nil)
            netEvents['esx:playerLoaded'](8); jobs[#jobs]()
            assert(Ownership.sourceOf('character_a')==7 and Ownership.sourceOf('character_b')==nil)
            netEvents['QBCore:Server:OnPlayerLoaded']()
            local pending=jobs[#jobs]
            source=0; handlers['QBCore:Server:OnPlayerUnload'][1](7)
            pending(); assert(next(Ownership.onlineMap())==nil)
        """)

    def test_restored_sale_updates_owner_and_delivers_keys_to_current_owner(self):
        self.storage()
        self.ownership()
        self.lua.execute("""
            source=8; netEvents['QBCore:Server:OnPlayerLoaded'](); jobs[#jobs]()
            Config.Ownership={matchOwnedByPlate=true}; Config.Keys={restore=true}
            Bridge.ownedByPlate=function() return {owner='character_b'} end
            Bridge.giveKeys=function(src) assert(src==8); gaveKeys=true end
            Database.thread=noop
            saved.owner='character_a'
            Ownership.onRestored(saved,42,9)
            assert(saved.owner=='character_b' and gaveKeys)
        """)

    def test_every_compatibility_api_write_respects_permissions(self):
        self.lua.execute("""
            api={}; exports=function(name,fn) api[name]=fn end
            caller='untrusted'; GetInvokingResource=function() return caller end
            Config.Api={allowWrites=false}
            mutated=0; Actions={setAnchor=function() mutated=mutated+1; return true end}
            Database={thread=function() mutated=mutated+1 end}
            SetVehicleNumberPlateText=function() mutated=mutated+1 end
            DeleteEntity=function() mutated=mutated+1 end
        """)
        self.load('server/api.lua')
        self.lua.execute("""
            for _,name in ipairs({'SetAnchored','Flush','UpdatePlate','DeleteVehicle'}) do
                assert(api[name]('sample',true)==false)
            end
            Config.Api={allowWrites=true,allowedResources={'trusted'}}
            for _,name in ipairs({'SetAnchored','Flush','UpdatePlate','DeleteVehicle'}) do
                assert(api[name]('sample',true)==false)
            end
            assert(mutated==0)
            caller='trusted'; assert(api.SetAnchored('sample',true)==true and mutated==1)
        """)

    def test_framework_garage_writes_are_atomic_and_propagate_failures(self):
        self.storage()
        self.load('bridge/server/framework.lua')
        self.lua.execute("""
            function setUpvalue(fn,key,value)
                for i=1,100 do
                    local name=debug.getupvalue(fn,i); if not name then error(key) end
                    if name==key then debug.setupvalue(fn,i,value); return end
                end
            end
            Config.Garages={markAsOut=true,returnToGarageOnRemoval=true}
            Bridge.ownedTable=function() return {table='test_owned',storedColumn='state',
                garageColumn='garage',plate='plate'} end
            calls={}; response=1
            Database.execute=function(sql,params) calls[#calls+1]={sql,params}; return response end
            for _,kind in ipairs({'qb','esx','ox'}) do
                setUpvalue(Bridge.markOut,'frameworkKind',kind)
                assert(Bridge.returnToGarage('TEST','central'))
                local call=calls[#calls]
                assert(call[1]:find('`state` = ?',1,true) and call[1]:find('`garage` = ?',1,true))
                assert(#call[2]==3 and call[2][2]=='central' and call[2][3]=='TEST')
                assert(Bridge.markOut('TEST'))
                call=calls[#calls]
                if kind=='ox' then
                    assert(call[1]:find('= NULL',1,true) and #call[2]==1 and call[2][1]=='TEST')
                else assert(#call[2]==2 and call[2][1]==0) end
                for _,bad in ipairs({false,'nil'}) do
                    response=bad; if bad=='nil' then response=nil end
                    assert(not Bridge.returnToGarage('TEST','central'))
                    assert(not Bridge.markOut('TEST'))
                    assert(not Bridge.impound('TEST'))
                end
                response=1
            end
        """)

    def test_failed_garage_return_retains_vehicle(self):
        self.storage()
        self.lua.execute("""
            Config.Garages={returnToGarageOnRemoval=true}
            Bridge.ownedTable=function() return {storedColumn='state'} end
            Bridge.returnToGarage=function() return false end
            Bridge.impound=function() return false,'none' end
            Bridge.isAdmin=function() return true end
            Spawn={despawn=function() error('must not despawn after failed garage write') end}
        """)
        self.load('server/actions.lua')
        self.load('server/lifecycle.lua')
        self.lua.execute("""
            assert(not Actions.toGarage(0,'sample','central'))
            assert(not Lifecycle.remove('sample','garage','system','test'))
            assert(not Lifecycle.remove('sample','impound','system','test'))
            assert(Store.get('sample')~=nil)
        """)


    def placed_extras(self):
        self.load('client/properties.lua')
        self.lua.execute("""
            entity,netId=42,9
            states={[1]=true,[2]=true,[3]=true,[4]=false,[11]=false}
            data={id='sample',properties={extras={['1']=0,['2']=0,['3']=0,['4']=1,['11']=1},
                bodyHealth=650,engineHealth=400,windows={0},doors={0},tyres={['0']=1},deformation={d={1}}}}
            unverified={};order={};placed=false;lateReset=true;refuse=false
            Schema.enabled=function(group)
                return group=='extras' or group=='health' or group=='damage' or group=='deformation'
            end
            Park.round=function(v) return v end
            local function note(v) order[#order+1]=v end
            SetVehicleModKit,SetVehicleEngineOn,SetVehicleDoorsShut=noop,noop,noop
            GetEntityModel=function() return 123 end
            IsVehicleWindowIntact=function() return true end
            GetVehicleBodyHealth=function() return 600 end
            SetVehicleAutoRepairDisabled=function(_,value) disabled=value end
            SetVehicleFixed=function()
                assert(not disabled)
                for _,v in ipairs(order) do assert(v~='deformation','repair after saved dents') end
                note('repair')
            end
            SetVehicleBodyHealth=function() assert(placed);note('health') end
            SetVehicleEngineHealth=function() assert(placed);note('engine') end
            SmashVehicleWindow=function() note('window') end
            SetVehicleDoorBroken=function() note('door') end
            SetVehicleTyreBurst=function() note('tyre') end
            Deformation={write=function() note('deformation') end}
            Properties.rememberNeons=noop
            Placement={place=function()
                placed=true;note('placement')
                states[1],states[2],states[4]=false,false,true
                return {ok=true}
            end}
            Wait=function(ms)
                assert(ms==50 or ms==100)
                if placed and (lateReset or refuse) then
                    lateReset=false
                    states[1],states[2],states[4]=false,false,true
                end
            end
        """)
        source=(ROOT/'client/stream.lua').read_text(encoding='utf-8')
        start=source.index('        local dressed = true')
        end=source.index('        if result.ok then',source.index('result.health =',start))
        return self.lua.eval('function() '+source[start:end]+' return result end')

    def test_post_placement_extra_reset_is_repaired_before_saved_damage(self):
        restore=self.placed_extras()
        result=restore()
        self.assertTrue(result['dressed'])
        self.lua.execute("""
            assert(Properties.extrasMatch(42,data.properties.extras))
            assert(disabled)
            local health=0
            for _,step in ipairs(order) do if step=='health' then health=health+1 end end
            assert(health==1,'health must only be restored once')
            assert(order[#order]=='deformation')
        """)

    def test_unstable_extras_after_placement_keep_the_save_guard(self):
        restore=self.placed_extras()
        self.lua.execute('refuse=true')
        result=restore()
        self.assertFalse(result['dressed'])
        self.assertTrue(self.lua.eval('unverified.sample.extras and disabled'))

    def test_final_extra_readback_rejects_changes_after_damage(self):
        restore=self.placed_extras()
        self.lua.execute("""
            Properties.rememberNeons=function() states[1]=false end
        """)
        result=restore()
        self.assertFalse(result['dressed'])
        self.assertTrue(self.lua.eval('unverified.sample.extras'))


if __name__ == '__main__':
    unittest.main(verbosity=2)
