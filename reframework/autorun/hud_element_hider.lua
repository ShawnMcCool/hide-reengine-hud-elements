-- HUD Element Hider
-- A REFramework Lua mod for RE Engine games, developed against
-- Onimusha: Way of the Sword.
--
-- Find any on-screen GUI element you dislike and switch it off.
--
-- Finding is half the product. Element names in these games are opaque ids
-- like GUI020102, so the tool shows which elements are drawing right now,
-- blinks one on demand so you can see which it is, and keeps a label you write
-- down about it. That label is what makes a hide list worth sending to someone
-- else, which is the other half: lists export and import, so identifying an
-- element is work one person does and everyone benefits from.
--
-- Menu: REFramework -> ScriptRunner -> HUD Element Hider. Insert opens it.
--
-- Files, all in reframework/data/:
--   hud_element_hider.json              settings
--   hud_element_hider_list.json         the hide list
--   hud_element_hider_diagnostics.json  what the tool learned about the game
--
-- Design and decisions: plans/001-hud-element-hider.md.
-- Verified REFramework API surface: docs/reframework-api.md.

local MOD, VERSION = "HUD Element Hider", "0.6.0"
local CFG_FILE  = "hud_element_hider.json"          -- settings
local LIST_FILE = "hud_element_hider_list.json"     -- the hide list, shareable
local DIAG_FILE = "hud_element_hider_diagnostics.json"
local SCHEMA = 2

local pure = require("hud_element_hider.pure")
local diagnostics = require("hud_element_hider.diagnostics")

-- ===========================================================================
-- Engine-facing code. Everything below here needs REFramework.
-- ===========================================================================

local WINDOW_FRAMES = 300      -- rolling mean span, about five seconds
local DUMP_FRAMES   = 600      -- periodic dump, about ten seconds
local EVENT_FRAMES  = 300      -- how long an overlay event line stays up
local EVENT_MAX     = 8        -- overlay event lines shown at once
local TRACE_CAP     = 200      -- recorded transitions per trace
local PATH_DEPTH    = 16       -- parent-walk limit
local ROW            = 18      -- draw.text line height, fixed by REFramework

local COL_LABEL = 0xFFB4B4B4   -- labels and headings
local COL_VALUE = 0xFFFFCC33   -- numbers, and matched elements
local COL_NEW   = 0xFF44FF44   -- something seen for the first time
local COL_ALERT = 0xFFFF5555   -- a probe that disabled itself
local COL_PANEL = 0xB0101010   -- overlay backing

local function info(m) log.info("[" .. MOD .. "] " .. tostring(m)) end

