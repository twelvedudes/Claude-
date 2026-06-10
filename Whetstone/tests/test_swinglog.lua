--[[
    Tests for swinglog.lua: the 0x028 bit reader (verified by round-trip
    against an independent packer replicating the server's packBitsBE
    little-endian-aggregate semantics) and the predicted-vs-observed
    log line builder.

    Runs under busted or plain Lua 5.1+:
        lua5.1 Whetstone/tests/test_debug.lua
]]

if type(describe) ~= 'function' then
    local stack  = {}
    local tests  = 0
    local failed = 0

    function describe(name, fn)
        table.insert(stack, name)
        fn()
        table.remove(stack)
    end

    function it(name, fn)
        tests = tests + 1

        local ok, err = pcall(fn)

        if ok then
            print('ok   ' .. table.concat(stack, ' > ') .. ' > ' .. name)
        else
            failed = failed + 1
            print('FAIL ' .. table.concat(stack, ' > ') .. ' > ' .. name)
            print('     ' .. tostring(err))
        end
    end

    local original_assert = assert

    assert = setmetatable(
    {
        are =
        {
            equal = function(expected, actual, msg)
                if expected ~= actual then
                    error((msg or 'assert.are.equal') ..
                        ': expected ' .. tostring(expected) ..
                        ', got ' .. tostring(actual), 2)
                end
            end,
        },

        is_true = function(value, msg)
            if value ~= true then
                error((msg or 'assert.is_true') .. ': got ' .. tostring(value), 2)
            end
        end,

        is_nil = function(value, msg)
            if value ~= nil then
                error((msg or 'assert.is_nil') .. ': got ' .. tostring(value), 2)
            end
        end,
    },
    {
        __call = function(_, ...)
            return original_assert(...)
        end,
    })

    WHETSTONE_TEST_SUMMARY = function()
        print(string.format('%d tests, %d failures', tests, failed))

        if failed > 0 then
            os.exit(1)
        end
    end
end

local here = (arg and arg[0] and arg[0]:match('(.*[/\\])')) or ''
package.path = table.concat(
{
    here .. '../?.lua',
    'Whetstone/?.lua',
    '?.lua',
    package.path,
}, ';')

local D = require('swinglog')

-- ---------------------------------------------------------------------
-- Independent bit PACKER replicating packBitsBE: value bits are OR'd
-- into a little-endian byte aggregate at the given bit offset. Written
-- from the C++ source, not from debug.lua, so the round trip is a real
-- cross-check.
-- ---------------------------------------------------------------------

local Writer = {}
Writer.__index = Writer

function Writer.new()
    return setmetatable({ bytes = {}, offset = 0 }, Writer)
end

function Writer:put(value, length)
    for bit = 0, length - 1 do
        local absolute = self.offset + bit
        local byte_index = math.floor(absolute / 8) + 1
        local bit_in_byte = absolute % 8

        if math.floor(value / 2 ^ bit) % 2 == 1 then
            self.bytes[byte_index] = (self.bytes[byte_index] or 0)
                + 2 ^ bit_in_byte
        else
            self.bytes[byte_index] = self.bytes[byte_index] or 0
        end
    end

    self.offset = self.offset + length
end

function Writer:tostring()
    local out = {}

    for index = 1, math.ceil(self.offset / 8) do
        out[index] = string.char(self.bytes[index] or 0)
    end

    return table.concat(out)
end

-- Build a category-1 melee round: actor 0x104, one target (0x10F),
-- two results: a 245 crit and a 117 normal hit with a 12-damage
-- additional effect (enspell-style).
local function build_melee_packet()
    local w = Writer.new()

    w:put(0x28, 8)  -- packet id
    w:put(0, 8)     -- size placeholder
    w:put(0, 16)    -- sync
    w:put(0, 8)     -- workSize byte (offset 0x04)

    w:put(0x104, 32)   -- actor
    w:put(1, 6)        -- target count
    w:put(0, 4)        -- res_sum
    w:put(1, 4)        -- category: melee
    w:put(0, 32)       -- action id
    w:put(0, 32)       -- info

    w:put(0x10F, 32)   -- target id
    w:put(2, 4)        -- result count

    -- result 1: crit for 245
    w:put(1, 3)        -- reaction
    w:put(0, 2)        -- kind
    w:put(2, 12)       -- animation
    w:put(0, 5)        -- info
    w:put(0, 2)        -- distortion
    w:put(0, 3)        -- knockback
    w:put(245, 17)     -- damage
    w:put(67, 10)      -- message: crit
    w:put(0, 31)       -- modifier
    w:put(0, 1)        -- no additional effect
    w:put(0, 1)        -- no spikes

    -- result 2: hit for 117 with +12 additional effect
    w:put(1, 3)
    w:put(0, 2)
    w:put(1, 12)
    w:put(0, 5)
    w:put(0, 2)
    w:put(0, 3)
    w:put(117, 17)
    w:put(1, 10)       -- message: hit
    w:put(0, 31)
    w:put(1, 1)        -- additional effect present
    w:put(3, 6)        -- effect animation
    w:put(0, 4)        -- effect info
    w:put(12, 17)      -- effect damage
    w:put(229, 10)     -- effect message
    w:put(0, 1)        -- no spikes

    return w:tostring()
end

