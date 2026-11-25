-- Headless driver for spelltracker-vanacore.lua: there is no VanaCore client on this machine, so the window's own code
-- is run against a stub of the API it calls. What this proves is narrow and worth stating: every event the addon
-- registers runs end to end without an error, rows are built, and the row list is laid out from the child's scroll
-- offset (the defect this file was written to catch: rows drawn at index*step would not move under the wheel).
--
--   luajit 'docs/obsidian/03 - Planning/spelltracker/tests/test_draw.lua'
--
-- It cannot prove the window looks right. That rung is the owner's, in the game.

local ADDON = '/home/koikaze/workspace/cexi-addons/addons/vanacore/spelltracker-vanacore'
local GAMEDATA = '/home/koikaze/workspace/vanacore-src/addons/vanacore/libs/gamedata'

local checks, failures = 0, 0
local function check(label, ok, detail)
    checks = checks + 1
    if not ok then
        failures = failures + 1
        print(('FAIL  %s%s'):format(label, detail and ('  (' .. tostring(detail) .. ')') or ''))
    else
        print(('ok    %s'):format(label))
    end
end

------------------------------------------------------------------------------- the stub
local rects = {}          -- every AddRectFilled, so the row layout can be measured
local texts = {}          -- every AddText, so a marker's glyph and place can be found
local injected = {}       -- every vana.packets.inject, so a request can be counted and opened
local SCROLL = 0

local function noop() end
local function lazy(tbl, overrides)
    return setmetatable(overrides or {}, { __index = function (_, k) return type(k) == 'string' and noop or nil end })
end

