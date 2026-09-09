-- HUD Element Hider -- diagnostics
--
-- Everything the mod learns about the game it is running in, and nothing the
-- product needs to work: the probes, their traces, and the dump.
--
-- Each probe answers one question and is independent of every other. On its
-- first failure a probe records the reason and never runs again -- the
-- REFramework log is overwritten every launch, and a probe failing once per
-- frame would bury the findings under a repeated line.
--
-- The scene probes exist because the decision cache is keyed on element
-- address, and addresses are recycled: something has to say when a load
-- happened. app.GameFlowManager answers; via.SceneManager was polled 13,800
-- times across a session and never produced a value.

local M = {}

-- deps: pure, info, on_transition(why) -- called when a load is detected, so
-- the caller can invalidate whatever it keyed on element addresses.
function M.new(deps)
    local pure, info = deps.pure, deps.info
    local on_transition = deps.on_transition or function() end

    local TRACE_CAP = 200

    local self = {
        findings = {},
        scene_trace = {},
        flow_trace = {},
        probes = {
            app_methods = pure.new_probe("app_methods"),
            scene = pure.new_probe("scene"),
            flow = pure.new_probe("flow"),
            display = pure.new_probe("display"),
            metrics = pure.new_probe("metrics"),
        },
    }
    local probes = self.probes

    local function run_probe(probe, fn, arg)
        if probe.disabled then return nil end
        probe.ran = probe.ran + 1
        local ok, result = pcall(fn, arg)
        if not ok then
            pure.probe_failed(probe, result)
            info("probe disabled: " .. probe.name .. ": " .. probe.reason)
            return nil
        end
        return result
    end
    self.run_probe = run_probe

    -- The module search path, recorded because the mod's own require of
    -- hud_element_hider.pure depends on it. There is no probe testing whether
    -- require works: this file is itself required at load, so if that were
    -- broken nothing here would be running.
    local function probe_modules()
        local f = self.findings
        f.package_path = tostring(package and package.path or "<no package table>")
        f.package_cpath = tostring(package and package.cpath or "")
        info("package.path = " .. f.package_path)
    end

    -- Application entry names live in the game's reflection data, not in
    -- dinput8.dll, so they cannot be grepped. Note that get_methods returns
    -- via.Application's reflection methods, which turned out NOT to be the
    -- function list on_application_entry hooks -- this records what is there,
    -- it does not answer that question.
    local function probe_app_methods()
        local names = run_probe(probes.app_methods, function()
            local td = sdk.find_type_definition("via.Application")
            if td == nil then error("via.Application not found") end
            local out = {}
            for _, m in ipairs(td:get_methods() or {}) do
                local n = m:get_name()
                if n then out[#out + 1] = n end
            end
            table.sort(out)
            return out
        end)
        if names ~= nil then
            self.findings.application_methods = names
            info("via.Application: " .. #names .. " methods enumerated")
        end
    end

    -- A native call may hand back a managed object or a bare address.
    -- Accepting both keeps the probe alive either way.
    local function scene_identity(scene)
        if scene == nil then return nil end
        if type(scene) == "number" then return scene end
        return scene:get_address()
    end

    local last_scene = nil
    local function poll_scene(frame)
        local addr = run_probe(probes.scene, function()
            local mgr = sdk.get_native_singleton("via.SceneManager")
            if mgr == nil then return nil end
            local td = sdk.find_type_definition("via.SceneManager")
            if td == nil then return nil end
            return scene_identity(sdk.call_native_func(mgr, td, "get_CurrentScene"))
        end)
        if addr == nil then return false end

        -- last_scene is assigned on every path. Returning early without
        -- assigning would re-detect the same change on the next frame, and
        -- every frame after it.
        local changed = last_scene ~= nil and addr ~= last_scene
        if changed then
            pure.push_trace(self.scene_trace,
                { frame = frame, from = string.format("%x", last_scene),
                  to = string.format("%x", addr) }, TRACE_CAP)
            info("SCENE changed at frame " .. frame)
            on_transition("scene change")
        end
        last_scene = addr
        return changed
    end

    -- The game's own flow state. instant_boot.lua exercises these three
    -- methods successfully on this build, which is why they are candidates.
    local FLOW_FLAGS = { "get_IsTitleStable", "get_IsMainMenu", "get_IsIngame" }
    local last_flow = nil
    local function poll_flow(frame)
        local state = run_probe(probes.flow, function()
            local mgr = sdk.get_managed_singleton("app.GameFlowManager")
            if mgr == nil then return nil end
            local parts = {}
            for _, m in ipairs(FLOW_FLAGS) do
                local ok, v = pcall(mgr.call, mgr, m)
                parts[#parts + 1] = (ok and v == true) and "1" or "0"
            end
            return table.concat(parts)
        end)
        if state == nil then return false end
        local changed = last_flow ~= nil and state ~= last_flow
        if changed then
            pure.push_trace(self.flow_trace,
                { frame = frame, from = last_flow, to = state }, TRACE_CAP)
            info("FLOW " .. last_flow .. " -> " .. state .. " at frame " .. frame)
            on_transition("flow change")
        end
        last_flow = state
        return changed
    end

    function self.at_load()
        probe_modules()
        probe_app_methods()
    end

    -- Returns true when a load was detected, which is the caller's cue to
    -- invalidate and to write a dump while there is something to write.
    function self.poll(frame)
        local changed = poll_scene(frame)
        if poll_flow(frame) then changed = true end
        return changed
    end

    function self.disabled()
        return pure.probe_summary(probes)
    end

    function self.report()
        local state = {}
        for key, pr in pairs(probes) do
            state[key] = { disabled = pr.disabled, reason = pr.reason, ran = pr.ran }
        end
        return {
            state = state,
            findings = self.findings,
            scene_trace = self.scene_trace,
            flow_trace = self.flow_trace,
        }
    end

    return self
end

return M