-- =====================================================================
describe('bit reader', function()
    it('reads values back from an independently packed stream', function()
        local w = Writer.new()

        w:put(0xDEADBEEF, 32)
        w:put(45, 6)
        w:put(5, 3)
        w:put(99999, 17)

        local data = w:tostring()

        assert.are.equal(0xDEADBEEF, D.read_bits(data, 0, 32))
        assert.are.equal(45, D.read_bits(data, 32, 6))
        assert.are.equal(5, D.read_bits(data, 38, 3))
        assert.are.equal(99999, D.read_bits(data, 41, 17))
    end)

    it('handles unaligned offsets across byte boundaries', function()
        local w = Writer.new()

        w:put(0, 5)
        w:put(1234, 11)

        assert.are.equal(1234, D.read_bits(w:tostring(), 5, 11))
    end)
end)

-- =====================================================================
describe('action packet parsing', function()
    local action = D.parse_action(build_melee_packet())

    it('parses the header fields', function()
        assert.are.equal(0x104, action.actor)
        assert.are.equal(D.CATEGORY_MELEE, action.category)
        assert.are.equal(1, #action.targets)
        assert.are.equal(0x10F, action.targets[1].id)
    end)

    it('parses every swing result with damage and message', function()
        local results = action.targets[1].results

        assert.are.equal(2, #results)
        assert.are.equal(245, results[1].damage)
        assert.are.equal(67, results[1].message)
        assert.are.equal(117, results[2].damage)
        assert.are.equal(1, results[2].message)
    end)

    it('consumes optional additional-effect blocks correctly', function()
        -- if the variable-width add-effect block were misread, result 2
        -- would be garbage; its presence and value prove alignment
        assert.are.equal(12,
            action.targets[1].results[2].add_effect_damage)
    end)

    it('rejects runt packets', function()
        assert.is_nil(D.parse_action(string.char(0x28, 0, 0, 0)))
    end)
end)

-- =====================================================================
describe('predicted-vs-observed log lines', function()
    local action = D.parse_action(build_melee_packet())

    it('emits one line per swing with prediction context', function()
        D.set_expectations(
        {
            target_name = 'Test Crab',
            swing =
            {
                expected = 130.5,
                base = 87,
                hit_rate = 0.95,
                crit_rate = 0.08,
                pdif = { lower = 1.54, upper = 2.0,
                         spike_chance = 0.333 },
            },
        })

        local lines = D.observe(action, 0x104)

        assert.are.equal(2, #lines)
        assert.is_true(lines[1]:find('crit observed=245') ~= nil)
        assert.is_true(lines[2]:find('hit observed=117') ~= nil)
        assert.is_true(lines[1]:find('predicted_mean=130.5') ~= nil)
        assert.is_true(lines[1]:find('base=87') ~= nil)
        assert.is_true(lines[1]:find('spike=0.333') ~= nil)
        assert.is_true(lines[1]:find('crit_rate=0.080') ~= nil)
        assert.is_true(lines[1]:find('target=Test Crab') ~= nil)
    end)

    it('ignores other actors', function()
        assert.are.equal(0, #D.observe(action, 0x999))
    end)

    it('ignores everything without expectations set', function()
        D.set_expectations(nil)

        assert.are.equal(0, #D.observe(action, 0x104))
    end)
end)

-- =====================================================================
describe('session header', function()
    local header = D.session_header(
    {
        version = '0.6.0',
        profile = 'phoenix',
        stats =
        {
            main_job = 1, sub_job = 13, main_level = 75,
            attack = 420, defense = 310,
            stats = { str = 82, dex = 62, vit = 65, agi = 55,
                      int = 51, mnd = 47, chr = 43 },
        },
        skills = { by_name = { great_axe = { value = 269,
                                             capped = true } } },
        weapon_skill = 'great_axe',
        accuracy = 333,
        haste =
        {
            magic = 0.1465, magic_estimated = false, ability = 0.10,
            gear = 0.07, multiplier = 0.6835, gear_overcap = 0,
        },
        gear_pieces =
        {
            { slot = 'waist', name = 'swift_belt', haste = 0.04 },
            { slot = 'body', name = 'haubergeon', haste = 0 },
        },
        buffs = { 33, 353, 251, 444 },
        known_buffs =
        {
            [33] = { name = 'Haste', category = 'magic',
                     amount = 0.1465, estimated = false },
            [353] = { name = 'Hasso', category = 'ability',
                      amount = 0.10, estimated = false },
        },
        target_name = 'Test Crab',
        level_range = { 20, 25 },
    })

    local text = table.concat(header, '\n')

    it('dumps the full assumed state', function()
        assert.is_true(text:find('profile=phoenix') ~= nil)
        assert.is_true(text:find('skill=269 %(capped%)') ~= nil)
        assert.is_true(text:find('derived_accuracy=333') ~= nil)
        assert.is_true(text:find('gear_haste waist=swift_belt 4.00%%') ~= nil)
        assert.is_true(text:find('buff 33=Haste magic 0.1465') ~= nil)
    end)

    it('warns about food (acc model excludes food acc)', function()
        assert.is_true(text:find('WARNING effect 251') ~= nil)
        assert.is_true(text:find('food acc is NOT counted') ~= nil)
    end)

    it('lists unaccounted effect ids', function()
        assert.is_true(text:find('unaccounted effect ids') ~= nil)
        assert.is_true(text:find('444') ~= nil)
    end)

    it('flags unpinned target ranges', function()
        assert.is_true(text:find('level_range=20%-25 UNPINNED') ~= nil)
    end)

    it('omits zero-haste gear from the haste breakdown', function()
        assert.is_nil(text:find('haubergeon'))
    end)
end)

if WHETSTONE_TEST_SUMMARY then
    WHETSTONE_TEST_SUMMARY()
end
