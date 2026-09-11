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
            function RegisterNetEvent() end
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
            writes = {}
            function SetVehicleExtra(_, index, disable)
                assert(type(disable) == 'number')
                table.insert(writes, {index, disable})
                states[index] = disable == 0
            end
            Bridge = {}
        """)

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
                    ['3'] = 0, ['-1'] = 0, ['1.5'] = 0, garbage = false}})
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
