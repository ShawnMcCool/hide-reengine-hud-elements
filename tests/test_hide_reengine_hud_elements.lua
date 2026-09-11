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

-- A probe that answers nothing is as useless as one that throws, and neither
-- of the two scene probes raises when it has nothing: they return nil forever.
-- On another RE Engine title that is the expected case, so retiring on failure
-- alone would leave a dead probe being asked sixty times a second.
local barren = pure.new_probe("scene")
for i = 1, pure.BARREN_POLLS do
    barren.ran = i
    pure.probe_result(barren, nil)
end
eq("a probe that never answers retires", barren.disabled, true)
check("and says why", tostring(barren.reason):find("no value", 1, true) ~= nil,
    barren.reason)

local answering = pure.new_probe("flow")
for i = 1, pure.BARREN_POLLS * 2 do
    answering.ran = i
    pure.probe_result(answering, i == 1 and "110" or nil)
end
eq("a probe that answered once is never retired for silence",
    answering.disabled, false)

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

-- The probes are polled four times a second, not sixty, so a step here has to
-- run enough frames to contain several polls. That cadence is also what
-- debounces the load bounce -- 110 -> 000 -> 001 two frames apart -- into the
-- single transition it actually is.
local POLL_SPAN = 15
local function polls(n) for _ = 1, n * POLL_SPAN do tick() end end

