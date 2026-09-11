-- REFramework stubs for desktop testing.
--
-- Provides the globals hide_reengine_hud_elements.lua expects, captures the callbacks
-- it registers, and records what it logged and dumped. Loading the real file
-- against these is itself the most valuable test: a logger that throws on load
-- wastes an entire play session, and play sessions are the scarce resource.

local M = {}

function M.install(opts)
    opts = opts or {}
    local env = {
        callbacks = {},
        logged = {},
        tree_labels = {},
        tree_pops = 0,
        dumps = {},
        config_file = opts.config,
    }

    _G.re = {}
    local function capture(name)
        return function(fn) env.callbacks[name] = fn end
    end
    for _, name in ipairs({
        "on_pre_gui_draw_element", "on_gui_draw_element", "on_frame",
        "on_draw_ui", "on_script_reset", "on_application_entry",
        "on_pre_application_entry",
    }) do
        _G.re[name] = capture(name)
    end

    _G.log = { info = function(m) env.logged[#env.logged + 1] = m end }

    _G.json = {
        load_file = function(name)
            if name == "hide_reengine_hud_elements.json" then return env.config_file end
            if name == "hide_reengine_hud_elements_list.json" then return opts.hide_list end
            return opts.files and opts.files[name] or nil
        end,
        dump_file = function(name, tbl)
            env.dumps[#env.dumps + 1] = { name = name, data = tbl }
            return true
        end,
    }

    local function noop() end
    _G.draw = {
        text = noop, world_text = noop, filled_rect = noop, outline_rect = noop,
        line = noop, world_to_screen = function() return nil end,
    }

    -- tree_node returns true so the panel body actually executes under test.
    -- With it returning false the panel is never entered, and a nil function
    -- inside it would go unnoticed until a play session.
    _G.imgui = {
        tree_node = function(label)
            env.tree_labels[#env.tree_labels + 1] = label
            return opts.tree_open ~= false
        end,
        tree_pop = function() env.tree_pops = env.tree_pops + 1 end,
        text = noop,
        text_colored = function(...)
            if opts.no_text_colored then error("text_colored unsupported") end
        end,
        checkbox = function(_, v)
            local ticked = opts.ticked
            if opts.checkbox_shape == "value" then
                if ticked ~= nil then return ticked end
                return v
            end
            if ticked ~= nil then return true, ticked end
            return false, v
        end,
        radio_button = function(label)
            return opts.click ~= nil and label == opts.click
        end,
        -- REFramework builds differ here and the shape is undocumented:
        -- opts.input_shape picks which one this stub imitates.
        input_text = function(_, v)
            local typed = opts.typed
            if opts.input_shape == "value" then return typed or v end
            if typed ~= nil then return true, typed end
            return false, v
        end,
        -- opts.click names a button label to report as clicked this frame.
        button = function(label) return opts.click ~= nil and label == opts.click end,
        -- Deliberately no new_line: this build of REFramework does not bind
        -- it, and a stub that is kinder than the engine hides real bugs.
        same_line = noop, separator = noop,
        get_display_size = function() return opts.display or { x = 1920, y = 1080 } end,
        calc_text_size = function(s) return { x = #s * 7, y = 14 } end,
        set_next_window_pos = noop, set_next_window_size = noop,
        begin_window = function()
            if opts.no_windows then error("begin_window unsupported") end
            return true
        end,
        end_window = noop,
    }

    -- opts.remove models this build's reality: bindings that are simply not
    -- there. radio_button and new_line are both absent in REFramework 01417.
    for _, name in ipairs(opts.remove or {}) do
        _G.imgui[name] = nil
    end

    _G.Vector2f = { new = function(x, y) return { x = x, y = y } end }

    -- fs.glob is present in the real build but its filter syntax is unverified,
    -- so the tool must work without it. opts.no_fs models that.
    if opts.no_fs then
        _G.fs = nil
    else
        _G.fs = { glob = function()
            local out = {}
            for name in pairs(opts.files or {}) do out[#out + 1] = name end
            table.sort(out)
            return out
        end }
    end

    _G.sdk = {
        find_type_definition = function(name)
            if name == "via.Application" and opts.app_methods then
                local methods = {}
                for _, n in ipairs(opts.app_methods) do
                    methods[#methods + 1] = { get_name = function() return n end }
                end
                return { get_methods = function() return methods end }
            end
            if name == "via.SceneManager" then return { name = name } end
            return nil
        end,
        get_native_singleton = function() return opts.scene_singleton end,
        get_managed_singleton = function() return opts.flow_singleton end,
        -- opts is captured by reference, so a test mutates opts.scene to
        -- simulate the scene changing under the poll.
        call_native_func = function() return opts.scene end,
    }

    env.restore = function()
        _G.re, _G.log, _G.json, _G.draw, _G.imgui, _G.sdk = nil, nil, nil, nil, nil, nil
        _G.Vector2f, _G.fs = nil, nil
    end
    env.opts = opts
    return env
end

-- A managed singleton whose flag methods return whatever the table says.
function M.flow(flags)
    return { call = function(_, method) return flags[method] == true end }
end

-- A fake GUI element. `fails` makes identification throw, which must still be
-- counted and must still draw.
function M.element(addr, name, type_name, path, fails)
    local go
    local function transform(depth)
        local segment = path and path[depth]
        if segment == nil then return nil end
        return {
            call = function(_, method)
                if method == "get_GameObject" then
                    return { call = function(_, m)
                        if m == "get_Name" then return segment end
                    end }
                elseif method == "get_Parent" then
                    return transform(depth + 1)
                elseif method == "get_Position" then
                    return { x = 0, y = 0, z = 0 }
                end
            end,
        }
    end

    go = {
        call = function(_, method)
            if method == "get_Name" then return name end
            if method == "get_Transform" then return transform(1) end
        end,
    }

    return {
        get_address = function() return addr end,
        get_type_definition = function()
            return {
                get_full_name = function() return type_name end,
                get_methods = function() return {} end,
                get_parent_type = function() return nil end,
            }
        end,
        call = function(_, method)
            if method == "get_GameObject" then
                if fails then error("identification failed") end
                return go
            end
        end,
    }
end

return M