-- Every imgui binding this file calls. Checked at load because a `strings`
-- grep of dinput8.dll proves a word appears in the binary, not that it is
-- bound on imgui: `new_line` is in there and `imgui.new_line` is not, which
-- cost a launch. A missing binding is reported once, here, rather than as an
-- exception halfway through drawing the panel.
local IMGUI_NEEDED = {
    "tree_node", "tree_pop", "text", "text_colored", "same_line", "separator",
    "button", "checkbox", "radio_button", "input_text",
}
local function check_imgui()
    local missing = {}
    for _, name in ipairs(IMGUI_NEEDED) do
        if type(imgui) ~= "table" or type(imgui[name]) ~= "function" then
            missing[#missing + 1] = name
        end
    end
    if #missing > 0 then
        info("MISSING imgui bindings: " .. table.concat(missing, ", ")
             .. " -- the panel will be degraded")
    end
    return missing
end

local cfg = {
    mode = "observe", filter = "", announce = true, dump = true,
    view = "on screen", search = "",
    overlay = true,
    -- "draw" is the fixed-size renderer font, small at 4K but known to work.
    -- "imgui" uses REFramework's own font, which honours FontSize in
    -- re2_fw_config.txt, but standalone ImGui windows from the frame callback
    -- are unproven on this build. A failure reverts to "draw" and saves that,
    -- so a setting that does not work here cannot survive a relaunch.
    overlay_style = "draw",
}
local MODES = { "observe", "report", "outline", "flash", "hide" }
local MODE_HELP = {
    observe = "record only, nothing is hidden",
    report  = "list matches on screen as they draw",
    outline = "box the match at its world position",
    flash   = "blink the match on and off",
    hide    = "stop the match drawing",
}
local OVERLAY_STYLES = { "draw", "imgui" }

-- Lowered once when the filter changes. Rebuilding it inside the draw callback
-- would allocate a string per element per frame. filter_raw is the value it was
-- derived from, reconciled once per frame, so the two cannot drift apart if the
-- filter is set by a path that does not go through save_cfg -- a hand-edited
-- config, say.
local filter_lc, filter_raw = "", ""

do
    local ok, saved = pcall(json.load_file, CFG_FILE)
    if ok and type(saved) == "table" then
        for k, v in pairs(saved) do
            if cfg[k] ~= nil and type(v) == type(cfg[k]) then cfg[k] = v end
        end
    else
        pcall(json.dump_file, CFG_FILE, cfg)
    end
end
-- The hide list lives in its own file, separate from settings, so it can be
-- sent to someone, backed up or hand-edited without dragging one player's
-- overlay preferences along with it.
local list = {}
do
    local ok, saved = pcall(json.load_file, LIST_FILE)
    if ok then list = pure.clean_entries(saved) end
end

-- Rebuilt whenever the list changes, never in the draw callback.
local hidden, hidden_count = {}, 0

local function refresh_hidden()
    hidden, hidden_count = pure.active_set(list)
end

local function save_list()
    refresh_hidden()
    pcall(json.dump_file, LIST_FILE, list)
end

-- Hand-editing the file while the game runs is otherwise a trap: this list is
-- held in memory and the next panel action writes all of it back, silently
-- discarding whatever was typed into the file. Reload makes the file the
-- authority again on demand.
local function reload_list()
    local ok, saved = pcall(json.load_file, LIST_FILE)
    if not ok then
        info("reload failed: could not read " .. LIST_FILE)
        return false, "could not read the file"
    end
    local loaded = pure.clean_entries(saved)
    for i = #list, 1, -1 do list[i] = nil end
    for i = 1, #loaded do list[i] = loaded[i] end
    refresh_hidden()
    info("reloaded " .. #list .. " entries from " .. LIST_FILE)
    return true, #list .. " entries loaded, " .. hidden_count .. " hidden"
end

local function sync_filter()
    if filter_raw ~= cfg.filter then
        filter_raw = cfg.filter
        filter_lc = cfg.filter:lower()
    end
end

local function save_cfg()
    sync_filter()
    pcall(json.dump_file, CFG_FILE, cfg)
end
sync_filter()
refresh_hidden()
if #list > 0 then
    info("hide list: " .. #list .. " entries, " .. hidden_count .. " active")
end

local S = {
    seen = {},                 -- element key -> record
    order = {},                -- element keys in first-sight order
    live = {},                 -- element name -> the frame it last drew
    panel_error = nil,         -- last error thrown by the panel body, if any
    mark = 0,                  -- frame the player last pressed Reset
    key_count = 0,
    names = {},                -- name -> list of types
    name_count = 0,
    stats = pure.new_stats(WINDOW_FRAMES),
    classified = {},           -- element address -> name, or false when unknown
}

local classified = S.classified
local live = S.live
local stats = S.stats

-- How many frames an element counts as on screen after it last drew. Elements
-- that draw on alternate frames would otherwise flicker in and out of the list
-- while the player is reading it.
local LIVE_GRACE = 12

-- Rows drawn at once. Long enough for every element this game showed in a
-- session, short enough that a game with hundreds cannot fill the screen.
local ROW_LIMIT = 40

local frame = 0
local frame_elements = 0
local dirty = false
local events = {}              -- transient overlay lines
local matched, pending = {}, {}

-- Free functions rather than closures: the hot path calls these per element and
-- must not allocate. pcall takes the function and its argument directly.
local function fn_addr(e) return e:get_address() end
local function fn_name(e) return e:call("get_GameObject"):call("get_Name") end
local function fn_type(e) return e:get_type_definition():get_full_name() end
local function fn_go(e) return e:call("get_GameObject") end

local function add_event(text, colour)
    events[#events + 1] = { text = text, colour = colour, frame = frame }
end

local function clear_cache(why)
    local n = 0
    for k in pairs(classified) do classified[k] = nil; n = n + 1 end
    if n > 0 then info("cache cleared (" .. why .. "), " .. n .. " entries") end
end

-- Diagnostics own the probes and the traces. The only thing they need back
-- from the product is a way to say a load happened, because the decision cache
-- is keyed on element addresses and those are recycled across one.
local diag = diagnostics.new({
    pure = pure,
    info = info,
    on_transition = function(why)
        clear_cache(why)
        add_event(why == "scene change" and "SCENE changed" or "LOAD", COL_NEW)
    end,
})
local probes = diag.probes

-- Colour accessors on the element's type, walked up the inheritance chain.
-- Records whether tinting is possible at all on this game's GUI types.
local function colour_methods(element)
    local out = {}
    local ok = pcall(function()
        local td = element:get_type_definition()
        local depth = 0
        while td ~= nil and depth < 5 do
            for _, m in ipairs(td:get_methods() or {}) do
                local n = m:get_name()
                if n and n:find("Color", 1, true) then out[n] = true end
            end
            td = td:get_parent_type()
            depth = depth + 1
        end
    end)
    if not ok then return nil end
    local list = {}
    for n in pairs(out) do list[#list + 1] = n end
    table.sort(list)
    return list
end

-- Root-first transform path. Runs on first sight of a key only, never on the
-- steady path. Also validates the walk the shipped mod reuses to let a player
-- tell two similar candidates apart.
local function transform_path(go)
    local segments = {}
    pcall(function()
        local tf = go:call("get_Transform")
        local depth = 0
        while tf ~= nil and depth < PATH_DEPTH do
            local owner = tf:call("get_GameObject")
            local n = owner and owner:call("get_Name")
            if n == nil then break end
            segments[#segments + 1] = tostring(n)
            tf = tf:call("get_Parent")
            depth = depth + 1
        end
    end)
    return pure.join_path(segments)
end

-- Returns the element's name, or false when it cannot be identified. The false
-- is cached too, so an unidentifiable element is not re-reflected every frame.
local function classify(element)
    local ok, name = pcall(fn_name, element)
    if not ok or name == nil then return false end
    name = tostring(name)

    local ok_type, type_name = pcall(fn_type, element)
    type_name = ok_type and tostring(type_name) or "?"

    local key = pure.key_of(name, type_name)
    if S.seen[key] == nil then
        local go = select(2, pcall(fn_go, element))
        S.seen[key] = {
            name = name,
            type = type_name,
            path = go and transform_path(go) or nil,
            first_frame = frame,
            colors = colour_methods(element),
        }
        S.order[#S.order + 1] = key
        S.key_count = S.key_count + 1
        dirty = true

        if S.names[name] == nil then S.name_count = S.name_count + 1 end
        local grew = pure.note_type(S.names, name, type_name)
        local collided = grew and #S.names[name] > 1
        info("NEW " .. name .. "  [" .. type_name .. "]"
             .. (collided and "  COLLISION" or ""))
        if cfg.announce then
            add_event("NEW: " .. name, collided and COL_ALERT or COL_NEW)
        end
    end
    return name
end

-- ---------------------------------------------------------------------------
-- The hot path
-- ---------------------------------------------------------------------------

re.on_pre_gui_draw_element(function(element)
    -- First statement, before any identification: an element that cannot be
    -- named still has to be drawn, so it still counts toward the per-frame
    -- population the shipped mod's callback would have to process.
    frame_elements = frame_elements + 1

    local addr = nil
    local ok_addr, a = pcall(fn_addr, element)
    if ok_addr then addr = a end

    -- Written out rather than as `addr and classified[addr] or nil`: the
    -- cache stores false for an element that cannot be identified, and the
    -- and/or idiom would collapse that false to nil and re-reflect it every
    -- frame, which is the cost the cache exists to avoid.
    local name = nil
    if addr ~= nil then name = classified[addr] end
    if name == nil then
        stats.cache_misses = stats.cache_misses + 1
        name = classify(element)
        if addr ~= nil then classified[addr] = name end
    else
        stats.cache_hits = stats.cache_hits + 1
    end

    if name == false then return true end            -- fail open

    -- One table write per element per frame, and the whole basis of finding:
    -- an element the player can see right now is one that drew recently.
    live[name] = frame

    local matched = filter_lc ~= ""
        and name:lower():find(filter_lc, 1, true) ~= nil

    -- Flash comes before the list so an element already on it can still be
    -- blinked. Otherwise confirming what a listed entry actually is would mean
    -- removing it first.
    if matched and cfg.mode == "flash" then
        return (frame % 30) < 15
    end

    -- The hide list. One hash lookup, skipped entirely while the list is empty,
    -- which is the state the tool sits in until a player puts something in it.
    if hidden_count > 0 and hidden[name] then return false end

    if matched then
        local mode = cfg.mode
        if mode == "report" or mode == "outline" then
            local pos = nil
            if mode == "outline" then
                local ok_go, go = pcall(fn_go, element)
                if ok_go and go ~= nil then
                    local ok_pos, p = pcall(function()
                        local tf = go:call("get_Transform")
                        return tf and tf:call("get_Position")
                    end)
                    if ok_pos then pos = p end
                end
            end
            pending[#pending + 1] = { name = name, pos = pos }
            return true
        elseif mode == "hide" then
            return false
        end
    end
    return true
end)

-- Which namespace binds get_display_size is unconfirmed, so try both once and
-- remember. The fallback keeps the overlay on screen either way.
local display = nil
local function display_size()
    if display ~= nil then return display end
    if probes.display.disabled then return { x = 1920, y = 1080, guessed = true } end
    for _, ns in ipairs({ imgui, draw }) do
        if ns ~= nil and ns.get_display_size ~= nil then
            local ok, size = pcall(ns.get_display_size)
            if ok and size ~= nil and size.x and size.x > 0 then
                display = { x = size.x, y = size.y }
                diag.findings.display_size = size.x .. "x" .. size.y
                diag.findings.display_size_namespace = (ns == imgui) and "imgui" or "draw"
                info("display " .. diag.findings.display_size
                     .. " via " .. diag.findings.display_size_namespace)
                return display
            end
        end
    end
    pure.probe_failed(probes.display, "get_display_size unavailable on imgui and draw")
    info("probe disabled: display: " .. probes.display.reason)
    return { x = 1920, y = 1080, guessed = true }
end

-- calc_text_size may need an active ImGui frame. It is tried once from the
-- frame callback; if that fails the probe disables so it is not retried sixty
-- times a second, and the panel tries again later from inside a real ImGui
-- frame. Until a measurement exists the backing rect uses an estimated advance
-- width, which only makes the panel slightly wide or narrow.
local CHAR_W_ESTIMATE = 7
local char_w = nil

local function measure_char_width(where)
    if char_w ~= nil then return true end
    local ok, size = pcall(imgui.calc_text_size, "MMMMMMMMMM")
    if ok and size ~= nil and size.x and size.x > 0 then
        char_w = size.x / 10
        diag.findings.char_width = char_w
        diag.findings.char_width_source = where
        return true
    end
    return false
end

local function text_width(s)
    if char_w == nil and not probes.metrics.disabled then
        if not measure_char_width("on_frame") then
            pure.probe_failed(probes.metrics,
                "calc_text_size unavailable outside an ImGui frame")
            info("probe disabled: metrics: " .. probes.metrics.reason)
        end
    end
    return #s * (char_w or CHAR_W_ESTIMATE)
end

-- The names this game uses are opaque ids -- GUI020102 tells a player nothing.
-- Picking a candidate from a list of what appeared most recently is therefore
-- the only practical way in: you did something, it showed up, it is at the top.
local function is_live(name)
    local at = live[name]
    return at ~= nil and (frame - at) <= LIVE_GRACE
end

-- One list, four ways of looking at it. Finding and hiding are the same
-- surface: whether an element is hidden is a property of a row, not a
-- different screen.
local VIEWS = { "on screen", "new", "everything", "hidden" }
local VIEW_HELP = {
    ["on screen"] = "drawing right now -- pause with it visible and it is here",
    ["new"]       = "first seen since you pressed Reset",
    ["everything"] = "every element seen this session, newest first",
    ["hidden"]    = "your hide list, including entries not seen yet",
}

-- Rows are the union of what has been seen and what is on the hide list: an
-- imported entry has never drawn here and must still be visible to switch off.
local function rows_for(view, search)
    local out, taken = {}, {}
    local lc = search ~= "" and search:lower() or nil

    local function want(name)
        if taken[name] then return false end
        if lc ~= nil and not name:lower():find(lc, 1, true) then return false end
        return true
    end

    if view ~= "hidden" then
        for i = #S.order, 1, -1 do
            local rec = S.seen[S.order[i]]
            if rec ~= nil and want(rec.name) then
                local show = true
                if view == "on screen" then show = is_live(rec.name)
                elseif view == "new" then show = rec.first_frame > S.mark end
                if show then
                    taken[rec.name] = true
                    out[#out + 1] = { name = rec.name, first_frame = rec.first_frame }
                end
            end
        end
    end

    for _, e in ipairs(list) do
        if want(e.name) and (view == "hidden" or view == "everything") then
            taken[e.name] = true
            out[#out + 1] = { name = e.name, first_frame = nil }
        end
    end
    return out
end

local function set_filter(value)
    cfg.filter = value
    save_cfg()
end

-- Selecting an element and entering a mode are one action, not two. Splitting
-- them across a text box and a radio list is what made the tool unusable in
-- session 1: the player knows which thing they want gone, not which mode a
-- filter belongs to.
local function hide_add(name, label)
    if pure.entry_add(list, pure.new_entry(name, label, true)) then
        save_list()
        info("hide list + " .. name)
        add_event("HIDING " .. name, COL_NEW)
        return true
    end
    return false
end

local function hide_remove(name)
    if pure.entry_remove(list, name) then
        save_list()
        info("hide list - " .. name)
        add_event("SHOWING " .. name, COL_NEW)
        return true
    end
    return false
end

local function select_element(name, mode)
    cfg.filter = name
    cfg.mode = mode
    save_cfg()
    info("selected " .. name .. " in mode " .. mode)
end

-- text_colored's argument order is unverified on this build. One failure
-- demotes every later call to plain text rather than breaking the panel.
local colored_ok = true
local function tc(s, colour)
    if colored_ok then
        if pcall(imgui.text_colored, s, colour) then return end
        colored_ok = false
    end
    imgui.text(s)
end

-- ---------------------------------------------------------------------------
-- Overlay
-- ---------------------------------------------------------------------------

local function overlay_lines()
    local lines = {
        { MOD .. " " .. VERSION, COL_LABEL },
        { string.format("elems/frame %d  max %d  avg %d",
            stats.last, stats.max, math.floor(pure.window_mean(stats.window) + 0.5)),
          COL_VALUE },
    }

    local collisions = pure.collisions(S.names)
    lines[#lines + 1] = {
        string.format("keys %d  names %d  collisions %d",
            S.key_count, S.name_count, #collisions),
        #collisions > 0 and COL_ALERT or COL_VALUE }

    if hidden_count > 0 then
        lines[#lines + 1] = { "hiding " .. hidden_count .. " of "
            .. #list .. " listed", COL_NEW }
    end

    local disabled = diag.disabled()
    lines[#lines + 1] = {
        string.format("cache %s  probes %s",
            pure.percent(pure.cache_hit_rate(stats)),
            #disabled == 0 and "ok" or ("DOWN " .. table.concat(disabled, ","))),
        #disabled == 0 and COL_VALUE or COL_ALERT }

    local shown = 0
    for i = #events, 1, -1 do
        local e = events[i]
        if frame - e.frame < EVENT_FRAMES and shown < EVENT_MAX then
            lines[#lines + 1] = { e.text, e.colour }
            shown = shown + 1
        end
    end
    return lines
end

-- NoTitleBar|NoResize|NoMove|NoScrollbar|NoCollapse|AlwaysAutoResize|
-- NoSavedSettings|NoInputs|NoFocusOnAppearing. A passive block that cannot be
-- dragged, focused or interacted with.
local OVERLAY_FLAGS = 1 + 2 + 4 + 8 + 32 + 64 + 256 + 512 + 4096

-- Begin must be paired with End whatever it returns, so end_window is called on
-- both paths. If any of this throws, the caller drops to the draw.* renderer
-- permanently rather than leaving ImGui's stack unbalanced a second time.
local function overlay_imgui(lines, size)
    imgui.set_next_window_pos(
        Vector2f.new(size.x * 0.012, size.y * 0.045), 1, Vector2f.new(0, 0))
    local open = imgui.begin_window("##" .. MOD .. "_overlay", true, OVERLAY_FLAGS)
    if open then
        for _, l in ipairs(lines) do tc(l[1], l[2]) end
    end
    imgui.end_window()
end

local function overlay_draw(lines, size)

    -- Anchored as a fraction of the display, so the block sits correctly at
    -- 1080p, 1440p, 4K and ultrawide alike. Row spacing stays at the fixed
    -- glyph height: stretching it around unscalable glyphs looks broken.
    local x = math.floor(size.x * 0.012)
    local y = math.floor(size.y * 0.045)
    local pad = 8

    local widest = 0
    for _, l in ipairs(lines) do
        local w = text_width(l[1])
        if w > widest then widest = w end
    end

    -- The substantive legibility fix: light text over a bright game HUD is
    -- unreadable at any resolution.
    pcall(draw.filled_rect, x - pad, y - pad,
          widest + pad * 2, #lines * ROW + pad * 2, COL_PANEL)

    for i, l in ipairs(lines) do
        pcall(draw.text, l[1], x, y + (i - 1) * ROW, l[2])
    end
end

local function draw_overlay()
    local lines = overlay_lines()
    local size = display_size()

    if cfg.overlay_style == "imgui" then
        if pcall(overlay_imgui, lines, size) then return end
        -- Saved, not just switched: a style that does not render on this build
        -- must not come back on the next launch and cost another session.
        cfg.overlay_style = "draw"
        save_cfg()
        info("imgui overlay failed to render; reverted to the draw overlay")
    end
    overlay_draw(lines, size)
end

-- ---------------------------------------------------------------------------
-- Output
-- ---------------------------------------------------------------------------

local function build_output()
    return {
        schema = SCHEMA,
        version = VERSION,
        stats = {
            frames = stats.frames,
            elements_last = stats.last,
            elements_min = stats.min or 0,
            elements_max = stats.max,
            elements_mean = pure.window_mean(stats.window),
            cache_hits = stats.cache_hits,
            cache_misses = stats.cache_misses,
            cache_hit_rate = pure.cache_hit_rate(stats),
            keys = S.key_count,
        },
        elements = S.seen,
        names = S.names,
        collisions = pure.collisions(S.names),
        probes = diag.report(),
    }
end

local function dump(why)
    local ok, err = pcall(json.dump_file, DIAG_FILE, build_output())
    if ok then
        dirty = false
    else
        info("dump failed (" .. tostring(why) .. "): " .. tostring(err))
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

re.on_frame(function()
    frame = frame + 1
    sync_filter()
    pure.record_frame(stats, frame_elements)
    frame_elements = 0
    matched, pending = pending, {}

    local changed = diag.poll(frame)

    if cfg.overlay then draw_overlay() end

    if cfg.mode == "report" or cfg.mode == "outline" then
        local size = display_size()
        local y = math.floor(size.y * 0.35)
        for _, m in ipairs(matched) do
            pcall(draw.text, "MATCH: " .. m.name, math.floor(size.x * 0.012), y, COL_VALUE)
            y = y + ROW
            if cfg.mode == "outline" and m.pos ~= nil then
                local ok, sp = pcall(draw.world_to_screen, m.pos)
                if ok and sp ~= nil then
                    pcall(draw.outline_rect, sp.x - 45, sp.y - 45, 90, 90, COL_VALUE)
                    pcall(draw.text, m.name, sp.x - 45, sp.y - 60, COL_VALUE)
                end
            end
        end
    end

    -- Dump on every transition, and otherwise periodically. The launch crash
    -- rate means a session that dies in combat must still leave usable output.
    if cfg.dump and (changed or (frame % DUMP_FRAMES) == 0) then
        if changed or dirty then dump(changed and "transition" or "periodic") end
    end
end)

re.on_script_reset(function()
    clear_cache("script reset")
    dump("script reset")
end)

-- ---------------------------------------------------------------------------
-- Sharing
-- ---------------------------------------------------------------------------

-- Lists are ordinary json files in reframework/data/, which is the directory
-- json.load_file and json.dump_file already work in. Sharing one is therefore
-- sending someone a file and them dropping it in beside their own.
local LIST_SUFFIX = ".hudlist.json"
local LIST_FORMAT = "hud-element-hider-list"

local function export_payload()
    local entries = {}
    for _, e in ipairs(list) do
        entries[#entries + 1] = { name = e.name, label = e.label, on = e.on }
    end
    return { format = LIST_FORMAT, version = 1, entries = entries }
end

-- Accepts the wrapper this writes, or a bare array, so a list assembled by hand
-- or by some other tool still loads.
local function payload_entries(payload)
    if type(payload) ~= "table" then return nil end
    if payload.entries ~= nil then return pure.clean_entries(payload.entries) end
    return pure.clean_entries(payload)
end

local function export_list(filename)
    if filename == nil or filename == "" then return false, "no filename" end
    if not filename:find("%.json$") then filename = filename .. LIST_SUFFIX end
    local ok, err = pcall(json.dump_file, filename, export_payload())
    if ok then
        info("exported " .. #list .. " entries to " .. filename)
        return true, filename
    end
    return false, tostring(err)
end

local function import_list(filename)
    if filename == nil or filename == "" then return false, "no file selected" end
    local ok, payload = pcall(json.load_file, filename)
    if not ok or payload == nil then
        return false, "could not read " .. filename
    end
    local entries = payload_entries(payload)
    if entries == nil or #entries == 0 then
        return false, filename .. " holds no entries"
    end
    local added, labelled = pure.merge_entries(list, entries, filename)
    save_list()
    info(string.format("imported %s: %d new (off), %d labelled",
        filename, added, labelled))
    return true, string.format("%d new, switched off. %d labelled.", added, labelled)
end

-- fs.glob is present in this build's strings but its filter syntax is not
-- documented anywhere authoritative, so a failure here just means the field is
-- typed into by hand rather than picked from a list.
local share_files, share_files_error = {}, nil
local share_files_loaded = false
local function refresh_share_files()
    share_files_loaded = true
    share_files, share_files_error = {}, nil
    if fs == nil or fs.glob == nil then
        share_files_error = "fs.glob unavailable -- type a filename"
        return
    end
    local ok, found = pcall(fs.glob, [[.*\.json$]])
    if not ok or type(found) ~= "table" then
        share_files_error = "fs.glob failed -- type a filename"
        return
    end
    for _, f in ipairs(found) do
        local base = tostring(f):match("([^/\\]+)$") or tostring(f)
        if base ~= CFG_FILE and base ~= DIAG_FILE and base ~= LIST_FILE then
            share_files[#share_files + 1] = base
        end
    end
    table.sort(share_files)
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

-- Held across frames so half-typed text survives until a button is pressed.
local add_buffer = ""
local export_buffer = "my-list" .. LIST_SUFFIX
local import_buffer = ""
local share_message = nil

local function kv(label, value, colour)
    imgui.text(label)
    imgui.same_line()
    tc(value, colour or COL_VALUE)
end

-- The panel's whole body. A plain function so the caller can run it under
-- pcall and still reach tree_pop: an exception between tree_node and
-- tree_pop leaves Dear ImGui's stack unbalanced, which breaks REFramework's
-- entire window rather than just this panel.
local function panel_body()

    -- The panel is the only way to change anything: the settings file is read at
    -- load and never re-read. So it has to explain itself. Someone using this
    -- to find an annoying prompt should not have to have written it.
    if imgui.tree_node("How to use this") then
        imgui.text("Insert opens and closes this menu.")
        imgui.text("")
        imgui.text("FINDING: pause with the thing you dislike on screen and")
        imgui.text("look at the list below on the 'on screen' view. Only what")
        imgui.text("is drawing right now is listed, so it is a short list.")
        imgui.text("Not sure which row it is? Flash blinks it.")
        imgui.text("")
        imgui.text("Narrower still: press Reset, make the thing happen, then")
        imgui.text("switch to the 'new' view. That is only what appeared since.")
        imgui.text("")
        imgui.text("HIDING: press Hide on the row. It stops drawing and stays")
        imgui.text("gone across launches. The tickbox turns an entry off")
        imgui.text("without deleting it.")
        imgui.text("")
        imgui.text("Then write what it is in the label box. The name is an")
        imgui.text("opaque id, so the label is the only record of what you")
        imgui.text("found, and it is what makes a list worth sending to")
        imgui.text("someone else. See Share a list.")
        imgui.tree_pop()
    end
    imgui.separator()

    -- One list. Whether an element is hidden is a property of its row, not a
    -- different screen: finding and hiding are the same surface.
    tc("ELEMENTS", COL_LABEL)
    for i, v in ipairs(VIEWS) do
        if imgui.radio_button(v, cfg.view == v) then cfg.view = v; save_cfg() end
        -- No same_line after the last one, which is what breaks the row.
        -- imgui.new_line does not exist in this build.
        if i < #VIEWS then imgui.same_line() end
    end
    tc("  " .. (VIEW_HELP[cfg.view] or ""), COL_LABEL)

    local schanged, sv = imgui.input_text("search", cfg.search)
    if schanged then cfg.search = sv; save_cfg() end
    imgui.same_line()
    if imgui.button("Reset##mark") then
        S.mark = frame
        cfg.view = "new"
        save_cfg()
    end
    imgui.same_line()
    tc("  Reset marks now, so 'new' shows only what appears next", COL_LABEL)

    local rows = rows_for(cfg.view, cfg.search)
    local shown = math.min(#rows, ROW_LIMIT)
    tc(string.format("  %d shown%s   --   %d hidden of %d listed",
        shown, #rows > shown and (" of " .. #rows) or "",
        hidden_count, #list), COL_LABEL)
    if #rows == 0 then
        tc(cfg.view == "on screen"
            and "  nothing drawing right now"
            or "  nothing matches", COL_LABEL)
    end

    local delete_me = nil
    for i = 1, shown do
        local row = rows[i]
        local name = row.name
        local at = pure.entry_index(list, name)
        local entry = at and list[at] or nil

        tc(is_live(name) and "*" or " ", is_live(name) and COL_NEW or COL_LABEL)
        imgui.same_line()
        if imgui.button("Flash##row_" .. name) then select_element(name, "flash") end
        imgui.same_line()

        if entry == nil then
            if imgui.button("Hide##row_" .. name) then hide_add(name) end
            imgui.same_line()
            tc("  " .. name, COL_VALUE)
        else
            local changed_on, on = imgui.checkbox("##on_" .. name, entry.on)
            if changed_on then entry.on = on; save_list() end
            imgui.same_line()
            tc("  " .. name, entry.on and COL_NEW or COL_LABEL)
            imgui.same_line()
            -- Always editable, never behind an Edit button: writing down what
            -- an element is, right after flashing it, is the step that makes
            -- the list worth anything to anyone else.
            local changed_label, label = imgui.input_text("##label_" .. name, entry.label)
            if changed_label then entry.label = label; save_list() end
            imgui.same_line()
            if imgui.button("Del##row_" .. name) then delete_me = name end
            if entry.from ~= nil and entry.from ~= "" then
                imgui.same_line()
                tc("  from " .. entry.from, COL_LABEL)
            end
        end
    end
    if delete_me ~= nil then hide_remove(delete_me) end

    local achanged, av = imgui.input_text("hide a name directly", add_buffer)
    if achanged then add_buffer = av end
    imgui.same_line()
    if imgui.button("Add##manual") then
        if hide_add(add_buffer) then add_buffer = "" end
    end
    imgui.same_line()
    if imgui.button("Reload from file") then
        local ok, detail = reload_list()
        share_message = ok and ("reloaded: " .. detail) or ("reload failed: " .. detail)
    end
    imgui.separator()

    if imgui.tree_node("Share a list") then
        -- Scanned when the section is first opened rather than behind a
        -- Refresh press: a file already sitting there should be offered
        -- without being asked for.
        if not share_files_loaded then refresh_share_files() end
        imgui.text("Lists are json files in reframework/data/. Send someone")
        imgui.text("the exported file; they drop it in there and load it.")
        imgui.text("Imported entries arrive switched off, so someone else's")
        imgui.text("list never changes your HUD until you tick it.")
        imgui.text("")

        local echanged, ev = imgui.input_text("export as", export_buffer)
        if echanged then export_buffer = ev end
        imgui.same_line()
        if imgui.button("Save##export") then
            local ok, detail = export_list(export_buffer)
            share_message = ok and ("exported to " .. detail)
                or ("export failed: " .. detail)
        end

        if imgui.button("Refresh##files") then refresh_share_files() end
        imgui.same_line()
        tc(share_files_error or (#share_files .. " json files in data/"), COL_LABEL)
        for _, f in ipairs(share_files) do
            if imgui.button("Load##file_" .. f) then
                local ok, detail = import_list(f)
                share_message = ok and (f .. ": " .. detail)
                    or ("import failed: " .. detail)
            end
            imgui.same_line()
            tc("  " .. f, COL_VALUE)
        end

        local ichanged, iv = imgui.input_text("or load by name", import_buffer)
        if ichanged then import_buffer = iv end
        imgui.same_line()
        if imgui.button("Load##import") then
            local ok, detail = import_list(import_buffer)
            share_message = ok and detail or ("import failed: " .. detail)
        end

        if share_message ~= nil then tc(share_message, COL_VALUE) end
        imgui.tree_pop()
    end
    imgui.separator()

    -- Flash is temporary state, separate from the list. Saying so avoids the
    -- trap of flashing something, seeing it blink, and assuming it is dealt
    -- with.
    if cfg.mode ~= "observe" and cfg.filter ~= "" then
        tc("TEMPORARY: " .. cfg.mode .. " on " .. cfg.filter
           .. "  (not on the hide list)", COL_VALUE)
        imgui.same_line()
        if imgui.button("Stop") then select_element("", "observe") end
        imgui.separator()
    end


    if imgui.tree_node("Manual control") then
        for _, m in ipairs(MODES) do
            if imgui.radio_button(m, cfg.mode == m) then cfg.mode = m; save_cfg() end
            imgui.same_line()
            tc("  " .. MODE_HELP[m], COL_LABEL)
        end
        local fchanged, fv = imgui.input_text("filter (substring)", cfg.filter)
        if fchanged then set_filter(fv) end
        -- A filter matching nothing, or eleven things, should be visible before
        -- a mode is set to hide.
        if cfg.filter ~= "" then
            local hits, lc = {}, cfg.filter:lower()
            for _, rec in pairs(S.seen) do
                if rec.name:lower():find(lc, 1, true) then hits[#hits + 1] = rec.name end
            end
            table.sort(hits)
            tc("  matches " .. #hits .. ": " .. table.concat(hits, ", "),
               #hits == 0 and COL_ALERT or COL_VALUE)
        end
        imgui.tree_pop()
    end
    imgui.separator()

    tc("FINDINGS", COL_LABEL)
    kv("Elements/frame", string.format("%d   min %d   max %d   avg %d",
        stats.last, stats.min or 0, stats.max,
        math.floor(pure.window_mean(stats.window) + 0.5)))
    kv("Address cache", string.format("%s   %d hit / %d miss",
        pure.percent(pure.cache_hit_rate(stats)), stats.cache_hits, stats.cache_misses))
    kv("Elements seen", S.key_count .. " keys, " .. S.name_count .. " names")
    kv("Frames", tostring(stats.frames))

    local collisions = pure.collisions(S.names)
    if #collisions == 0 then
        kv("Collisions", "none", COL_VALUE)
    else
        tc("Collisions: " .. #collisions .. " name(s) carry more than one type", COL_ALERT)
        for _, c in ipairs(collisions) do
            imgui.text("  " .. c.name .. "  ->  " .. table.concat(c.types, ", "))
        end
    end

    local disabled = diag.disabled()
    if #disabled == 0 then
        kv("Probes", "all running", COL_VALUE)
    else
        tc("Probes disabled: " .. table.concat(disabled, ", "), COL_ALERT)
        for _, name in ipairs(disabled) do
            imgui.text("  " .. name .. ": " .. tostring(probes[name].reason))
        end
    end
    kv("Scene / flow changes", #diag.scene_trace .. " / " .. #diag.flow_trace)
    kv("Hide list", #list == 0 and "empty"
        or (hidden_count .. " hidden of " .. #list .. " listed"),
        #list == 0 and COL_LABEL or COL_NEW)

    if imgui.tree_node("Details") then
        imgui.text("package.path = " .. tostring(diag.findings.package_path))
        imgui.text("display = " .. tostring(diag.findings.display_size)
            .. " via " .. tostring(diag.findings.display_size_namespace))
        imgui.text("via.Application methods = "
            .. tostring(diag.findings.application_methods and #diag.findings.application_methods or "?"))
        imgui.text("output = reframework/data/" .. DIAG_FILE)
        imgui.tree_pop()
    end
    imgui.separator()

    tc("DISPLAY", COL_LABEL)
    local changed, v = imgui.checkbox("On-screen overlay", cfg.overlay)
    if changed then cfg.overlay = v; save_cfg() end
    changed, v = imgui.checkbox("Announce new elements", cfg.announce)
    if changed then cfg.announce = v; save_cfg() end
    for _, style in ipairs(OVERLAY_STYLES) do
        if imgui.radio_button("overlay: " .. style, cfg.overlay_style == style) then
            cfg.overlay_style = style; save_cfg()
        end
        imgui.same_line()
        tc(style == "draw" and "  fixed size, small at 4K, always works"
                            or "  uses the REFramework font size, unproven here", COL_LABEL)
    end
    if imgui.button("Dump now") then dump("manual") end
end

re.on_draw_ui(function()
    -- Inside a real ImGui frame, which is the one place calc_text_size is
    -- certain to work. Costs nothing once a measurement exists.
    measure_char_width("on_draw_ui")

    -- The label must not vary. ImGui identifies a tree node by its text, so
    -- folding the mode into it gives the node a new identity whenever the
    -- mode changes, collapsing the panel the instant Flash is pressed.
    if not imgui.tree_node(MOD) then return end

    -- Recorded on the state rather than swallowed, so the tests can assert
    -- a normal render produces no error. Without that, this guard would
    -- hide every future panel bug the way it hides this one from a player.
    local ok, err = pcall(panel_body)
    if ok then
        S.panel_error = nil
    else
        if S.panel_error ~= tostring(err) then
            S.panel_error = tostring(err)
            info("panel error: " .. S.panel_error)
        end
        pcall(imgui.text, "panel error: " .. tostring(S.panel_error))
        pcall(imgui.text, "Hiding still works. Please report this.")
    end
    imgui.tree_pop()
end)

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

diag.at_load()
diag.findings.imgui_missing = check_imgui()
info("loaded " .. VERSION .. " (mode " .. cfg.mode .. ")")

-- Returned for the desktop tests. REFramework ignores an autorun chunk's
-- return value, so this costs nothing in game.
return { pure = pure, state = S, cfg = cfg, list = list, diag = diag,
         rows_for = rows_for, is_live = is_live }
