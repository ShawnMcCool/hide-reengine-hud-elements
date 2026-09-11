-- Hide RE Engine HUD Elements -- pure logic
--
-- Nothing in this file touches a REFramework global, so tests/test_pure.lua
-- drives it directly on the desktop with no stubs at all. Key building, hide
-- list handling and the sharing merge all live here for that reason.

local pure = {}


-- An element key is a GameObject name plus a via.gui type. Kept as two fields
-- rather than a joined string: the hot path must not build strings per element.
function pure.key_of(name, type_name)
    return name .. "\0" .. tostring(type_name)
end

function pure.name_of_key(key)
    return key:match("^(.-)\0") or key
end

-- names[name] is the list of types seen under that name. Returns true when the
-- type was not already present, i.e. when this call created or grew a list.
function pure.note_type(names, name, type_name)
    local list = names[name]
    if list == nil then
        names[name] = { type_name }
        return true
    end
    for i = 1, #list do
        if list[i] == type_name then return false end
    end
    list[#list + 1] = type_name
    table.sort(list)
    return true
end

-- A collision is one name carrying more than one type. Question 4 asks whether
-- any exist; this is the answer, sorted so the dump is stable across sessions.
function pure.collisions(names)
    local out = {}
    for name, list in pairs(names) do
        if #list > 1 then out[#out + 1] = { name = name, types = list } end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

-- Segments arrive leaf first from the parent walk; the readable path is root
-- first. Returns nil for an empty walk so a failed walk is distinguishable
-- from a root-level object.
function pure.join_path(segments)
    local n = #segments
    if n == 0 then return nil end
    local ordered = {}
    for i = n, 1, -1 do ordered[#ordered + 1] = segments[i] end
    return table.concat(ordered, "/")
end

-- A hide-list entry. The label is the point: names in this game are opaque ids
-- like GUI020102, so a list of bare names is unusable by anyone who did not
-- identify them personally. The label is what makes a list worth sharing, and
-- `from` records which imported list an entry arrived in.
function pure.new_entry(name, label, on, from)
    return { name = name, label = label or "", on = on ~= false, from = from }
end

function pure.entry_index(entries, name)
    for i = 1, #entries do
        if entries[i].name == name then return i end
    end
    return nil
end

function pure.entry_add(entries, entry)
    if entry == nil or type(entry.name) ~= "string" or entry.name == "" then
        return false
    end
    if pure.entry_index(entries, entry.name) ~= nil then return false end
    entries[#entries + 1] = entry
    return true
end

function pure.entry_remove(entries, name)
    local at = pure.entry_index(entries, name)
    if at == nil then return false end
    table.remove(entries, at)
    return true
end

-- Only entries that are switched on hide anything, so an imported list can sit
-- in the interface without changing what is on screen until it is asked to.
function pure.active_set(entries)
    local set, n = {}, 0
    for i = 1, #entries do
        local e = entries[i]
        if e.on and type(e.name) == "string" and e.name ~= "" and set[e.name] == nil then
            set[e.name] = true
            n = n + 1
        end
    end
    return set, n
end

function pure.count_active(entries)
    local _, n = pure.active_set(entries)
    return n
end

-- The file format is an array of entries. A bare string is accepted as
-- shorthand for an entry with no label, so the list stays comfortable to edit
-- by hand. Anything unusable is dropped rather than failing the whole list: one
-- bad line must not switch a player's HUD back on.
function pure.clean_entries(value)
    local out = {}
    if type(value) ~= "table" then return out end
    for i = 1, #value do
        local raw = value[i]
        if type(raw) == "string" then
            pure.entry_add(out, pure.new_entry(raw))
        elseif type(raw) == "table" and type(raw.name) == "string" then
            pure.entry_add(out, pure.new_entry(
                raw.name,
                type(raw.label) == "string" and raw.label or "",
                raw.on ~= false,
                type(raw.from) == "string" and raw.from or nil))
        end
    end
    return out
end

-- Merging someone else's list. A new entry arrives switched off, because an
-- import must never silently change what a player sees. An entry already held
-- keeps its own on/off state and only gains a label if it had none.
function pure.merge_entries(into, incoming, source)
    local added, labelled = 0, 0
    for i = 1, #incoming do
        local e = incoming[i]
        local at = pure.entry_index(into, e.name)
        if at == nil then
            pure.entry_add(into, pure.new_entry(e.name, e.label, false, source))
            added = added + 1
        elseif into[at].label == "" and e.label ~= "" then
            into[at].label = e.label
            into[at].from = into[at].from or source
            labelled = labelled + 1
        end
    end
    return added, labelled
end

-- Fixed-size ring, so the mean is over recent frames rather than the whole
-- session. A session mean would be dominated by the menus it started in.
function pure.new_window(size)
    return { size = size, buf = {}, at = 0, count = 0, sum = 0 }
end

function pure.window_push(w, value)
    w.at = (w.at % w.size) + 1
    local old = w.buf[w.at]
    if old ~= nil then
        w.sum = w.sum - old
    else
        w.count = w.count + 1
    end
    w.buf[w.at] = value
    w.sum = w.sum + value
end

function pure.window_mean(w)
    if w.count == 0 then return 0 end
    return w.sum / w.count
end

function pure.new_stats(window_size)
    return {
        frames = 0,
        last = 0, min = nil, max = 0,
        window = pure.new_window(window_size),
        cache_hits = 0, cache_misses = 0,
    }
end

function pure.record_frame(stats, elements)
    stats.frames = stats.frames + 1
    stats.last = elements
    if stats.min == nil or elements < stats.min then stats.min = elements end
    if elements > stats.max then stats.max = elements end
    pure.window_push(stats.window, elements)
end

-- Hit rate is the evidence for or against the campaign's decision cache: a high
-- rate means caching by address is worth its invalidation complexity.
function pure.cache_hit_rate(stats)
    local total = stats.cache_hits + stats.cache_misses
    if total == 0 then return 0 end
    return stats.cache_hits / total
end

function pure.percent(fraction)
    return string.format("%d%%", math.floor(fraction * 100 + 0.5))
end

-- A probe answers one open question and is independent of every other probe.
-- It stops for one of two reasons and both retire it permanently: the log is
-- overwritten each launch, and a probe reporting once per poll would bury the
-- findings under a repeated line.
--
-- The second reason is the portable one. A probe that never answers is as
-- useless as one that throws, and on another RE Engine title that is the
-- expected case rather than a fault: app.GameFlowManager is this game's own
-- type and will not exist there. A missing singleton does not raise, it
-- returns nil forever, so retiring on failure alone would never retire it.
--
-- Note what this rule does not catch, because session 4 found it: a probe that
-- answers every time with a value that never changes. via.SceneManager does
-- exactly that here. It is inert rather than barren, and telling those apart
-- needs a human looking at the dump, not a rule -- an unchanging answer is
-- also what a correct probe returns when nothing has happened yet.
pure.BARREN_POLLS = 40

function pure.new_probe(name)
    return { name = name, disabled = false, reason = nil, ran = 0, answered = false }
end

function pure.probe_stopped(probe, reason)
    probe.disabled = true
    probe.reason = reason
    return probe
end

function pure.probe_failed(probe, err)
    return pure.probe_stopped(probe, tostring(err))
end

-- Records what a poll returned, and retires the probe once it is clear that no
-- poll ever will return anything. Passes the value back so a caller can hand a
-- result straight through.
function pure.probe_result(probe, value)
    if value ~= nil then
        probe.answered = true
    elseif not probe.answered and probe.ran >= pure.BARREN_POLLS then
        pure.probe_stopped(probe, "no value in " .. probe.ran .. " polls")
    end
    return value
end

function pure.probe_summary(probes)
    local disabled = {}
    for _, p in pairs(probes) do
        if p.disabled then disabled[#disabled + 1] = p.name end
    end
    table.sort(disabled)
    return disabled
end

-- Traces are capped because a long session must not grow without bound, and
-- the early transitions are the informative ones -- they bracket the loads.
function pure.push_trace(trace, entry, cap)
    if #trace >= cap then return false end
    trace[#trace + 1] = entry
    return true
end

return pure