polls(3)
eq("no scene transition without a change", #L3.diag.scene_trace, 0)
eq("no flow transition without a change", #L3.diag.flow_trace, 0)

topts.scene = 0x22220000
polls(5)
eq("scene change recorded exactly once", #L3.diag.scene_trace, 1)
eq("transition records the frame", type(L3.diag.scene_trace[1].frame), "number")

topts.flow_singleton = stub.flow({ get_IsIngame = true })
polls(5)
eq("flow change recorded exactly once", #L3.diag.flow_trace, 1)

topts.scene = 0x33330000
polls(4)
eq("a second scene change is also recorded once", #L3.diag.scene_trace, 2)

-- Sixty frames of play must not be sixty polls.
eq("polled once per span, not once per frame", L3.diag.probes.scene.ran, 17)

-- The scene probe must survive a singleton that hands back a bare address.
check("scene probe still running", L3.diag.probes.scene.disabled == false,
    L3.diag.probes.scene.reason)
env3.restore()

-- ---------------------------------------------------------------------------
group("finding and playing")
-- ---------------------------------------------------------------------------
-- Playing is the hide list and nothing else: no probes, no feed, no dump.
--
-- What it must not stop is observing. A player switches to Playing and keeps
-- playing; when the next thing annoys them they open the panel expecting to
-- see what just drew, and an empty browser would mean going away and making it
-- happen all over again.
local env4, ok4, L4 = load_logger({
    config = { finding = false },
    scene_singleton = {}, scene = 0x11110000,
    flow_singleton = stub.flow({ get_IsMainMenu = true }),
    hide_list = { { name = "EnemyGauge", label = "the gauge", on = true } },
})
check("fourth instance loads", ok4, ok4 and "" or L4)
eq("playing read from config", L4.cfg.finding, false)

local hot4 = env4.callbacks.on_pre_gui_draw_element
local target = stub.element(0xC000, "EnemyGauge", "via.gui.Control", { "EnemyGauge" })
local other = stub.element(0xD000, "PlayerHealth", "via.gui.Control", { "PlayerHealth" })
eq("a listed element is hidden while playing", hot4(target), false)
eq("an unlisted element still draws", hot4(other), true)
eq("fail-open survives while playing",
    hot4(stub.element(0xF000, nil, nil, nil, true)), true)

-- Observation continues.
check("elements are still recorded while playing",
    L4.state.seen[pure.key_of("PlayerHealth", "via.gui.Control")] ~= nil)
eq("and are still on screen while playing", L4.is_live("PlayerHealth"), true)
eq("hidden elements are still counted", (function()
    env4.callbacks.on_frame(); return L4.state.stats.last end)(), 3)

-- The transform walk is up to sixteen reflection calls and answers nothing a
-- player reads, so it is the one thing observation gives up while playing.
eq("the transform walk is skipped while playing",
    L4.state.seen[pure.key_of("PlayerHealth", "via.gui.Control")].path, nil)

-- Long enough to pass both the poll cadence and the periodic dump.
for _ = 1, 700 do env4.callbacks.on_frame() end
eq("the scene probe is never polled while playing", L4.diag.probes.scene.ran, 0)
eq("nor the flow probe", L4.diag.probes.flow.ran, 0)
local wrote_diag = false
for _, d in ipairs(env4.dumps) do
    if d.name == "hide_reengine_hud_elements_diagnostics.json" then wrote_diag = true end
end
check("no diagnostics file is written while playing", not wrote_diag)

-- The cache is still bounded in time, because a recycled address hiding the
-- wrong element is the one failure this mod must not have -- and it is exactly
-- the failure a player would meet while playing rather than while finding.
local misses_before_expiry = L4.state.stats.cache_misses
hot4(target)
check("the cache still expires while playing",
    L4.state.stats.cache_misses > misses_before_expiry, L4.state.stats.cache_misses)

env4.opts.click = "Finding"
pcall(env4.callbacks.on_draw_ui)
env4.opts.click = nil
eq("the panel switches back to finding", L4.cfg.finding, true)

-- Pressing the option already selected must not write the config, or holding
-- the panel open would rewrite it sixty times a second.
local cfg_writes_before = 0
for _, d in ipairs(env4.dumps) do
    if d.name == "hide_reengine_hud_elements.json" then
        cfg_writes_before = cfg_writes_before + 1
    end
end
env4.opts.click = "Finding"
pcall(env4.callbacks.on_draw_ui)
env4.opts.click = nil
local cfg_writes_after = 0
for _, d in ipairs(env4.dumps) do
    if d.name == "hide_reengine_hud_elements.json" then
        cfg_writes_after = cfg_writes_after + 1
    end
end
eq("choosing the state already in force saves nothing",
    cfg_writes_after - cfg_writes_before, 0)
env4.restore()

-- radio_button is absent in REFramework 01417, so in game the switch is really
-- a button carrying its own state. That is the path a player presses.
local env4b, ok4b, L4b = load_logger({ config = { finding = true },
                                       remove = { "radio_button" } })
check("switch instance loads without radio_button", ok4b, ok4b and "" or L4b)
env4b.opts.click = "( ) Playing"
pcall(env4b.callbacks.on_draw_ui)
env4b.opts.click = nil
eq("the switch works without imgui.radio_button", L4b.cfg.finding, false)
env4b.restore()

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

-- Clicking a candidate must select it outright, since the names are unusable
-- ids and typing them by hand is what made the tool unusable in the first
-- place. Flash and Hide are one gesture each.
env5.opts.click = "Flash##row_GUI020210"
local clicked, cerr = pcall(env5.callbacks.on_draw_ui)
check("panel renders with a click", clicked, cerr)
eq("Flash selects the element", L5.flashing(), "GUI020210")

-- Pressing Flash on what is already flashing stops it. This is the escape
-- hatch that does not depend on finding a second control: the button that
-- started the blinking is on the row the player is already looking at.
env5.opts.click = "Flash##row_GUI020210"
pcall(env5.callbacks.on_draw_ui)
eq("Flash again on the same element stops it", L5.flashing(), "")
env5.opts.click = nil

-- And the banner's own button, which is the one that was unreachable in game:
-- it sat after the message on the same line, and at 24 pixels per character
-- that put it past the right edge of the window.
env5.opts.click = "Flash##row_GUI020210"
pcall(env5.callbacks.on_draw_ui)
env5.opts.click = "Stop flashing"
pcall(env5.callbacks.on_draw_ui)
eq("Stop flashing clears the flash", L5.flashing(), "")
env5.opts.click = nil

-- With nothing flashing the button is not rendered at all, so a stray click
-- cannot reach it.
env5.opts.click = "Stop flashing"
pcall(env5.callbacks.on_draw_ui)
eq("Stop flashing is absent while nothing is flashing", L5.flashing(), "")
env5.opts.click = nil

-- Flashing is not a setting. Saving it meant that quitting mid-flash brought
-- the blinking back on the next launch with nothing on screen to explain it.
env5.opts.click = "Flash##row_GUI020210"
pcall(env5.callbacks.on_draw_ui)
env5.opts.click = nil
for _, d in ipairs(env5.dumps) do
    if d.name == "hide_reengine_hud_elements.json" then
        eq("flashing is never written to the config", d.data.flashing, nil)
    end
end

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
eq("the flash target changed", L5.flashing(), "GUI020102")
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
group("the feed")
-- ---------------------------------------------------------------------------
-- An empty feed draws nothing at all -- no window, no backing rectangle, no
-- text. That is what makes it something a player never notices rather than a
-- block in the corner they come to the panel wanting rid of.
local envF, okF, LF = load_logger({ config = { feed_style = "imgui" },
                                    no_windows = true })
check("feed instance loads", okF, okF and "" or LF)
local quiet, qerr = pcall(envF.callbacks.on_frame)
check("a silent feed does not touch the renderer at all", quiet, qerr)
eq("and so does not trip the fallback", LF.cfg.feed_style, "imgui")
envF.restore()

-- The imgui renderer is unproven on this build. If it throws it must fall back
-- and persist the fallback, so a setting that does not work here cannot come
-- back on the next launch and cost another session.
local env6, ok6, L6 = load_logger({ config = { feed_style = "imgui" } })
check("sixth instance loads", ok6, ok6 and "" or L6)
eq("imgui feed style read from config", L6.cfg.feed_style, "imgui")
-- A new element is an announcement, which is the only thing the feed draws.
env6.callbacks.on_pre_gui_draw_element(
    stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" }))
env6.callbacks.on_frame()
eq("a working imgui feed is kept", L6.cfg.feed_style, "imgui")
env6.restore()

local env7, ok7, L7 = load_logger({ config = { feed_style = "imgui" },
                                    no_windows = true })
check("seventh instance loads", ok7, ok7 and "" or L7)
env7.callbacks.on_pre_gui_draw_element(
    stub.element(0x1, "GUI020102", "via.gui.GUI", { "GUI020102" }))
local ferr
ok7, ferr = pcall(env7.callbacks.on_frame)
check("a failing imgui feed does not propagate", ok7, ferr)
eq("failure reverts to the draw renderer", L7.cfg.feed_style, "draw")
local saved
for _, d in ipairs(env7.dumps) do
    if d.name == "hide_reengine_hud_elements.json" then saved = d.data end
end
check("the revert is saved to config", saved ~= nil and saved.feed_style == "draw",
    saved and saved.feed_style)
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
eq("Flash works on an element already hidden", L8.flashing(), "GUI020102")

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
    -- Another mod's settings. reframework/data/ is shared, so this is the
    -- normal case, and offering it as a loadable list would only confuse.
    ["instant_boot.json"] = { enabled = true, hide_boot_gui = true },
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

env9.opts.click = "Load##file_instant_boot.json"
pcall(env9.callbacks.on_draw_ui)
eq("another mod's config is never offered as a list", #L9.list, 2)
env9.opts.click = nil
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

env9.opts.click = "Del##list_GUI020102"
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
group("the hide list is always visible")
-- ---------------------------------------------------------------------------
-- The list is what the tool produces. Showing it only through a view of the
-- element browser meant a player could not see their own list unless its
-- entries happened to be drawing at that moment -- which, for a prompt that
-- appears occasionally, is almost never.
local envL, okL, LL = load_logger({ hide_list = {
    { name = "NOT_DRAWING", label = "an occasional prompt", on = true },
} })
check("list instance loads", okL, okL and "" or LL)
eq("the browser is on the on-screen view", LL.cfg.view, "on screen")
eq("and nothing is drawing", #LL.rows_for("on screen", ""), 0)

-- The entry's own controls must still have been rendered, which a click proves.
envL.opts.click = "Del##list_NOT_DRAWING"
pcall(envL.callbacks.on_draw_ui)
envL.opts.click = nil
eq("the entry was on screen to be deleted", #LL.list, 0)

-- And the same for an entry that is drawing, so the list does not depend on
-- liveness in either direction.
local envM, okM, LM = load_logger({ hide_list = {
    { name = "DRAWING", label = "always up", on = true },
} })
check("second list instance loads", okM, okM and "" or LM)
local hotM = envM.callbacks.on_pre_gui_draw_element
hotM(stub.element(0x1, "DRAWING", "via.gui.GUI", { "DRAWING" }))
envM.opts.click = "Del##list_DRAWING"
pcall(envM.callbacks.on_draw_ui)
envM.opts.click = nil
eq("a drawing entry is deletable too", #LM.list, 0)
envL.restore()
envM.restore()

-- ---------------------------------------------------------------------------
group("widget return shapes")
-- ---------------------------------------------------------------------------
-- The return shape of input_text and checkbox is undocumented and differs
-- between REFramework builds. Assuming one shape silently breaks the other:
-- the change is never detected, the value is never written back, and the
-- control behaves exactly like a dead field that will not accept typing.
for _, shape in ipairs({ "changed_and_value", "value" }) do
    local envT, okT, LT = load_logger({ input_shape = shape, typed = "GUI0201" })
    check("loads with input shape " .. shape, okT, okT and "" or LT)
    if okT then
        pcall(envT.callbacks.on_draw_ui)
        eq("typing reaches the search box with shape " .. shape,
            LT.cfg.search, "GUI0201")
        envT.restore()
    end
end

-- Untouched fields must not report a change, or every frame would look like an
-- edit and the config would be rewritten sixty times a second.
for _, shape in ipairs({ "changed_and_value", "value" }) do
    local envU, okU, LU = load_logger({ input_shape = shape })
    check("loads with untouched input, shape " .. shape, okU, okU and "" or LU)
    if okU then
        -- Counted from after load: a first run with no settings file writes
        -- the defaults once, which is not a panel save.
        local function writes()
            local n = 0
            for _, d in ipairs(envU.dumps) do
                if d.name == "hide_reengine_hud_elements.json" then n = n + 1 end
            end
            return n
        end
        local before = writes()
        pcall(envU.callbacks.on_draw_ui)
        eq("an untouched panel saves nothing, shape " .. shape, writes() - before, 0)
        envU.restore()
    end
end

-- Same for the tickbox that switches an entry on and off.
for _, shape in ipairs({ "changed_and_value", "value" }) do
    local envV, okV, LV = load_logger({
        checkbox_shape = shape, ticked = false,
        hide_list = { { name = "TICKED", label = "on", on = true } },
    })
    check("loads with checkbox shape " .. shape, okV, okV and "" or LV)
    if okV then
        local hotV = envV.callbacks.on_pre_gui_draw_element
        hotV(stub.element(0x1, "TICKED", "via.gui.GUI", { "TICKED" }))
        pcall(envV.callbacks.on_draw_ui)
        eq("unticking reaches the entry with shape " .. shape, LV.list[1].on, false)
        eq("and it draws again with shape " .. shape,
            hotV(stub.element(0x1, "TICKED", "via.gui.GUI", { "TICKED" })), true)
        envV.restore()
    end
end

-- A tickbox reporting a change to the value it already had must not count as a
-- change: it would rewrite the list every frame and make a real toggle
-- impossible to tell from a misread return value.
local envN, okN, LN = load_logger({
    ticked = true,   -- the stub reports "changed to true" every frame
    hide_list = { { name = "ALREADY_ON", label = "on", on = true } },
})
check("tickbox instance loads", okN, okN and "" or LN)
local function list_writes()
    local n = 0
    for _, d in ipairs(envN.dumps) do
        if d.name == "hide_reengine_hud_elements_list.json" then n = n + 1 end
    end
    return n
end
local before_writes = list_writes()
pcall(envN.callbacks.on_draw_ui)
pcall(envN.callbacks.on_draw_ui)
eq("a tickbox reporting its existing value writes nothing",
    list_writes() - before_writes, 0)
eq("and the entry is untouched", LN.list[1].on, true)
envN.restore()

-- ---------------------------------------------------------------------------
group("panel layout")
-- ---------------------------------------------------------------------------
-- A text field takes the full window width and puts its caption on the right,
-- so anything placed after one with same_line is pushed past the edge of the
-- window where it cannot be read or clicked. This is a source-shape rule
-- rather than a behaviour, but it regresses silently: nothing throws, the
-- control is simply gone.
do
    local src = assert(io.open("reframework/autorun/hide_reengine_hud_elements.lua"))
    local lines = {}
    for line in src:lines() do lines[#lines + 1] = line end
    src:close()

    local offenders = {}
    for i, line in ipairs(lines) do
        if line:find("ui.input(", 1, true) then
            -- Skip the assignment's own follow-up lines, then see what comes next.
            for j = i + 1, math.min(i + 3, #lines) do
                local nxt = lines[j]
                if nxt:find("ui.same_line()", 1, true) then
                    offenders[#offenders + 1] = j
                    break
                end
                local trimmed = nxt:match("^%s*(.-)%s*$")
                if trimmed ~= "" and not trimmed:find("^if %w+changed")
                    and not trimmed:find("^%-%-") then
                    break
                end
            end
        end
    end
    eq("no control is placed after a text field on the same line", #offenders, 0)
    if #offenders > 0 then
        io.write("    offending lines: " .. table.concat(offenders, ", ") .. "\n")
    end

    -- The same rule, generalised, and the one that would have caught the Stop
    -- button. Text is the only thing whose width is unbounded: a name, a label
    -- and a sentence of help all end up on the line, and at 24 pixels per
    -- character on a 4K display "FLASHING GUI020102  (not hidden -- press Hide
    -- for that)" is 1320 pixels wide before the button is placed. The button
    -- was laid out past the right edge of the window, where a player can see
    -- neither it nor any reason it is missing.
    --
    -- So text goes last on its line, always. A control after text on the same
    -- line is the bug, whatever the text happens to say today.
    local KINDS = {
        { "ui.input(", "control" }, { "ui.button(", "control" },
        { "ui.checkbox(", "control" }, { "ui.radio(", "control" },
        { "tc(", "text" }, { "ui.text(", "text" }, { "ui.colored(", "text" },
    }
    local function kind_of(line)
        for _, k in ipairs(KINDS) do
            if line:find(k[1], 1, true) then return k[2] end
        end
        return nil
    end

    local pushed_off = {}
    for i, line in ipairs(lines) do
        if line:find("ui.same_line()", 1, true) then
            local before
            for j = i - 1, math.max(i - 4, 1), -1 do
                before = kind_of(lines[j])
                if before ~= nil then break end
            end
            local after
            for j = i + 1, math.min(i + 4, #lines) do
                after = kind_of(lines[j])
                if after ~= nil then break end
            end
            if before == "text" and after == "control" then
                pushed_off[#pushed_off + 1] = i
            end
        end
    end
    eq("no control is placed after text on the same line", #pushed_off, 0)
    if #pushed_off > 0 then
        io.write("    same_line at: " .. table.concat(pushed_off, ", ") .. "\n")
        for _, n in ipairs(pushed_off) do
            io.write("      " .. n .. ": " .. (lines[n - 1] or "") .. "\n")
        end
    end
end

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
-- The hide list is always rendered, so an entry that has never drawn here is
-- visible without switching views at all. The browser's "everything" still
-- includes it, so it can also be found by search.
eq("the entry is on the list", L12.list[1].name, "NEVER_SEEN_HERE")
eq("everything includes an entry never seen", #L12.rows_for("everything", ""), 1)
eq("and names it", L12.rows_for("everything", "")[1].name, "NEVER_SEEN_HERE")
eq("it is absent from on screen", #L12.rows_for("on screen", ""), 0)

-- A listed element that has also been seen must appear once, not twice.
local hot12 = env12.callbacks.on_pre_gui_draw_element
hot12(stub.element(0x1, "NEVER_SEEN_HERE", "via.gui.GUI", { "NEVER_SEEN_HERE" }))
eq("a seen listed element is not duplicated", #L12.rows_for("everything", ""), 1)
env12.restore()

-- ---------------------------------------------------------------------------
io.write(string.format("\n%d checks, %d failed\n", checks, failures))
os.exit(failures == 0 and 0 or 1)
