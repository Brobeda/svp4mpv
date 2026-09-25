local H = require('helpers')
local Menu = require('third_party.menu')
local utils = require('mp.utils')

local first_start = true
local first_start_timer = nil
local timer = nil
local stopped = true
local menu = nil
local original_hr_seek = mp.get_property("hr-seek-framedrop", "yes")

local menu_json = (os.getenv("TMPDIR") or "/tmp") .. "/svp_menu.json"
local config_json = (os.getenv("TMPDIR") or "/tmp") .. "/svp_config.json"
if H:on_windows() then
    menu_json = os.getenv("LOCALAPPDATA") .. "\\Temp\\svp_menu.json"
    config_json = os.getenv("LOCALAPPDATA") .. "\\Temp\\svp_config.json"
end

local config = {
    multiplicand = "Video FPS",
    multiplier = "Auto (respect vsync)",
    frame_interpolation_mode = "Adaptive",
    adaptive_pattern = "Uniform - 1m - 1.5m",
    svp_shader = "13. Standard",
    artifacts_masking = "Average",
    motion_vectors_precision = "Half pixel",
    motion_vectors_grid = "12 px. Average 2",
    decrease_grid_step = "Disabled",
    search_radius = "Average",
    wide_search = "Average",
    width_of_top_coarse_level = "Large",
    use_nvidia_optical_flow = "Don't use",
    fill_with_light = "Enabled",
    lights_count = "16",
    flare_length = "100",
    flare_width = "1.0",
    border = "12",
    processing_of_scene_changes = "Repeat frame",
    duplicate_frames_removal = "Do not remove",
    gpu_acceleration = "Disable",
    gpu_id = "Default (use first available)",
    native_10bit_decoding = "Never allow",
    processing_threads = "Do not change",
    json_super = "",
    json_analyse = "",
    json_smoothfps = "",
}
local defaults = H:shallow_copy(config)
require "mp.options".read_options(config, "svp")

local function remove_filter()
    if string.find(mp.get_property("vf"), "@svp") then
        mp.commandv("vf", "remove", "@svp")
    end
end

local ffi = require("ffi")

-- Declare Windows API functions needed for DLL loading
ffi.cdef[[
    int SetDllDirectoryW(const wchar_t* lpPathName);
    int SetEnvironmentVariableW(const wchar_t* lpName, const wchar_t* lpValue);
]]

-- Helper function to convert Lua UTF-8 strings to UTF-16 wide strings for Win32 API
local function to_wchar(str)
    local utf8 = require("ffi")
    local len = #str + 1
    local buf = ffi.new("wchar_t[?]", len)
    for i = 1, #str do
        buf[i - 1] = str:byte(i)
    end
    buf[#str] = 0
    return buf
end

-- ====================================================
-- Portable VapourSynth Path Resolution
-- ====================================================
local function get_vapoursynth_options()
    if not H:on_windows() then return "" end

    local script_dir = mp.get_script_directory()
    local mpv_home = mp.command_native({"expand-path", "~~/"})

    local candidates = {
        utils.join_path(script_dir, "vapoursynth"),
        utils.join_path(script_dir, "vapoursynth-portable"),
        utils.join_path(mpv_home, "vapoursynth"),
        mpv_home
    }

    for _, dir in ipairs(candidates) do
        local dll_path = utils.join_path(dir, "vsscript.dll")
        if H:path_exists(dll_path) then
            local clean_dir = dir:gsub("/", "\\")
            
            -- 1. Register DLL directory directly with Windows OS loader
            pcall(function()
                ffi.C.SetDllDirectoryW(to_wchar(clean_dir))
            end)

            -- 2. Update process PATH variable via Windows API
            local current_path = os.getenv("PATH") or ""
            local new_path = clean_dir .. ";" .. current_path
            pcall(function()
                ffi.C.SetEnvironmentVariableW(to_wchar("PATH"), to_wchar(new_path))
            end)

            mp.msg.info("[svp4mpv] Successfully registered DLL directory with Windows API: " .. clean_dir)
            break
        end
    end

    return ""
end

local function update()
    if stopped then return end

    get_vapoursynth_options() -- Resolves DLL path internally if present

    local filter =
        '@svp:vapoursynth="' .. mp.get_script_directory() .. '/svp.py"' ..
        ':buffered-frames=4:concurrent-frames=23'

    remove_filter()
    mp.set_property("hr-seek-framedrop", "no")
    mp.commandv("vf", "add", filter)
    stopped = false
end

local function schedule_update()
    if timer then timer:stop() end
    timer = mp.add_timeout(0.25, update)
end

local function new_file_print_state()
    if stopped then return end
    mp.osd_message("SVP On")
end

local function stop(silent)
    stopped = true
    remove_filter()
    if not silent then mp.osd_message("SVP Off") end

    if original_hr_seek then
        mp.set_property("hr-seek-framedrop", original_hr_seek)
    end
end

local function start(silent)
    stopped = false
    update()
    if not silent then mp.osd_message("SVP On") end
end

local function toggle()
    if stopped then start() else stop() end
    if menu then
        menu:close()
        menu.stopped = stopped
        menu:open()
    end
end

local function apply()
    if stopped then
        start()
    else
        update()
        mp.osd_message("Applied")
    end
end

local function save()
    local data = ""
    for key, value in pairs(config) do
        data = data .. key .. "=" .. value .. "\n"
    end
    local path = H:exp("~~home/script-opts/svp.conf")
    local f = H:write_file(path, data)
    mp.osd_message("Saved options to " .. path)
end

local function show_menu()
    if menu == nil then
        menu = Menu:new({
            stopped = stopped,
            choices = H:read_json(menu_json),
            config = config,
            defaults = defaults,
            keybindings = {
                {
                    keys = {"ENTER", "KP_ENTER"},
                    fn = function(self) toggle() end
                },
                {
                    keys = {"a"},
                    fn = function(self) apply() end
                },
                {
                    keys = {"s", "ctrl+s"},
                    fn = function(self) save() end
                },
            }
        })
        menu.on_config_changed = function()
            H:write_json(config_json, config)
        end
    end
    menu.stopped = stopped
    menu:open()
end

H:write_json(config_json, config)
mp.add_hook('on_preloaded', 50, schedule_update)
mp.add_hook('on_preloaded', 49, new_file_print_state)
mp.observe_property("vo-configured", "native", schedule_update)
mp.observe_property("display-fps", "native", schedule_update)
mp.observe_property("osd-width", "native", schedule_update)
mp.observe_property("osd-height", "native", schedule_update)

mp.add_key_binding("Alt+S", "svp-menu", function()
    if first_start then
        os.remove(menu_json)  -- remove any menu from old script version
        start(true)  -- svp.py will run the logic to prepare the menu only
        first_start_timer = mp.add_periodic_timer(0.02, function()
            if not H:path_exists(menu_json) then return end
            first_start_timer:stop()
            stop(true)
            first_start = false
            show_menu()
        end)
    else
        show_menu()
    end
end)
