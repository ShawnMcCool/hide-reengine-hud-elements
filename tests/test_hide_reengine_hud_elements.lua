-- Unit tests for reframework/autorun/hide_reengine_hud_elements.lua
--
-- Run with tools/run-tests. Lua 5.4 explicitly: REFramework embeds 5.4 and the
-- system lua is 5.5.
--
-- These cover the pure logic and the callback behaviour that can be driven from
-- the desktop. Engine integration -- whether returning false actually hides an
-- element, whether the scene probe fires on a real load -- is verified by
-- playing the game against the session checklist, and is never called tested.

package.path = "tests/?.lua;reframework/autorun/?.lua;" .. package.path
local stub = require("stub_reframework")

local failures, checks = 0, 0
local function check(name, cond, detail)
    checks = checks + 1
    if not cond then
        failures = failures + 1
        io.write("  FAIL  ", name, detail and ("  -- " .. tostring(detail)) or "", "\n")
    end
end
local function eq(name, got, want)
    check(name, got == want, string.format("got %s, want %s", tostring(got), tostring(want)))
end
local function group(name) io.write(name, "\n") end

local function load_logger(opts)
    local env = stub.install(opts)
    local chunk, err = loadfile("reframework/autorun/hide_reengine_hud_elements.lua")
    if chunk == nil then error("loadfile failed: " .. tostring(err)) end
    local ok, result = pcall(chunk)
    return env, ok, result
end

-- ---------------------------------------------------------------------------
group("loads under stubs")
-- ---------------------------------------------------------------------------
local env, ok, L = load_logger({ app_methods = { "UpdateBehavior", "BeginRendering" } })
check("chunk runs without error", ok, ok and "" or L)
if not ok then
    io.write("cannot continue: logger failed to load\n")
    os.exit(1)