local dlist = lazy({}, {
    AddRectFilled = function (_, a, b) rects[#rects + 1] = { a[1], a[2], b[1], b[2] } end,
    AddRect = noop, AddLine = noop, AddCircle = noop, AddCircleFilled = noop, AddImage = noop,
    AddRectFilledMultiColor = noop,
    AddText = function (_, font, size, pos, color, str)
        texts[#texts + 1] = { font = font, size = size, x = pos[1], y = pos[2], s = str }
    end,
    PushClipRect = noop, PopClipRect = noop,
    PathClear = noop, PathArcTo = noop, PathStroke = noop,
})

-- where ImGui has the window, and every placement the addon asks for: both must exist before the stub's closures
-- below close over them (declared after, they resolve to globals and every draw raises into the addon's pcall)
local WIN_POS = { 120, 90 }   -- where ImGui has the window; a drag changes it
local NEXT_POS = {}          -- every SetNextWindowPos this run, with its cond

local imgui = lazy({}, {
    GetWindowDrawList = function () return dlist end,
    GetForegroundDrawList = function () return dlist end,
    Begin = function () return true end,
    BeginChild = function () return true end,
    End = noop, EndChild = noop, Dummy = noop,
    CalcTextSize = function () return 40, 14 end,
    GetFont = function () return {} end,
    AddFontFromFileTTF = function () return {} end,
    GetFontBaked = function () return nil end,
    GetTime = function () return 0 end,
    GetIO = function () return { DeltaTime = 0.016 } end,
    GetScrollY = function () return SCROLL end,
    GetScrollMaxY = function () return 4000 end,
    -- two numbers, not a table: vanacore-src/addons/vanacore/vanamaps/vanamaps.lua:1170 reads it that way
    GetWindowPos = function () return WIN_POS[1], WIN_POS[2] end,
    GetWindowSize = function () return 700, 560 end,
    GetItemRectMin = function () return 0, 0 end,
    GetItemRectSize = function () return 10, 10 end,
    GetMousePos = function () return 0, 0 end,
    InvisibleButton = function () return false end,
    IsItemHovered = function () return false end,
    IsItemActive = function () return false end,
    IsItemFocused = function () return false end,
    IsItemDeactivated = function () return false end,
    IsMouseDown = function () return false end,
    IsMouseDoubleClicked = function () return false end,
    IsKeyPressed = function () return false end,
    IsWindowFocused = function () return false end,
    InputTextWithHint = function () return false end,
    PushStyleVar = noop, PopStyleVar = noop, PushStyleColor = noop, PopStyleColor = noop,
    PushFont = noop, PopFont = noop, SetTooltip = noop, SetNextItemWidth = noop,
    SetCursorScreenPos = noop, SetNextWindowSize = noop,
    -- the window's own place, which a drag changes and the addon must not fight: every placement is recorded with
    -- its ImGuiCond, because 'placed once' and 'pinned every frame' look identical without the condition
    SetWindowPos = function (p) WIN_POS[1], WIN_POS[2] = p[1], p[2] end,
    SetNextWindowPos = function (p, cond) NEXT_POS[#NEXT_POS + 1] = { x = p[1], y = p[2], cond = cond } end,
    SetNextWindowFocus = noop, SetScrollY = noop, SetWindowFocus = noop,
})

-- three spells the player knows and three they do not, so both branches of the row draw
local spells = {
    { id = 1, name = 'Cure', type = 'white', skill_name = 'healing_magic', mp = 8, element = 'light', jobs = { [3] = 1, [5] = 3 } },
    { id = 2, name = 'Cure II', type = 'white', skill_name = 'healing_magic', mp = 24, element = 'light', jobs = { [3] = 11, [5] = 15 } },
    { id = 3, name = 'Protect', type = 'white', skill_name = 'enhancing_magic', mp = 6, element = 'light', jobs = { [3] = 7, [5] = 7 } },
    { id = 4, name = 'Cure IV', type = 'white', skill_name = 'healing_magic', mp = 88, element = 'light', jobs = { [3] = 41, [5] = 48, [7] = 51 } },
    { id = 5, name = 'Raise II', type = 'white', skill_name = 'healing_magic', mp = 150, element = 'light', jobs = { [3] = 50, [7] = 75 } },
    { id = 6, name = 'Cure V', type = 'white', skill_name = 'healing_magic', mp = 135, element = 'light', jobs = { [3] = 80 } },
}
-- 40 filler spells on the same job, so the list is long enough to scroll: the row-layout check needs rows that are
-- culled at the top of the view once the wheel has moved
for i = 1, 40 do
    spells[#spells + 1] = { id = 100 + i, name = ('Filler %02d'):format(i), type = 'black', skill_name = 'elemental_magic',
        mp = 20, element = 'fire', jobs = { [3] = 30 } }
end

local bits = string.rep('\0', 128)
local function set_bit(n)
    local i = math.floor(n / 8) + 1
    local v = bits:byte(i) + 2 ^ (n % 8)
    bits = bits:sub(1, i - 1) .. string.char(v) .. bits:sub(i + 1)
end
set_bit(1) set_bit(2) set_bit(3)

-- the bags: an inventory with two Scrolls of Cure IV in slot 3 and a Scroll of Fire in slot 5, and a Mog Locker
-- with a Scroll of Raise II. scan_bags() walks containers 0..17, so this proves it reads real slots and that the id
-- -> name table names the bag the client actually used (4 is the locker, not "bag 4"); every other id answers nil,
-- exactly as a character who owns two bags does.
local scans = 0
-- the shipped gamedata's own shape, not an invented one: an item's `name` is the bare thing and only `log_name`
-- carries the prefix (item 4629 in libs/gamedata/items_1.lua: name="Holy", log_name="scroll of Holy"). A fixture
-- reading `name` alone hid a real defect once: the addon marked nothing, and the fake 'Scroll of Cure IV' said it did.
local ITEMS = {
    [5001] = { name = 'Cure IV', log_name = 'scroll of Cure IV' },
    [5002] = { name = 'Fire', log_name = 'scroll of Fire' },
    [5003] = { name = 'Raise II', log_name = 'scroll of Raise II' },
    [5004] = { name = 'Indi-Int', log_name = 'plate of Indi-Int' },
    -- not a scroll at all: a piece of gear that must never be marked
    [5005] = { name = 'Haubergeon', log_name = 'haubergeon' },
}
local INVENTORY = {
    capacity = 6,
    [0] = { id = 0, index = 0, count = 1200 },
    [3] = { id = 5001, index = 3, count = 2 },
    [4] = { id = 5005, index = 4, count = 1 },   -- gear, not a scroll
    [5] = { id = 5002, index = 5, count = 1 },
}
local LOCKER = {
    capacity = 3,
    [0] = { id = 0, index = 0, count = 0 },
    [1] = { id = 5003, index = 1, count = 1 },
}

local handlers, chat = {}, {}
local player = { main_job = 3, main_job_level = 40, sub_job = 5, sub_job_level = 20 }
-- the client's clock, which the test moves by hand: the ledger's one-a-minute gate and the bag scan's cache both read
-- it, and a frozen clock would make one guard hide behind another
local NOW = 0
-- the zone the client says the player is in, for /spells here. 245 is Lower Jeuno, where the shipped spell_sources
-- table puts Cure IV's scroll.
local PLAYER_ZONE = 245

vana = {
    imgui = imgui,
    ui = { screen = function () return 1920, 1080 end },
    game = {
        player = function () return player end,
        self = function () return 1, 100, 3, 40, 5, 20 end,
        spells = function () return bits end,
        container = function (id)
            if id == 0 then scans = scans + 1 return INVENTORY end
            if id == 4 then return LOCKER end
            return nil
        end,
        -- the two zone reads the alert code is allowed to use (docs/addons/04-game-data.md:455-470): the zone-in's
        -- own answer, and the party list that lags it
        player_zone = function (listed) return PLAYER_ZONE end,
        party = function () return { members = { { name = 'Tester', zone = PLAYER_ZONE } } } end,
    },
    -- the three zones the tests enter. The names are the GAME's spelling, not the wiki's: 'Port San dOria' and
    -- 'Ifrits Cauldron' carry no apostrophe, which is exactly what zone_key has to bridge.
    gamedata = {
        spells = spells, items = ITEMS, jobs = { [3] = { short = 'WHM' }, [5] = { short = 'RDM' } },
        zones = {
            [245] = { name = 'Lower Jeuno' },
            [232] = { name = 'Port San dOria' },
            [205] = { name = 'Ifrits Cauldron' },
            [252] = { name = 'Norg' },
        },
    },
    settings = {
        register = function (spec)
            local data = {}
            for k, v in pairs(spec.defaults or {}) do data[k] = v end
            return { data = data, save = function () saved = (saved or 0) + 1 end }
        end,
    },
    system = {
        open_url = function (url) opened = url return true end,
        play_sound = function () return true end,
        set_clipboard = function () return true end,
    },
    ashita = { object = function () return nil end }, -- no D3D device here: the kit falls back to text badges
    fs = { exists = function () return true end },
    paths = { addon = ADDON, install = '/tmp' },
    chat = { write = function (text) chat[#chat + 1] = text end },
    events = { on = function (name, fn) handlers[name] = handlers[name] or {} handlers[name][#handlers[name] + 1] = fn end },
    log = function (text) last_log = text end,
    time = { clock = function () return NOW end },
    -- the ledger's two symbols (docs/addons/10-packets.md:95-121). inject records the whole packet it was handed so
    -- the request's byte 5 / byte 7 can be read back; last answers nil, as a client that has never seen one does.
    packets = {
        inject = function (incoming, id, data)
            injected[#injected + 1] = { incoming = incoming, id = id, data = data }
            return true
        end,
        last = function () return nil end,
    },
}
addon = { name = 'spelltracker-vanacore', author = 'test', version = '0.1.0', desc = 'test' }

local function fire(name, arg)
    for _, fn in ipairs(handlers[name] or {}) do fn(arg) end
end

------------------------------------------------------------------------------- run
package.path = ADDON .. '/?.lua;' .. package.path
local ok, err = pcall(dofile, ADDON .. '/spelltracker-vanacore.lua')
check('the addon loads', ok, err)
check('it registered present, load, unload and command', (handlers.present and handlers.load and handlers.command) ~= nil)

fire('load')
-- the window starts shut and a shut window builds nothing (a closed tracker costs no CPU), so open it first
fire('command', { command = '/spells' })
local drew, derr = pcall(function () fire('present') fire('present') fire('present') end)
check('three frames run with a client up, no error', drew, derr)

local st = SPELLTRACKER
check('rows were built (WHM 40: Cure IV and Raise II, not Cure V)', st and st.rows and #st.rows >= 3, st and #st.rows)
check('the counts saw the whole job list', st and st.counts and st.counts.total >= 4, st and st.counts and st.counts.total)
local has_cure4 = false
for _, r in ipairs(st.rows or {}) do if r.name == 'Cure IV' then has_cure4 = true check('Cure IV is marked unreachable at 51 vs a 40 WHM', r.unreachable == false) end end
check('Cure IV is in a WHM 40 list', has_cure4)

------------------------------------------------------------------------------- the scroll ledger
-- One 0x1A4 request when the window opens, none on the next frame, one more for /spells sync, then an answer built
-- from the SHIPPED page table marks a row and draws its marker. The request and the answer are Trove's protocol
-- (legacy/ashita/addons/trove/plugins/scrolls.lua:32-46, :326-348): byte 5 = 13 C2S_TAB_SUMMARY, byte 7 = 2, and an
-- answer with action 12, byte 6 = page count, byte 7 = source 2, uint32s from byte 9.
check('opening the window asked for the ledger exactly once', #injected == 1, ('%d requests'):format(#injected))
check('the request is outgoing 0x1A4', injected[1] ~= nil and injected[1].incoming == false and injected[1].id == 0x1A4)
check('the request is 64 bytes with action 13 at byte 5 and source 2 at byte 7',
    injected[1] ~= nil and type(injected[1].data) == 'string' and #injected[1].data == 64
        and injected[1].data:byte(5) == 13 and injected[1].data:byte(7) == 2,
    injected[1] and ('len %s, b5 %s, b7 %s'):format(#injected[1].data, injected[1].data:byte(5), injected[1].data:byte(7)))
check('every other byte of the request is zero', (function ()
    if injected[1] == nil then return false end
    for i = 1, 64 do
        local b = injected[1].data:byte(i)
        if i ~= 5 and i ~= 7 and b ~= 0 then return false end
    end
    return true
end)())

-- and not on every frame: a present tick with the window already open must not spend a second packet
fire('present')
check('a second frame sends no second request', #injected == 1, ('%d requests'):format(#injected))

------------------------------------------------------------------------------- the window moves
-- The first live test reported a window that could not be dragged. The cause is visible here: SetNextWindowPos with
-- ImGuiCond_Always (1) is applied EVERY frame, so a drag is undone before the next frame draws. A position has to be
-- placed once -- at the start of the session, or for /spells reset -- and then left alone.
local pinned = 0
for _, c in ipairs(NEXT_POS) do if c.cond == 1 then pinned = pinned + 1 end end
check('the window is placed, not pinned: at most one forced placement so far', pinned <= 1,
    ('%d Always placements of %d'):format(pinned, #NEXT_POS))
check('it was placed at least once', #NEXT_POS >= 1, #NEXT_POS)

-- a drag: ImGui moves the window itself, the addon must not put it back
local n0 = #NEXT_POS
WIN_POS[1], WIN_POS[2] = 300, 200
fire('present')
check('a dragged window is not put back', #NEXT_POS == n0, ('%d placements after the drag'):format(#NEXT_POS - n0))
check('and the window is left where the mouse let go', WIN_POS[1] == 300 and WIN_POS[2] == 200,
    ('%s, %s'):format(WIN_POS[1], WIN_POS[2]))

-- /spells reset asks for the centre: one placement, then quiet again
local n1 = #NEXT_POS
fire('command', { command = '/spells reset' })
fire('present')
local forced = 0
for i = n1 + 1, #NEXT_POS do if NEXT_POS[i].cond == 1 then forced = forced + 1 end end
check('/spells reset forces the position once', forced == 1, ('%d forced placements'):format(forced))
local n2 = #NEXT_POS
fire('present')
check('and the frame after it places nothing', #NEXT_POS == n2, ('%d more'):format(#NEXT_POS - n2))

-- the window itself: the ledger line is in the header and the stored count comes from the counts
chat = {}
fire('command', { command = '/spells sync' })
check('/spells sync sends a request of its own', #injected == 2, ('%d requests'):format(#injected))
check('/spells sync says what it is doing', table.concat(chat, ' '):find('scroll ledger') ~= nil, table.concat(chat, ' '):sub(1, 120))
check('the forced request is the same packet', injected[2] ~= nil and injected[2].data == injected[1].data)
chat = {}

-- where the SHIPPED table puts Cure IV: the answer below is built from this page and bit, so a decoder that
-- flattens the categories differently marks a different row and the checks after it go red.
local LEDGER = assert(loadfile(ADDON .. '/scroll_ledger.lua'))()
local page_of, bit_of, pages_total = nil, nil, 0
for c = 1, #LEDGER do
    for j = 1, #LEDGER[c].pages do
        pages_total = pages_total + 1
        local page = LEDGER[c].pages[j]
        for b = 0, #page - 1 do
            if page[b + 1][1] == 'Cure IV' then page_of, bit_of = pages_total, b end
        end
    end
end
check('the shipped ledger has 19 pages and places Cure IV on one of them', page_of ~= nil and pages_total == 19,
    ('pages %d, Cure IV at page %s bit %s'):format(pages_total, tostring(page_of), tostring(bit_of)))

-- the answer as the server would send it: a 4-byte header, action, page count, source, a pad byte, then one
-- little-endian uint32 per page from byte 9
local function ledger_answer(masks, action, source)
    local count = #masks
    local bytes = { 0, 0, 0, 0, action or 12, count, source or 2, 0 }
    for i = 1, count do
        local m = masks[i] or 0
        bytes[#bytes + 1] = m % 256
        bytes[#bytes + 1] = math.floor(m / 256) % 256
        bytes[#bytes + 1] = math.floor(m / 65536) % 256
        bytes[#bytes + 1] = math.floor(m / 16777216) % 256
    end
    local out = {}
    for i = 1, #bytes do out[i] = string.char(bytes[i]) end
    return table.concat(out)
end
local masks = {}
for i = 1, pages_total do masks[i] = 0 end
masks[page_of] = 2 ^ bit_of

-- the frame before the answer, so the marker that appears after it can be told apart from the ones already there.
-- 'in storage' narrows the list to the two rows whose scroll is in a bag: at scroll 0 the forty filler spells fill
-- the view, so Cure IV would be culled below the fold and a marker that is never drawn would pass as one that is.
fire('command', { command = '/spells held on' })
chat = {}
local ui = require('ui')
local ICON_FONT = ui.fonts().icons
local BAG_GLYPH = ui.fa('sack-dollar')
local function icon_draws(list)
    local out = {}
    for i = 1, #list do if list[i].font == ICON_FONT then out[#out + 1] = list[i] end end
    return out
end
local function by_row(list)
    local m = {}
    for _, d in ipairs(icon_draws(list)) do
        local k = ('%.1f'):format(d.y)
        m[k] = (m[k] or 0) + 1
    end
    return m
end
texts = {}
fire('present')
local before = by_row(texts)
local before_draws = icon_draws(texts)

-- the answer
local ok_answer, err_answer = pcall(function ()
    fire('packet_in', { id = 0x1A4, data = ledger_answer(masks), size = 8 + 4 * pages_total })
end)
check('an action 12 answer is parsed without an error', ok_answer, err_answer)
check('the answer is stored as one mask per page', st.masks ~= nil and #st.masks == pages_total,
    st.masks and #st.masks)
check('the mask of the page holding Cure IV survived the decode', st.masks ~= nil and st.masks[page_of] == 2 ^ bit_of)

texts = {}
fire('present')
local after_draws = icon_draws(texts)
local after = by_row(texts)

local cure4_row = nil
for _, r in ipairs(st.rows or {}) do if r.name == 'Cure IV' then cure4_row = r end end
check('the ledger answer marks the row of a stored spell', cure4_row ~= nil and cure4_row.stored == true)
check('and no other row is marked', (function ()
    local n = 0
    for _, r in ipairs(st.rows or {}) do if r.stored then n = n + 1 end end
    return n == 1
end)(), st.counts and st.counts.stored)
check('the header count follows the rows', st.counts ~= nil and st.counts.stored == 1, st.counts and st.counts.stored)
check('the header draws the stored count beside the bag count', (function ()
    for i = 1, #texts do if texts[i].s == '1 stored' then return true end end
    return false
end)())

-- exactly one row grew a glyph, and it is the stored marker: the extra draw sits LEFT of that row's bag marker
-- (Cure IV's scroll is in the fixture's inventory, so both markers are on the same row)
local grew, grew_y = 0, nil
for y, n in pairs(after) do
    if n > (before[y] or 0) then grew = grew + 1 grew_y = y end
end
check('the answer adds a marker to one row and no other', grew == 1, ('%d rows grew'):format(grew))
local function draws_at(list, y)
    local out = {}
    for _, d in ipairs(icon_draws(list)) do
        if ('%.1f'):format(d.y) == y then out[#out + 1] = d end
    end
    table.sort(out, function (a, b) return a.x < b.x end)
    return out
end
local new_glyph = nil
do
    local was = draws_at(before_draws, grew_y)
    local matched = {}
    for _, d in ipairs(draws_at(after_draws, grew_y)) do
        local found = false
        for i = 1, #was do
            if not matched[i] and was[i].s == d.s and math.abs(was[i].x - d.x) < 0.01 then
                matched[i] = true found = true break
            end
        end
        if not found then new_glyph = d end
    end
end
local bag_x = nil
for _, d in ipairs(draws_at(after_draws, grew_y)) do if d.s == BAG_GLYPH then bag_x = d.x end end
check('the stored marker had a bag marker to sit beside', bag_x ~= nil)
check('the new glyph is the stored marker, not the bag one', new_glyph ~= nil and new_glyph.s ~= BAG_GLYPH)
check('the stored marker is drawn LEFT of the bag marker', new_glyph ~= nil and bag_x ~= nil and new_glyph.x < bag_x,
    new_glyph and ('stored x %s, bag x %s'):format(tostring(new_glyph.x), tostring(bag_x)))
check('the row without a stored mark did not grow one', (function ()
    for y, n in pairs(after) do
        if y ~= grew_y and n > (before[y] or 0) then return false end
    end
    return true
end)())

-- back to the unfiltered list for the checks that follow
fire('command', { command = '/spells held off' })
chat = {}

-- /spells debug names the ledger in the three facts that explain a marker
chat = {}
fire('command', { command = '/spells debug' })
local dbg = table.concat(chat, ' ')
check('/spells debug reports the ledger pages and stored rows', dbg:find('ledger: 19 pages') ~= nil, dbg:sub(1, 240))
check('/spells debug reports one stored and no lock', dbg:find('1 stored, locked=no') ~= nil, dbg:sub(1, 240))
check('/spells debug reports when it last asked', dbg:find('asked 0s ago') ~= nil, dbg:sub(1, 240))
chat = {}

-- a malformed answer is not an error and not a blank answer: the last good masks stay, so no stored scroll is
-- unmarked by a half-read packet
local short = { 0, 0, 0, 0, 12, 19, 2, 0, 1, 2, 3, 4 }
local short_bytes = {}
for i = 1, #short do short_bytes[i] = string.char(short[i]) end
local ok_short, err_short = pcall(function ()
    fire('packet_in', { id = 0x1A4, data = table.concat(short_bytes) })
end)
check('a truncated answer raises nothing', ok_short, err_short)
check('a truncated answer leaves the last good masks in place', st.masks ~= nil and #st.masks == pages_total,
    st.masks and #st.masks)
local ok_nodata, err_nodata = pcall(function () fire('packet_in', { id = 0x1A4 }) end)
check('an answer with no e.data and no last packet raises nothing', ok_nodata, err_nodata)
local ok_wrong, err_wrong = pcall(function ()
    -- a different mask, so "ignored" is a claim about the content and not just the page count
    local other = {}
    for i = 1, pages_total do other[i] = 0 end
    other[1] = 1
    fire('packet_in', { id = 0x1A4, data = ledger_answer(other, 12, 0) })
end)
check('an answer for another tab source is ignored, and raises nothing', ok_wrong, err_wrong)
check('and it did not overwrite the masks', st.masks ~= nil and #st.masks == pages_total and st.masks[page_of] == 2 ^ bit_of,
    st.masks and ('pages %s, page %s mask %s'):format(#st.masks, tostring(page_of), tostring(st.masks[page_of])))

-- an action that is neither a summary nor a lock (5 is Trove's S2C summary for another tab) carries no ledger and
-- must be left alone: the action byte is what says which tab the masks belong to
local ok_other, err_other = pcall(function ()
    local other = {}
    for i = 1, pages_total do other[i] = 0 end
    other[1] = 1
    fire('packet_in', { id = 0x1A4, data = ledger_answer(other, 5, 2) })
end)
check('an answer with another action is ignored, and raises nothing', ok_other, err_other)
check('and that one did not overwrite the masks either',
    st.masks ~= nil and st.masks[page_of] == 2 ^ bit_of,
    st.masks and tostring(st.masks[page_of]))

-- the one-a-minute gate, measured on its own: the window is closed and opened again 30 s after the last ask (refused)
-- and again 61 s after it (sent). st.ledger_asked is reset by the close, so only the clock decides.
NOW = 30
fire('command', { command = '/spells hide' })
fire('command', { command = '/spells show' })
check('a reopen inside the minute is refused', #injected == 2, ('%d requests'):format(#injected))
NOW = 61
fire('command', { command = '/spells hide' })
fire('command', { command = '/spells show' })
check('a reopen past the minute asks again', #injected == 3, ('%d requests'):format(#injected))
chat = {}

-- out of the world: neither read names a character, so there is nothing to ask about and no packet is spent. The
-- clock is past the gate on purpose, or the gate would be the thing refusing and this rule would go unmeasured.
-- Both reads are restored afterwards, because the checks that follow need a character that could otherwise ask.
local real_self = vana.game.self
vana.game.self = function () return nil end
player = { main_job = 0, main_job_level = 0, sub_job = 0, sub_job_level = 0 }
NOW = 300
local sent_out_of_world = #injected
fire('command', { command = '/spells hide' })
fire('command', { command = '/spells show' })
check('no character in the world means no ledger request', #injected == sent_out_of_world,
    ('%d requests'):format(#injected))
vana.game.self = real_self
player = { main_job = 3, main_job_level = 40, sub_job = 5, sub_job_level = 20 }

-- an older Core.dll with no packet surface: the ask has to be refused, not raised, and it must not be recorded as an
-- error the player would then read in /spells debug
local real_packets = vana.packets
vana.packets = nil
st.last_error = nil
NOW = 400
local sent_no_packets = #injected
local ok_nopk, err_nopk = pcall(function ()
    fire('command', { command = '/spells hide' })
    fire('command', { command = '/spells show' })
end)
check('a client with no packet surface sends nothing and raises nothing',
    ok_nopk and #injected == sent_no_packets and st.last_error == nil, err_nopk or tostring(st.last_error))
vana.packets = real_packets
st.last_error = nil
chat = {}

-- action 4: the server's answer to a character that is not a Crystal Warrior. The ledger locks, says so once, and
-- nothing is asked again -- not from a frame, not from a fresh opening past the gate, and not from /spells sync.
NOW = 500
local sent_before_lock = #injected
local lock_packet = {}
for _, b in ipairs({ 0, 0, 0, 0, 4, 0, 0, 0 }) do lock_packet[#lock_packet + 1] = string.char(b) end
local function lock_lines_in(list)
    local n = 0
    for _, line in ipairs(list) do if line:find('Crystal Warrior only', 1, true) then n = n + 1 end end
    return n
end
chat = {}
fire('packet_in', { id = 0x1A4, data = table.concat(lock_packet) })
check('an action 4 answer locks the ledger', st.ledger_locked == true)
check('the lock is said in one line', lock_lines_in(chat) == 1, #chat)
chat = {}
fire('packet_in', { id = 0x1A4, data = table.concat(lock_packet) })
check('a second lock answer does not repeat the line', lock_lines_in(chat) == 0, #chat)
chat = {}
fire('present')
check('a locked ledger is not asked for on the next frame', #injected == sent_before_lock, ('%d requests'):format(#injected))
-- and not on a fresh opening either: closing and opening the window runs set_open, which is the other place the
-- ledger is asked for, so the lock has to be checked inside the request itself and not only at the call sites
fire('command', { command = '/spells hide' })
fire('command', { command = '/spells show' })
check('a locked ledger is not asked for when the window is opened again', #injected == sent_before_lock,
    ('%d requests'):format(#injected))
fire('command', { command = '/spells sync' })
check('/spells sync on a locked ledger sends nothing', #injected == sent_before_lock, ('%d requests'):format(#injected))
check('/spells sync says why', table.concat(chat, ' '):find('Crystal Warrior only') ~= nil)
check('the lock did not blank what was already decoded', st.masks ~= nil and #st.masks == pages_total)
chat = {}

-- the scroll: at the wheel's 300, every row the list still draws must sit exactly 300 px higher than it does at 0.
-- Index*step would leave them where they were (the defect this check exists for).
local function row_tops(scroll)
    rects = {}
    SCROLL = scroll
    fire('present')
    local tops = {}
    for _, r in ipairs(rects) do
        local h = r[4] - r[2]
        if h > 30 and h < 36 then tops[#tops + 1] = r[2] end
    end
    table.sort(tops)
    return tops
end
local at0 = row_tops(0)
local at300 = row_tops(300)
check('rows are drawn at scroll 0', #at0 >= 5, #at0)
check('rows are drawn at scroll 300', #at300 >= 3, #at300)
-- at scroll 300 the first row still drawn is index floor(300/38)+1 = 8, and it must sit 300 px above where row 8 sits
-- at scroll 0 - i.e. top0 + 7*38 - 300. Placing rows at index*step (the defect) would leave it at top0 + 7*38 instead,
-- 300 px lower: the two answers cannot be confused.
local expect300 = at0[1] + 7 * 38 - 300
check('the list is laid out from the scroll, not from the row index', #at0 > 0 and #at300 > 0 and math.abs(at300[1] - expect300) < 2,
    ('top at 0 %s, top at 300 %s, expected %s (index-based would be %s)')
        :format(tostring(at0[1]), tostring(at300[1]), tostring(expect300), tostring(at0[1] + 7 * 38)))

-- commands
SCROLL = 0
fire('command', { command = '/spells mode cw' })
check('/spells mode cw is taken by the addon', (st and true) and handlers.command ~= nil)
check('mode reached the settings', true)
if st.last_error then print('LAST ERROR: ' .. tostring(st.last_error)) end
fire('command', { command = '/spells debug' })
local said = table.concat(chat, ' | ')
check('/spells debug reports counts and no error', said:find('last error: none') ~= nil, said:sub(1, 120))
fire('command', { command = '//spells scale 60' })
check('//spells is answered too', table.concat(chat, ' '):find('scale: 60%%') ~= nil)
check('an unknown command is not swallowed', (handlers.command[1]({ command = '/ah buy 1' })) == false)

-- the scrolls in the bags: the fixture inventory holds two Scrolls of Cure IV in slot 3, so the Cure IV row must
-- carry the bag and the count, a spell with no scroll must carry nothing, and the header's bag line must have
-- something to count. (The scan runs from the first frame, so this also proves a present frame ends with rows held.)
check('the bags were read on the first frame', scans >= 1, scans)
local cure4 = nil
for _, r in ipairs(st.rows or {}) do if r.name == 'Cure IV' then cure4 = r end end
check('a scroll in the inventory marks its row', cure4 ~= nil and cure4.held ~= nil)
check('the marker carries the bag the scan found it in', cure4 ~= nil and cure4.held ~= nil and cure4.held.bag == 'Inventory',
    cure4 and cure4.held and cure4.held.bag)
check('the marker carries the count off the slot', cure4 ~= nil and cure4.held ~= nil and cure4.held.count == 2,
    cure4 and cure4.held and cure4.held.count)
local raise2 = nil
for _, r in ipairs(st.rows or {}) do if r.name == 'Raise II' then raise2 = r end end
check('a second bag is read too, under the client\'s own name', raise2 ~= nil and raise2.held ~= nil and raise2.held.bag == 'Mog Locker',
    raise2 and raise2.held and raise2.held.bag)
check('a scroll that is not a spell of this job marks nothing', (function ()
    for _, r in ipairs(st.rows or {}) do if r.name == 'Cure V' then return r.held == nil end end
    return false
end)())
check('the counts saw the scrolls in the bags', st.counts ~= nil and st.counts.held == 2, st.counts and st.counts.held)
-- the gear sitting in slot 4 of the same bag must not be mistaken for a scroll: the test is the item's log name,
-- not 'is this item in a bag'
local gear_marked = false
for _, r in ipairs(st.rows or {}) do if r.held ~= nil and r.name == 'Haubergeon' then gear_marked = true end end
check('a piece of gear in a bag is not marked as a scroll', not gear_marked)

-- 'usable now': every row left must be castable, and the three above a WHM 40's level (Cure IV 41, Raise II 50,
-- Cure V 80) have to go
local before_now = #(st.rows or {})
fire('command', { command = '/spells now on' })
fire('present')
check('/spells now on answers', table.concat(chat, ' '):find('can cast now: on') ~= nil)
check('usable now drops the spells above the level', #(st.rows or {}) == before_now - 3,
    ('%d rows before, %d after'):format(before_now, #(st.rows or {})))
local all_cast = #(st.rows or {}) > 0
for _, r in ipairs(st.rows or {}) do if r.castable ~= true then all_cast = false end end
check('every row usable now is castable', all_cast)
fire('command', { command = '/spells now off' })

-- 'in storage': only the row whose scroll is in a bag survives. 'Scroll of Fire' is an item, but Fire is not a spell
-- of a WHM 40, so the map's second entry marks nothing - which is the right answer, not a missed one.
fire('command', { command = '/spells held on' })
fire('present')
check('/spells held on answers', table.concat(chat, ' '):find('scroll in your bags: on') ~= nil)
check('in storage keeps only the rows with a scroll in the bags', #(st.rows or {}) == 2, #(st.rows or {}))
local held_names = {}
for _, r in ipairs(st.rows or {}) do held_names[#held_names + 1] = r.name end
check('the rows left are the two with a scroll, in the sort order they had', table.concat(held_names, ' | ') == 'Cure IV | Raise II',
    table.concat(held_names, ' | '))

-- a rescan is what /spells rescan exists for: the stub counts how many times the inventory was read
local before_scan = scans
fire('command', { command = '/spells rescan' })
check('/spells rescan reads the bags again', scans > before_scan, ('scans %d -> %d'):format(before_scan, scans))
check('/spells rescan reports what it read', table.concat(chat, ' '):find('bags read: 0 Inventory') ~= nil)

-- debug: the two new lines, and no error anywhere in the run
chat = {}
fire('command', { command = '/spells debug' })
local dbg = table.concat(chat, ' ')
check('/spells debug names the bags it read', dbg:find('bags read: 0 Inventory') ~= nil, dbg:sub(1, 160))
check('/spells debug counts the held scrolls', dbg:find('held scrolls: 3') ~= nil, dbg:sub(1, 160))
check('/spells debug still reports no error', dbg:find('last error: none') ~= nil, dbg:sub(1, 200))

fire('command', { command = '/spells held off' })
fire('present')

------------------------------------------------------------------------------- the zone alerts
-- These read the SHIPPED spell_sources.lua, so what they prove is the real generated table end to end: Cure IV's
-- scroll is shop / Lower Jeuno, Raise II's is drop / Ifrit's Cauldron, and the three spells the fixture marks learnt
-- (Cure, Cure II, Protect) are the whole of what Port San d'Oria sources for this job - the 'sourced here, nothing
-- left to learn' case. Ifrit's Cauldron is also the apostrophe case: the game's zone table says 'Ifrits Cauldron'.
-- The kit's own toast is U.toast(kind, title, body, seconds, icon) (ui.lua), so recording its arguments and calling
-- through to the real one proves both what the addon asked for and that the kit accepts it.
local UI = require('ui')
local toasts = {}
local real_toast = UI.toast
UI.toast = function (kind, title, body, seconds, icon)
    toasts[#toasts + 1] = { kind = kind, title = title, body = body, seconds = seconds, icon = icon }
    return real_toast(kind, title, body, seconds, icon)
end
local function enter_zone(id)
    toasts, chat = {}, {}
    fire('zone_change', { zone = id, previous = 0 })
end
local sent_before_zones = #injected

-- 1. in, with a scroll this job still needs: exactly one notice
enter_zone(245)
check('a zone with a needed scroll announces once: one toast', #toasts == 1, ('%d toasts'):format(#toasts))
check('and exactly one chat line', #chat == 1, ('%d lines'):format(#chat))
check('the toast is titled with the zone', toasts[1] ~= nil and toasts[1].title == 'Lower Jeuno',
    toasts[1] and toasts[1].title)
check('the toast body counts the scrolls and names the spell',
    toasts[1] ~= nil and toasts[1].body ~= nil and toasts[1].body:find('Cure IV', 1, true) ~= nil
        and toasts[1].body:find('scrolls here', 1, true) ~= nil,
    toasts[1] and toasts[1].body)
check('the chat line carries the kind, the spell and the generated note',
    chat[1] ~= nil and chat[1]:find('shop: Cure IV - Hasim / Lower Jeuno', 1, true) ~= nil, chat[1])
check('the notice is information only: it sends no packet', #injected == sent_before_zones,
    ('%d requests'):format(#injected))
local drew_toast, drew_toast_err = pcall(function () fire('present') end)
check('the frame after the notice draws it without an error', drew_toast and st.last_error == nil,
    drew_toast_err or tostring(st.last_error))

-- 2. the same zone again is a Mog House in-and-out: nothing new happened, so nothing is said
enter_zone(245)
check('entering the same zone again announces nothing', #toasts == 0 and #chat == 0,
    ('%d toasts, %d lines'):format(#toasts, #chat))

-- 3. a zone the table sources, where everything is already learnt
enter_zone(232)
check('a zone whose spells are all learnt announces nothing', #toasts == 0 and #chat == 0,
    ('%d toasts, %d lines'):format(#toasts, #chat))

-- 4. the per-kind switch. Ifrit's Cauldron has only drops for this job, so it is the one-kind case.
chat = {}
fire('command', { command = '/spells alerts drop off' })
check('/spells alerts drop off says what it did', table.concat(chat, ' '):find('drop zone alerts: off', 1, true) ~= nil,
    table.concat(chat, ' '):sub(1, 120))
enter_zone(205)
check('alert_drop off silences a drop-only zone', #toasts == 0 and #chat == 0,
    ('%d toasts, %d lines'):format(#toasts, #chat))
fire('command', { command = '/spells alerts drop on' })
enter_zone(205)
check('with drop back on, the same zone announces (the game spelling has no apostrophe)',
    #toasts == 1 and #chat == 1, ('%d toasts, %d lines'):format(#toasts, #chat))
check('the drop notice names the drop', chat[1] ~= nil and chat[1]:find('drop: Raise II', 1, true) ~= nil, chat[1])

-- 5. the master switch
chat = {}
fire('command', { command = '/spells alerts off' })
check('/spells alerts off says so', table.concat(chat, ' '):find('zone alerts: off', 1, true) ~= nil,
    table.concat(chat, ' '):sub(1, 120))
enter_zone(245)
check('with alerts off a zone with a need announces nothing', #toasts == 0 and #chat == 0,
    ('%d toasts, %d lines'):format(#toasts, #chat))

-- 6. /spells here: on demand, so it answers even with the automatic notice off, and it reads the zone the client
-- names now rather than the one the last event carried
PLAYER_ZONE = 245
chat = {}
fire('command', { command = '/spells here' })
check('/spells here names the spell and its note with the alerts off',
    #chat == 1 and chat[1]:find('Cure IV', 1, true) ~= nil and chat[1]:find('Hasim / Lower Jeuno', 1, true) ~= nil,
    chat[1])
PLAYER_ZONE = 232
chat = {}
fire('command', { command = '/spells here' })
check('/spells here in a zone with nothing left says so', #chat == 1 and chat[1]:find('nothing here', 1, true) ~= nil,
    chat[1])

-- 7. a zone id the table has no name for: no notice, no error
enter_zone(99999)
check('a zone id with no name announces nothing and raises nothing',
    #toasts == 0 and #chat == 0 and st.last_error == nil,
    ('%d toasts, %d lines, error %s'):format(#toasts, #chat, tostring(st.last_error)))

-- 8. login carries the zone too, and the first zone of a session is not a zone_change
PLAYER_ZONE = 245
chat = {}
fire('command', { command = '/spells alerts on' })
toasts, chat = {}, {}
fire('login', { name = 'Tester', id = 1, zone = 245 })
check('login announces the zone the session starts in', #toasts == 1 and #chat == 1,
    ('%d toasts, %d lines'):format(#toasts, #chat))

-- 9. /spells debug names the zone and the switches
PLAYER_ZONE = 245
chat = {}
fire('command', { command = '/spells debug' })
local zdbg = table.concat(chat, ' ')
check("/spells debug names the zone and the key both tables meet on",
    zdbg:find("zone 'Lower Jeuno' (lower jeuno)", 1, true) ~= nil, zdbg:sub(1, 220))
check('/spells debug says how many spells the table sources there and whether the alerts are on',
    zdbg:find(' sourced spells here, alerts on', 1, true) ~= nil, zdbg:sub(1, 260))
chat = {}
fire('command', { command = '/spells alerts' })
check('a bare /spells alerts answers with the three switches',
    table.concat(chat, ' '):find('shop on, drop on, bcnm on', 1, true) ~= nil, table.concat(chat, ' '):sub(1, 160))
chat = {}

-- an empty bag: the ordinary case for a new character, and the one where a missing slot must not read as an item
INVENTORY[3], INVENTORY[5], LOCKER[1] = nil, nil, nil
fire('command', { command = '/spells rescan' })
local empty_bag_ok, empty_bag_err = pcall(function () fire('present') end)
check('empty bags draw without an error', empty_bag_ok, empty_bag_err)
local any_held = false
for _, r in ipairs(st.rows or {}) do if r.held ~= nil then any_held = true end end
check('empty bags leave every row unheld', not any_held)

-- the client without data: no player, no game data, no sources
player = { main_job = 0, main_job_level = 0, sub_job = 0, sub_job_level = 0 }
vana.game.spells = function () return nil end
vana.gamedata.spells = nil
local empty_ok, empty_err = pcall(function () fire('present') fire('present') end)
check('character select (no job, no bits, no game data) draws an empty list without an error', empty_ok, empty_err)

-- and the same with no game data table at all: vana.gamedata.items is read by the bag scan, so a nil vana.gamedata
-- must cost the scan its names, not the frame
vana.gamedata = nil
local nodata_ok, nodata_err = pcall(function () fire('present') fire('present') end)
check('a nil vana.gamedata still draws, and the bag scan just finds no names', nodata_ok, nodata_err)

-- and with no game data at all, a zone event and /spells here have to degrade to nothing rather than raise into the
-- event handler: they cannot name a zone, so there is nothing to say and nothing to list
toasts, chat = {}, {}
local nozone_ok, nozone_err = pcall(function ()
    fire('zone_change', { zone = 245, previous = 0 })
    fire('command', { command = '/spells here' })
end)
check('with no game data a zone event and /spells here raise nothing', nozone_ok, nozone_err)
check('and neither announces anything', #toasts == 0 and st.last_error == nil,
    ('%d toasts, error %s'):format(#toasts, tostring(st.last_error)))
check('/spells here says the client has not named a zone rather than guessing one',
    #chat == 1 and chat[1]:find('no zone to list yet', 1, true) ~= nil, chat[1])

print(('\nchecks %d, failures %d'):format(checks, failures))
os.exit(failures == 0 and 0 or 1)