end
check("registers the draw callback", env.callbacks.on_pre_gui_draw_element ~= nil)
check("registers on_frame", env.callbacks.on_frame ~= nil)
check("registers on_draw_ui", env.callbacks.on_draw_ui ~= nil)
check("registers on_script_reset", env.callbacks.on_script_reset ~= nil)
check("enumerated via.Application methods", L.diag.findings.application_methods ~= nil)
eq("enumerated method count", #(L.diag.findings.application_methods or {}), 2)
check("recorded package.path", L.diag.findings.package_path ~= nil)
check("the mod requires a real module at load", L.pure ~= nil)

local pure = L.pure

-- ---------------------------------------------------------------------------
group("element keys")
-- ---------------------------------------------------------------------------
local k = pure.key_of("Bar", "via.gui.Text")
check("key separates name from type", k ~= "Barvia.gui.Text")
eq("name recovered from key", pure.name_of_key(k), "Bar")
eq("name recovered when key has no type", pure.name_of_key("Bare"), "Bare")
check("same name different type gives different keys",
    pure.key_of("Bar", "via.gui.Text") ~= pure.key_of("Bar", "via.gui.Rect"))

-- ---------------------------------------------------------------------------
group("collisions")
-- ---------------------------------------------------------------------------
local names = {}
eq("first type is new", pure.note_type(names, "Bar", "via.gui.Text"), true)
eq("repeat type is not new", pure.note_type(names, "Bar", "via.gui.Text"), false)
eq("second type is new", pure.note_type(names, "Bar", "via.gui.Rect"), true)
pure.note_type(names, "Solo", "via.gui.Text")
local coll = pure.collisions(names)
eq("one colliding name", #coll, 1)
eq("collision names the right element", coll[1].name, "Bar")
eq("collision lists both types", #coll[1].types, 2)
eq("collision types sorted", coll[1].types[1], "via.gui.Rect")

-- ---------------------------------------------------------------------------
group("transform paths")
-- ---------------------------------------------------------------------------
eq("leaf-first walk becomes root-first path",
    pure.join_path({ "Leaf", "Mid", "Root" }), "Root/Mid/Leaf")
eq("single segment", pure.join_path({ "Only" }), "Only")
eq("empty walk is nil", pure.join_path({}), nil)

-- ---------------------------------------------------------------------------
group("frame statistics")
-- ---------------------------------------------------------------------------
local st = pure.new_stats(3)
pure.record_frame(st, 10)
pure.record_frame(st, 30)
pure.record_frame(st, 20)
eq("frames counted", st.frames, 3)
eq("last", st.last, 20)
eq("min", st.min, 10)
eq("max", st.max, 30)
eq("mean over full window", pure.window_mean(st.window), 20)
pure.record_frame(st, 60)
eq("window evicts the oldest", pure.window_mean(st.window), (30 + 20 + 60) / 3)
eq("max survives eviction", st.max, 60)

local zero = pure.new_stats(3)
eq("mean of no frames is zero", pure.window_mean(zero.window), 0)
eq("hit rate with no traffic is zero", pure.cache_hit_rate(zero), 0)
zero.cache_hits, zero.cache_misses = 3, 1
eq("hit rate", pure.cache_hit_rate(zero), 0.75)
eq("percent rounds", pure.percent(0.75), "75%")

-- ---------------------------------------------------------------------------
group("probes")
-- ---------------------------------------------------------------------------
local p = pure.new_probe("scene")
eq("probe starts enabled", p.disabled, false)
pure.probe_failed(p, "boom")
eq("probe disables", p.disabled, true)
eq("probe records the reason", p.reason, "boom")
local summary = pure.probe_summary({ a = p, b = pure.new_probe("flow") })
eq("only disabled probes summarised", #summary, 1)
eq("summary names the probe", summary[1], "scene")

local trace = {}
eq("trace accepts within cap", pure.push_trace(trace, { frame = 1 }, 2), true)
pure.push_trace(trace, { frame = 2 }, 2)
eq("trace refuses beyond cap", pure.push_trace(trace, { frame = 3 }, 2), false)
eq("trace stays at cap", #trace, 2)

-- ---------------------------------------------------------------------------
group("draw callback")
-- ---------------------------------------------------------------------------
local hot = env.callbacks.on_pre_gui_draw_element
local S = L.state

local a = stub.element(0x1000, "EnemyGauge", "via.gui.Control", { "EnemyGauge", "HUD" })
eq("first draw returns true", hot(a), true)
eq("element recorded", S.key_count, 1)
eq("cache missed once", S.stats.cache_misses, 1)
eq("first draw is not a hit", S.stats.cache_hits, 0)

eq("second draw returns true", hot(a), true)
eq("second draw hits the cache", S.stats.cache_hits, 1)
eq("second draw adds no key", S.key_count, 1)

local rec = S.seen[pure.key_of("EnemyGauge", "via.gui.Control")]
check("record exists for the key", rec ~= nil)
eq("record keeps the name", rec and rec.name, "EnemyGauge")
eq("record keeps the type", rec and rec.type, "via.gui.Control")
eq("record keeps the root-first path", rec and rec.path, "HUD/EnemyGauge")

local b = stub.element(0x2000, "EnemyGauge", "via.gui.Text", { "EnemyGauge" })
hot(b)
eq("same name new type is a new key", S.key_count, 2)
eq("collision recorded", #pure.collisions(S.names), 1)

-- An element that cannot be identified must still draw, and must not be
-- re-reflected on every frame it appears.
local bad = stub.element(0x3000, nil, nil, nil, true)
eq("unidentifiable element still draws", hot(bad), true)
local misses_after_first_bad = S.stats.cache_misses
eq("unidentifiable element draws again", hot(bad), true)
eq("failure is cached, not re-reflected", S.stats.cache_misses, misses_after_first_bad)

-- ---------------------------------------------------------------------------
group("element counting")
-- ---------------------------------------------------------------------------
local env2, ok2, L2 = load_logger({})
check("second instance loads", ok2, ok2 and "" or L2)
local hot2 = env2.callbacks.on_pre_gui_draw_element
local good = stub.element(0xA000, "Good", "via.gui.Control", { "Good" })
local broken = stub.element(0xB000, nil, nil, nil, true)
hot2(good)
hot2(broken)
hot2(broken)
env2.callbacks.on_frame()
eq("count includes elements that failed identification", L2.state.stats.last, 3)
eq("only one element was identifiable", L2.state.key_count, 1)

-- ---------------------------------------------------------------------------
group("output")
-- ---------------------------------------------------------------------------
local dumped
for _, d in ipairs(env2.dumps) do
    if d.name == "hide_reengine_hud_elements_diagnostics.json" then dumped = d.data end
end
if dumped == nil then
    -- Force one through the panel's Dump now path by running enough frames.
    for _ = 1, 600 do env2.callbacks.on_frame() end
    for _, d in ipairs(env2.dumps) do
        if d.name == "hide_reengine_hud_elements_diagnostics.json" then dumped = d.data end
    end
end
check("an output dump was produced", dumped ~= nil)
if dumped ~= nil then
    eq("schema is 2", dumped.schema, 2)
    check("has stats", dumped.stats ~= nil)
    check("has elements", dumped.elements ~= nil)
    check("has names", dumped.names ~= nil)
    check("has collisions", dumped.collisions ~= nil)
    check("has probes", dumped.probes ~= nil)
    check("probes carry findings", dumped.probes.findings ~= nil)
    check("probes carry state", dumped.probes.state ~= nil)
    check("probes carry the scene trace", dumped.probes.scene_trace ~= nil)
    check("probes carry the flow trace", dumped.probes.flow_trace ~= nil)
    check("stats carry the hit rate", dumped.stats.cache_hit_rate ~= nil)
end

env2.restore()

-- ---------------------------------------------------------------------------
group("transition polling")
-- ---------------------------------------------------------------------------
-- A detected change must be recorded once. Re-detecting the same change every
-- frame would clear the cache and flood the log sixty times a second, which is
-- the failure the whole self-disabling design exists to avoid.
local topts = { scene_singleton = {}, scene = 0x11110000,
                flow_singleton = stub.flow({ get_IsMainMenu = true }) }
local env3, ok3, L3 = load_logger(topts)
check("third instance loads", ok3, ok3 and "" or L3)
local tick = env3.callbacks.on_frame

for _ = 1, 3 do tick() end
eq("no scene transition without a change", #L3.diag.scene_trace, 0)
eq("no flow transition without a change", #L3.diag.flow_trace, 0)

topts.scene = 0x22220000
for _ = 1, 5 do tick() end
eq("scene change recorded exactly once", #L3.diag.scene_trace, 1)
eq("transition records the frame", type(L3.diag.scene_trace[1].frame), "number")

topts.flow_singleton = stub.flow({ get_IsIngame = true })
for _ = 1, 5 do tick() end
eq("flow change recorded exactly once", #L3.diag.flow_trace, 1)

topts.scene = 0x33330000
for _ = 1, 4 do tick() end
eq("a second scene change is also recorded once", #L3.diag.scene_trace, 2)

-- The scene probe must survive a singleton that hands back a bare address.
check("scene probe still running", L3.diag.probes.scene.disabled == false,
    L3.diag.probes.scene.reason)
env3.restore()

-- ---------------------------------------------------------------------------
group("filter and modes")
-- ---------------------------------------------------------------------------
-- Returning false is the shipped mod's whole hiding mechanism, and the filter
-- is how a candidate is selected before it is hidden. A saved config must
-- reach both without the panel being opened.
local env4, ok4, L4 = load_logger({ config = { mode = "hide", filter = "gauge" } })
check("fourth instance loads", ok4, ok4 and "" or L4)
eq("mode read from config", L4.cfg.mode, "hide")
eq("filter read from config", L4.cfg.filter, "gauge")

local hot4 = env4.callbacks.on_pre_gui_draw_element
local target = stub.element(0xC000, "EnemyGauge", "via.gui.Control", { "EnemyGauge" })
local other = stub.element(0xD000, "PlayerHealth", "via.gui.Control", { "PlayerHealth" })
eq("matching element is hidden", hot4(target), false)
eq("non-matching element still draws", hot4(other), true)
eq("match is case insensitive", hot4(stub.element(0xE000, "BOSSGAUGE",
    "via.gui.Control", { "BOSSGAUGE" })), false)

-- Even while hiding, discovery keeps running: the hidden element is recorded.
check("hidden element was still recorded",
    L4.state.seen[pure.key_of("EnemyGauge", "via.gui.Control")] ~= nil)
eq("hidden elements still counted", (function()
    env4.callbacks.on_frame(); return L4.state.stats.last end)(), 3)

-- An unidentifiable element must draw even when a filter is hiding things.
eq("fail-open survives hide mode",
    hot4(stub.element(0xF000, nil, nil, nil, true)), true)
env4.restore()

-- ---------------------------------------------------------------------------
group("panel")
-- ---------------------------------------------------------------------------
-- The panel is the only way to change anything at runtime, so it has to render.
-- Its body is entered here, which is what catches a function referenced before
-- it is defined -- the kind of slip that otherwise costs a play session.
local env5, ok5, L5 = load_logger({})
check("fifth instance loads", ok5, ok5 and "" or L5)
local hot5 = env5.callbacks.on_pre_gui_draw_element
hot5(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" }))
hot5(stub.element(0x2, "GUI020210", "via.gui.GUI", { "GUI020210" }))
hot5(stub.element(0x3, "GUI030400", "via.gui.GUI", { "GUI030400" }))

local drew, perr = pcall(env5.callbacks.on_draw_ui)
check("panel renders without error", drew, perr)
-- The pcall guard means a nil call inside the panel no longer throws, so the
-- check above would pass with the exact bug that reached the game. This is the
-- one that catches it.
check("panel body threw nothing", L5.state.panel_error == nil, L5.state.panel_error)

-- Newest first: the element that just appeared is the one being hunted.
local recent = L5.state.order
eq("order records every key", #recent, 3)
eq("order is first-sight order", pure.name_of_key(recent[3]), "GUI030400")

-- Clicking a candidate must set the filter, since the names are unusable ids
-- and typing them by hand is what made the tool unusable in the first place.
-- Flash and Hide are one gesture each: they pick the element and enter the
-- mode together. Splitting that across a text box and a radio list is what
-- made the tool unusable on first contact.
env5.opts.click = "Flash##row_GUI020210"
local clicked, cerr = pcall(env5.callbacks.on_draw_ui)
check("panel renders with a click", clicked, cerr)
eq("Flash selects the element", L5.cfg.filter, "GUI020210")
eq("Flash enters flash mode", L5.cfg.mode, "flash")

-- Stop has to be reachable, because it is how a player leaves a temporary mode.
env5.opts.click = "Stop"
pcall(env5.callbacks.on_draw_ui)
eq("Stop clears the filter", L5.cfg.filter, "")
eq("Stop returns to observe", L5.cfg.mode, "observe")
env5.opts.click = nil

-- With nothing hidden the Stop button is absent, so a stray click cannot
-- reach it and the state line reads as recording.
env5.opts.click = "Stop"
pcall(env5.callbacks.on_draw_ui)
eq("Stop is absent while observing", L5.cfg.mode, "observe")
env5.opts.click = nil

-- ImGui identifies a tree node by its label, so a label that varies gives the
-- node a new identity and collapses it. Pressing Flash must not shut the panel.
env5.tree_labels = {}
pcall(env5.callbacks.on_draw_ui)
local label_before = env5.tree_labels[1]
env5.opts.click = "Flash##row_GUI020102"
pcall(env5.callbacks.on_draw_ui)
env5.opts.click = nil
env5.tree_labels = {}
pcall(env5.callbacks.on_draw_ui)
eq("the mode changed", L5.cfg.mode, "flash")
eq("the panel's label does not change with it", env5.tree_labels[1], label_before)
env5.restore()

-- Three separate crashes came from calling an imgui function this build does
-- not bind. The panel must now render fully with any one of them missing,
-- because a `strings` grep cannot tell a Lua binding from ImGui's own C symbol
-- and the inherited list of "confirmed" bindings was never exercised.
for _, missing in ipairs({ "radio_button", "checkbox", "button", "input_text",
                           "text_colored", "same_line", "separator", "text",
                           "tree_node", "tree_pop" }) do
    local envX, okX, LX = load_logger({ remove = { missing } })
    check("loads without imgui." .. missing, okX, okX and "" or LX)
    if okX then
        local hotX = envX.callbacks.on_pre_gui_draw_element
        hotX(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" }))
        local drewX, errX = pcall(envX.callbacks.on_draw_ui)
        check("panel survives a missing imgui." .. missing, drewX, errX)
        check("and reports no error without imgui." .. missing,
            LX.state.panel_error == nil, LX.state.panel_error)
        -- Hiding is the product. It must not depend on the interface at all.
        eq("hiding still works without imgui." .. missing,
            hotX(stub.element(0x2, "OTHER", "via.gui.GUI", { "OTHER" })), true)
        envX.restore()
    end
end

-- tree_pop is still called unconditionally, which is what keeps a logic error
-- inside the panel from unbalancing Dear ImGui and taking out REFramework's
-- whole window rather than just this panel.
local env13, ok13, L13 = load_logger({})
check("thirteenth instance loads", ok13, ok13 and "" or L13)
env13.tree_pops = 0
pcall(env13.callbacks.on_draw_ui)
check("tree_pop ran", env13.tree_pops > 0)
env13.restore()

-- Every imgui binding the panel calls must exist. The strings grep that said
-- new_line was present is why this is checked against the engine instead.
local env14, ok14, L14 = load_logger({})
check("fourteenth instance loads", ok14, ok14 and "" or L14)
eq("no imgui bindings are missing under the stub",
    #(L14.diag.findings.imgui_missing or {}), 0)
pcall(env14.callbacks.on_draw_ui)
check("a full panel render throws nothing", L14.state.panel_error == nil,
    L14.state.panel_error)
check("the panel never calls imgui.new_line",
    _G.imgui == nil or _G.imgui.new_line == nil)
env14.restore()

-- ---------------------------------------------------------------------------
group("overlay style")
-- ---------------------------------------------------------------------------
-- The imgui overlay is unproven on this build. If it throws it must fall back
-- and persist the fallback, so a setting that does not work here cannot come
-- back on the next launch and cost another session.
local env6, ok6, L6 = load_logger({ config = { overlay_style = "imgui" } })
check("sixth instance loads", ok6, ok6 and "" or L6)
eq("imgui overlay style read from config", L6.cfg.overlay_style, "imgui")
env6.callbacks.on_frame()
eq("working imgui overlay is kept", L6.cfg.overlay_style, "imgui")
env6.restore()

local env7, ok7, L7 = load_logger({ config = { overlay_style = "imgui" },
                                    no_windows = true })
check("seventh instance loads", ok7, ok7 and "" or L7)
local ferr
ok7, ferr = pcall(env7.callbacks.on_frame)
check("a failing imgui overlay does not propagate", ok7, ferr)
eq("failure reverts to the draw overlay", L7.cfg.overlay_style, "draw")
local saved
for _, d in ipairs(env7.dumps) do
    if d.name == "hide_reengine_hud_elements.json" then saved = d.data end
end
check("the revert is saved to config", saved ~= nil and saved.overlay_style == "draw",
    saved and saved.overlay_style)
env7.restore()

-- ---------------------------------------------------------------------------
group("hide list entries")
-- ---------------------------------------------------------------------------
local entries = {}
eq("add returns true", pure.entry_add(entries, pure.new_entry("GUI020102")), true)
eq("duplicate name is refused",
    pure.entry_add(entries, pure.new_entry("GUI020102", "other")), false)
eq("empty name is refused", pure.entry_add(entries, pure.new_entry("")), false)
eq("nil entry is refused", pure.entry_add(entries, nil), false)
eq("new entries default to on", entries[1].on, true)
eq("new entries default to an empty label", entries[1].label, "")

pure.entry_add(entries, pure.new_entry("GUI030400", "rift prompt"))
eq("two entries", #entries, 2)
eq("label kept", entries[2].label, "rift prompt")
eq("index finds an entry", pure.entry_index(entries, "GUI030400"), 2)
eq("index of an absent name is nil", pure.entry_index(entries, "nope"), nil)

-- Only entries switched on hide anything.
eq("both active", pure.count_active(entries), 2)
entries[1].on = false
eq("switching one off leaves one active", pure.count_active(entries), 1)
local set = pure.active_set(entries)
eq("the off entry is not in the set", set["GUI020102"], nil)
eq("the on entry is in the set", set["GUI030400"], true)

eq("remove returns true", pure.entry_remove(entries, "GUI020102"), true)
eq("remove of an absent name is false", pure.entry_remove(entries, "GUI020102"), false)
eq("one left", #entries, 1)

-- The file must stay comfortable to edit by hand, and one unusable line must
-- never take the rest of the list down with it.
local cleaned = pure.clean_entries({
    "GUI1",
    { name = "GUI2", label = "a label", on = false },
    42, "", {}, { name = "GUI1" },
})
eq("clean keeps the usable entries", #cleaned, 2)
eq("a bare string becomes an entry", cleaned[1].name, "GUI1")
eq("a bare string has no label", cleaned[1].label, "")
eq("a bare string is on", cleaned[1].on, true)
eq("a record keeps its label", cleaned[2].label, "a label")
eq("a record keeps being off", cleaned[2].on, false)
eq("clean of a non-table is empty", #pure.clean_entries("nope"), 0)

-- ---------------------------------------------------------------------------
group("sharing")
-- ---------------------------------------------------------------------------
-- Someone else's list must never change what is on screen just by loading.
local mine = { pure.new_entry("GUI020102", "", true) }
local theirs = {
    pure.new_entry("GUI020102", "X prompt over exhausted enemy", true),
    pure.new_entry("GUI030400", "rift absorb prompt", true),
}
local added, labelled = pure.merge_entries(mine, theirs, "friend.hudlist.json")
eq("one entry was new", added, 1)
eq("one entry gained a label", labelled, 1)
eq("the list grew by one", #mine, 2)
eq("an imported entry arrives switched off", mine[2].on, false)
eq("an imported entry records where it came from", mine[2].from, "friend.hudlist.json")
eq("my own entry kept its on state", mine[1].on, true)
eq("my own unlabelled entry gained their label",
    mine[1].label, "X prompt over exhausted enemy")

local kept = { pure.new_entry("GUI020102", "my own words", true) }
pure.merge_entries(kept, theirs, "friend.hudlist.json")
eq("an existing label is not overwritten", kept[1].label, "my own words")

-- ---------------------------------------------------------------------------
group("hiding end to end")
-- ---------------------------------------------------------------------------
-- The list must arrive from the config file and hide immediately, with no
-- panel interaction: that is what "it stays on until I remove it" means.
local env8, ok8, L8 = load_logger({ hide_list = {
    { name = "GUI020102", label = "X prompt", on = true },
    { name = "GUI030400", label = "off for now", on = false },
} })
check("eighth instance loads", ok8, ok8 and "" or L8)
eq("list restored from its own file", #L8.list, 2)
eq("label survived the round trip", L8.list[1].label, "X prompt")

local hot8 = env8.callbacks.on_pre_gui_draw_element
eq("an active entry does not draw",
    hot8(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" })), false)
eq("an entry switched off still draws",
    hot8(stub.element(0x2, "GUI030400", "via.gui.GUI", { "GUI030400" })), true)
eq("an unlisted element draws",
    hot8(stub.element(0x3, "GUI020210", "via.gui.GUI", { "GUI020210" })), true)
eq("a hidden element is still recorded",
    L8.state.seen[pure.key_of("GUI020102", "via.gui.GUI")] ~= nil, true)
eq("fail-open beats the hide list",
    hot8(stub.element(0x4, nil, nil, nil, true)), true)

-- Flash overrides the list, so an entry can be identified without being taken
-- off it first.
env8.opts.click = "Flash##row_GUI020102"
pcall(env8.callbacks.on_draw_ui)
env8.opts.click = nil
eq("Flash works on an element already hidden", L8.cfg.mode, "flash")
eq("Flash targets it", L8.cfg.filter, "GUI020102")

local seen_true, seen_false = false, false
for _ = 1, 60 do
    env8.callbacks.on_frame()
    if hot8(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" })) then
        seen_true = true
    else
        seen_false = true
    end
end
check("flash blinks a listed element on", seen_true)
check("flash blinks a listed element off", seen_false)
env8.restore()

-- ---------------------------------------------------------------------------
group("panel list actions")
-- ---------------------------------------------------------------------------
local env9, ok9, L9 = load_logger({ files = {
    ["friend.hudlist.json"] = { format = "hide-reengine-hud-elements-list", version = 1,
        entries = { { name = "GUI099999", label = "someone else's find", on = true } } },
} })
check("ninth instance loads", ok9, ok9 and "" or L9)
local hot9 = env9.callbacks.on_pre_gui_draw_element
hot9(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" }))

env9.opts.click = "Hide##row_GUI020102"
pcall(env9.callbacks.on_draw_ui)
eq("Add puts the element on the list", L9.list[1].name, "GUI020102")
eq("added element stops drawing",
    hot9(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" })), false)

local persisted
for _, d in ipairs(env9.dumps) do
    if d.name == "hide_reengine_hud_elements_list.json" then persisted = d.data end
end
check("the list is written to its own file",
    persisted ~= nil and persisted[1] ~= nil and persisted[1].name == "GUI020102")

-- Loading a shared list adds to it without changing what is on screen.
env9.opts.click = "Load##file_friend.hudlist.json"
pcall(env9.callbacks.on_draw_ui)
eq("the shared entry was added", #L9.list, 2)
eq("the shared entry is switched off", L9.list[2].on, false)
eq("the shared entry kept its label", L9.list[2].label, "someone else's find")
eq("the shared element still draws",
    hot9(stub.element(0x5, "GUI099999", "via.gui.GUI", { "GUI099999" })), true)

-- Export writes a file that import can read back.
env9.opts.click = "Save##export"
pcall(env9.callbacks.on_draw_ui)
local exported
for _, d in ipairs(env9.dumps) do
    if d.name ~= "hide_reengine_hud_elements.json"
        and d.name ~= "hide_reengine_hud_elements_list.json"
        and d.name ~= "hide_reengine_hud_elements_diagnostics.json" then
        exported = d.data
    end
end
check("export wrote a list file", exported ~= nil)
if exported ~= nil then
    eq("export is tagged with the format", exported.format, "hide-reengine-hud-elements-list")
    eq("export carries both entries", #exported.entries, 2)
    eq("export carries labels", exported.entries[2].label, "someone else's find")
end

env9.opts.click = "Del##row_GUI020102"
pcall(env9.callbacks.on_draw_ui)
eq("Del removes the entry", pure.entry_index(L9.list, "GUI020102"), nil)
eq("removed element draws again",
    hot9(stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" })), true)
env9.opts.click = nil
env9.restore()

-- The tool must work where fs.glob does not, since its filter syntax is
-- unverified on this build.
local env10, ok10, L10 = load_logger({ no_fs = true })
check("tenth instance loads without fs", ok10, ok10 and "" or L10)
local nofs, nofserr = pcall(env10.callbacks.on_draw_ui)
check("the panel renders without fs.glob", nofs, nofserr)
check("and throws nothing", L10.state.panel_error == nil, L10.state.panel_error)
env10.restore()

-- Hand-editing the list file while the game runs is a trap without this: the
-- in-memory copy is written back on the next panel action, discarding whatever
-- was typed into the file.
local env15, ok15, L15 = load_logger({ hide_list = {
    { name = "FROM_FILE", label = "typed in by hand", on = true },
} })
check("fifteenth instance loads", ok15, ok15 and "" or L15)
eq("started from the file", L15.list[1].name, "FROM_FILE")

-- The file changes underneath the running mod.
env15.opts.hide_list = {
    { name = "EDITED", label = "added by hand while running", on = true },
}
env15.opts.click = "Reload from file"
pcall(env15.callbacks.on_draw_ui)
env15.opts.click = nil
eq("reload replaces the list", #L15.list, 1)
eq("with what the file now says", L15.list[1].name, "EDITED")
eq("labels come back too", L15.list[1].label, "added by hand while running")

local hot15 = env15.callbacks.on_pre_gui_draw_element
eq("the reloaded entry hides",
    hot15(stub.element(0x1, "EDITED", "via.gui.GUI", { "EDITED" })), false)
eq("the replaced entry no longer hides",
    hot15(stub.element(0x2, "FROM_FILE", "via.gui.GUI", { "FROM_FILE" })), true)
env15.restore()

-- Element addresses are recycled, so the cache must be bounded in time and not
-- only by load transitions. On a game without app.GameFlowManager -- which is
-- every game but this one -- transitions may never fire at all.
local env16, ok16, L16 = load_logger({})
check("sixteenth instance loads", ok16, ok16 and "" or L16)
local hot16 = env16.callbacks.on_pre_gui_draw_element
local el = stub.element(0x7000, "RECYCLED", "via.gui.GUI", { "RECYCLED" })
hot16(el)
local misses_before = L16.state.stats.cache_misses
for _ = 1, 60 do hot16(el) end
eq("a cached address is not re-reflected",
    L16.state.stats.cache_misses, misses_before)

-- Run past the time bound with no transition of any kind.
for _ = 1, 300 do env16.callbacks.on_frame() end
hot16(el)
check("the cache is rebuilt on the timer",
    L16.state.stats.cache_misses > misses_before)

-- And it stays quiet about it: the log is the only artefact a bug report has.
local noisy = 0
for _, line in ipairs(env16.logged) do
    if tostring(line):find("cache cleared", 1, true) then noisy = noisy + 1 end
end
eq("periodic clearing does not fill the log", noisy, 0)
env16.restore()

-- ---------------------------------------------------------------------------
group("finding")
-- ---------------------------------------------------------------------------
-- The strongest finding aid the tool has: pause with the thing on screen, and
-- only what is drawing right now is listed. This is what makes the search a
-- handful of rows instead of the whole session.
local env11, ok11, L11 = load_logger({})
check("eleventh instance loads", ok11, ok11 and "" or L11)
local hot11 = env11.callbacks.on_pre_gui_draw_element
local function draw(addr, name)
    return hot11(stub.element(addr, name, "via.gui.GUI", { name }))
end

draw(0x1, "ALWAYS")
draw(0x2, "BRIEF")
eq("something that just drew is on screen", L11.is_live("ALWAYS"), true)

-- BRIEF stops drawing; ALWAYS keeps going. After the grace period only one of
-- them should still be listed as on screen.
for _ = 1, 30 do
    env11.callbacks.on_frame()
    draw(0x1, "ALWAYS")
end
eq("an element still drawing stays on screen", L11.is_live("ALWAYS"), true)
eq("an element that stopped drawing leaves", L11.is_live("BRIEF"), false)
eq("an element never seen is not on screen", L11.is_live("NOPE"), false)

local on_screen = L11.rows_for("on screen", "")
eq("on screen lists only what is drawing", #on_screen, 1)
eq("and it is the right one", on_screen[1].name, "ALWAYS")
eq("everything still lists both", #L11.rows_for("everything", ""), 2)

-- Reset, then make something happen: the new view is only what appeared since.
L11.state.mark = L11.state.stats.frames
env11.callbacks.on_frame()
draw(0x3, "AFTER_MARK")
local fresh = L11.rows_for("new", "")
eq("new lists only what appeared after the mark", #fresh, 1)
eq("and it is the new one", fresh[1].name, "AFTER_MARK")

eq("search narrows the list", #L11.rows_for("everything", "brief"), 1)
eq("search is case insensitive", L11.rows_for("everything", "BrIeF")[1].name, "BRIEF")
eq("search that matches nothing is empty", #L11.rows_for("everything", "zzz"), 0)
env11.restore()

-- An imported entry has never drawn here, and must still be reachable to be
-- switched off or deleted.
local env12, ok12, L12 = load_logger({ hide_list = {
    { name = "NEVER_SEEN_HERE", label = "someone else's find", on = false },
} })
check("twelfth instance loads", ok12, ok12 and "" or L12)
local hidden_view = L12.rows_for("hidden", "")
eq("the hidden view includes an entry never seen", #hidden_view, 1)
eq("and names it", hidden_view[1].name, "NEVER_SEEN_HERE")
eq("it is absent from on screen", #L12.rows_for("on screen", ""), 0)
eq("everything includes it too", #L12.rows_for("everything", ""), 1)

-- A listed element that has also been seen must appear once, not twice.
local hot12 = env12.callbacks.on_pre_gui_draw_element
hot12(stub.element(0x1, "NEVER_SEEN_HERE", "via.gui.GUI", { "NEVER_SEEN_HERE" }))
eq("a seen listed element is not duplicated", #L12.rows_for("everything", ""), 1)
env12.restore()

-- ---------------------------------------------------------------------------
io.write(string.format("\n%d checks, %d failed\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
