obs = obslua

local separator = package.config:sub(1, 1)
-- OBS supplies UTF-8 paths; Lua's CRT file functions use the Windows code page.
-- Use OBS file helpers and CreateProcessW so Chinese installation paths work.
local ffi, obs_native, kernel
if separator == "\\" then
    local ok, library = pcall(require, "ffi")
    if ok then
        ffi = library
        if not pcall(ffi.typeof, "AL_STARTUPINFOW") then
            ffi.cdef[[
                typedef struct {
                    unsigned long cb; unsigned short *reserved, *desktop, *title;
                    unsigned long x, y, xsize, ysize, xchars, ychars, fill, flags;
                    unsigned short show, reserved_size; unsigned char *reserved_data;
                    void *input, *output, *error;
                } AL_STARTUPINFOW;
                typedef struct { void *process, *thread; unsigned long pid, tid; } AL_PROCESS_INFORMATION;
                int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, unsigned short *, int);
                int __stdcall CreateProcessW(const unsigned short *, unsigned short *, void *, void *, int,
                    unsigned long, void *, const unsigned short *, AL_STARTUPINFOW *, AL_PROCESS_INFORMATION *);
                int __stdcall CloseHandle(void *);
                unsigned long __stdcall GetCurrentProcessId(void);
                char *os_quick_read_utf8_file(const char *);
                bool os_quick_write_utf8_file(const char *, const char *, size_t, bool);
                bool os_file_exists(const char *);
                int os_unlink(const char *);
                int os_rename(const char *, const char *);
                void bfree(void *);
            ]]
        end
        obs_native = ffi.load("obs")
        kernel = ffi.load("kernel32")
    end
end

local function execute_hidden(command)
    if not kernel then return os.execute(command) end
    local length = kernel.MultiByteToWideChar(65001, 0, command, #command, nil, 0)
    if length == 0 then return false end
    local wide = ffi.new("unsigned short[?]", length + 1)
    if kernel.MultiByteToWideChar(65001, 0, command, #command, wide, length) == 0 then return false end
    local startup, process = ffi.new("AL_STARTUPINFOW"), ffi.new("AL_PROCESS_INFORMATION")
    startup.cb = ffi.sizeof(startup)
    if kernel.CreateProcessW(nil, wide, nil, nil, 0, 0x08000000, nil, nil, startup, process) == 0 then return false end
    kernel.CloseHandle(process.thread)
    kernel.CloseHandle(process.process)
    return true
end

local function remove_file(path)
    if obs_native then return obs_native.os_unlink(path) == 0 end
    return os.remove(path)
end

local function rename_file(from, to)
    if obs_native then return obs_native.os_rename(from, to) == 0 end
    return os.rename(from, to)
end

local script_dir = script_path()
if script_dir:lower():match("%.lua$") then
    script_dir = script_dir:match("^(.*)[/\\]") or ""
end
if script_dir:sub(-1) ~= "\\" and script_dir:sub(-1) ~= "/" then
    script_dir = script_dir .. separator
end
local sender_path = script_dir .. "AppleLiveSender.exe"
local usb_script_path = script_dir .. "usb_forward.ps1"
local status_path = script_dir .. "applelive-status.json"
local stop_path = script_dir .. "applelive-stop.flag"
local log_path = script_dir .. "applelive-sender.log"
local dock_path = script_dir .. "AppleLiveDock.exe"
local bridge_path = script_dir .. "applelive-bridge.json"
local command_path = script_dir .. "applelive-command.json"
local settings_ref = nil
local last_command = ""
local command_error = ""

local port = 8765
local width = 720
local height = 1280
local fps = 30
local bitrate_kbps = 5000
local quality = "standard"
local connection_mode = "lan"
local computer_audio = false
local show_advanced = false
local encoder = "auto"
local encoder_preset = "veryfast"
local video_device = "HD Camera"
local ffmpeg_path = "ffmpeg"
local audio_device = "CABLE Output (VB-Audio Virtual Cable)"
local owns_virtual_camera = false
local pending_camera_start = nil
local sender_state = "stopped"
local launch_started_at = 0
local status_text = "未启动"
local last_logged_status = ""

local function log(level, message)
    obs.script_log(level, "[AppleLive] " .. message)
end

local function read_file(path)
    if obs_native then
        local buffer = obs_native.os_quick_read_utf8_file(path)
        if buffer == nil then return nil end
        local content = ffi.string(buffer)
        obs_native.bfree(buffer)
        return content
    end
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function file_exists(path)
    if obs_native then return obs_native.os_file_exists(path) end
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function write_file(path, content)
    if obs_native then
        if obs_native.os_quick_write_utf8_file(path, content, #content, false) then return true end
        log(obs.LOG_ERROR, "无法写入 " .. path)
        return false
    end
    local file, err = io.open(path, "wb")
    if not file then
        log(obs.LOG_ERROR, "无法写入 " .. path .. ": " .. tostring(err))
        return false
    end
    file:write(content)
    file:close()
    return true
end

local function safe_argument(value)
    if not value or value == "" then return true end
    for _, char in ipairs({ '"', '%', '!', '^', '&', '|', '<', '>', '\r', '\n' }) do
        if value:find(char, 1, true) then return false end
    end
    return true
end

local function quoted(value)
    return '"' .. value .. '"'
end

local function status_label(state, clients, usb_clients)
    if state == "running" then
        return "运行中 | 接收连接 " .. tostring(clients or 0) .. " | USB " .. tostring(usb_clients or 0)
    elseif state == "starting" then
        return "正在启动"
    elseif state == "stopping" then
        return "正在停止"
    elseif state == "error" then
        return "发送器错误，请查看日志"
    end
    return "未启动"
end

local function refresh_status()
    local content = read_file(status_path)
    if not content then
        if sender_state == "starting" and os.time() - launch_started_at > 10 then
            sender_state = "error"
            status_text = "发送器启动超时，请查看日志"
            if owns_virtual_camera then
                obs.obs_frontend_stop_virtualcam()
                owns_virtual_camera = false
            end
        end
        return
    end
    local data = obs.obs_data_create_from_json(content)
    if not data then return end
    local state = obs.obs_data_get_string(data, "state")
    local clients = obs.obs_data_get_int(data, "clients")
    local usb_clients = obs.obs_data_get_int(data, "usb_clients")
    local updated_at = obs.obs_data_get_int(data, "updated_at")
    obs.obs_data_release(data)
    if not state then return end
    if updated_at > 0 and os.time() - updated_at > 5 then
        state = "stopped"
        status_text = "未启动"
    else
        if state == "running" and file_exists(stop_path) then state = "stopping" end
        status_text = status_label(state, clients, usb_clients)
    end
    sender_state = state
    if (state == "error" or state == "stopped") and owns_virtual_camera then
        if obs.obs_frontend_virtualcam_active() then
            obs.obs_frontend_stop_virtualcam()
        end
        owns_virtual_camera = false
    end
    if status_text ~= last_logged_status then
        log(obs.LOG_INFO, status_text)
        last_logged_status = status_text
    end
end

local function request_stop()
    if pending_camera_start then
        obs.timer_remove(pending_camera_start)
        pending_camera_start = nil
    end
    if sender_state == "stopped" or sender_state == "error" then return true end
    if not write_file(stop_path, "stop\n") then return false end
    if owns_virtual_camera and obs.obs_frontend_virtualcam_active() then
        obs.obs_frontend_stop_virtualcam()
    end
    owns_virtual_camera = false
    sender_state = "stopping"
    status_text = "正在停止"
    return true
end

local function start_sender(props, property)
    if separator ~= "\\" then
        status_text = "仅支持 Windows"
        log(obs.LOG_ERROR, status_text)
        return true
    end
    if not file_exists(sender_path) then
        status_text = "找不到 AppleLiveSender.exe"
        log(obs.LOG_ERROR, status_text .. "，请将 exe 放在脚本同一目录")
        return true
    end
    if connection_mode == "usb" and not file_exists(usb_script_path) then
        status_text = "找不到 USB 连接脚本"
        log(obs.LOG_ERROR, status_text)
        return true
    end
    if video_device == "" then
        status_text = "请填写视频设备名"
        log(obs.LOG_ERROR, status_text)
        return true
    end
    for _, value in ipairs({ sender_path, usb_script_path, ffmpeg_path, video_device, audio_device, status_path, stop_path, log_path }) do
        if not safe_argument(value) then
            status_text = "路径或设备名含不支持的符号"
            log(obs.LOG_ERROR, status_text)
            return true
        end
    end

    refresh_status()
    if sender_state == "running" or sender_state == "starting" or sender_state == "stopping" then
        log(obs.LOG_WARNING, "发送器正在启动、运行或停止")
        return true
    end

    remove_file(stop_path)
    remove_file(status_path)
    if video_device == "OBS Virtual Camera" or video_device == "HD Camera" then
        if not obs.obs_frontend_virtualcam_active() then
            obs.obs_frontend_start_virtualcam()
            owns_virtual_camera = true
            -- OBS queues virtual camera startup on the UI thread. Wait without
            -- blocking that thread; an immediate active() check reports failure.
            sender_state = "starting"
            status_text = "正在启动 OBS 虚拟摄像头"
            launch_started_at = os.time()
            pending_camera_start = function()
                if obs.obs_frontend_virtualcam_active() then
                    obs.timer_remove(pending_camera_start)
                    pending_camera_start = nil
                    sender_state = "stopped"
                    start_sender(nil, nil)
                elseif os.time() - launch_started_at > 8 then
                    obs.timer_remove(pending_camera_start)
                    pending_camera_start = nil
                    sender_state = "error"
                    status_text = "OBS 虚拟摄像头启动超时"
                    log(obs.LOG_ERROR, status_text)
                    obs.obs_frontend_stop_virtualcam()
                    owns_virtual_camera = false
                end
            end
            obs.timer_add(pending_camera_start, 100)
            return true
        end
    end

    sender_state = "starting"
    launch_started_at = os.time()
    local command = quoted(sender_path) ..
        ' --host "0.0.0.0" --port ' .. port ..
        ' --connection-mode ' .. quoted(connection_mode) ..
        ' --video-device ' .. quoted(video_device) ..
        ' --width ' .. width .. ' --height ' .. height .. ' --fps ' .. fps ..
        ' --bitrate-kbps ' .. bitrate_kbps ..
        ' --encoder ' .. quoted(encoder) ..
        ' --encoder-preset ' .. quoted(encoder_preset) ..
        ' --ffmpeg ' .. quoted(ffmpeg_path) ..
        ' --status-file ' .. quoted(status_path) ..
        ' --stop-file ' .. quoted(stop_path) ..
        ' --log-file ' .. quoted(log_path)
    if computer_audio and audio_device ~= "" then
        command = command .. ' --audio-device ' .. quoted(audio_device)
    end

    local result = execute_hidden(command)
    if result ~= true and result ~= 0 then
        sender_state = "error"
        status_text = "发送器启动命令失败"
        log(obs.LOG_ERROR, status_text .. ": " .. tostring(result))
        if owns_virtual_camera then obs.obs_frontend_stop_virtualcam() end
        owns_virtual_camera = false
    else
        status_text = "正在启动"
        log(obs.LOG_INFO, "发送器已启动，监听端口 " .. port)
        if connection_mode == "usb" then
            local usb_command = 'cmd /d /c start "AppleLive USB" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File ' ..
                quoted(usb_script_path) .. ' -Port ' .. port
            execute_hidden(usb_command)
        end
    end
    return true
end

local function stop_sender(props, property)
    request_stop()
    return true
end

local function launch_dock()
    if file_exists(dock_path) and safe_argument(dock_path) and safe_argument(script_dir) then
        local directory = script_dir:gsub("[/\\]+$", "")
        local process_id = kernel and tonumber(kernel.GetCurrentProcessId()) or 0
        execute_hidden(quoted(dock_path) .. ' --directory ' .. quoted(directory) .. ' --obs-pid ' .. process_id)
    else
        log(obs.LOG_WARNING, "停靠面板组件缺失，请完整解压插件包")
    end
    return true
end

local function dock_tick()
    local content = read_file(command_path)
    if content and settings_ref then
        local data = obs.obs_data_create_from_json(content)
        if data then
            local id = obs.obs_data_get_string(data, "id")
            local action = obs.obs_data_get_string(data, "action")
            local created = obs.obs_data_get_double(data, "created_at")
            command_error = ""
            if os.time() - created > 15 or created - os.time() > 5 then
                command_error = "操作已过期，请重试"
            elseif id ~= last_command then
                refresh_status()
                if action == "settings" then
                    if sender_state == "running" or sender_state == "starting" or sender_state == "stopping" then
                        command_error = "请先停止传输，再调整设置"
                    else
                        local updates = obs.obs_data_get_obj(data, "settings")
                        if updates then
                            obs.obs_data_apply(settings_ref, updates)
                            obs.obs_data_release(updates)
                            script_update(settings_ref)
                            obs.obs_frontend_save()
                        end
                    end
                elseif action == "start" then
                    start_sender(nil, nil)
                    if sender_state ~= "starting" and sender_state ~= "running" then command_error = status_text end
                elseif action == "stop" then
                    if not request_stop() then command_error = "停止失败，请检查插件目录是否可写" end
                else command_error = "不支持的操作" end
            end
            last_command = id
            obs.obs_data_release(data)
        end
        remove_file(command_path)
    end
    local state = obs.obs_data_create()
    local config = obs.obs_data_create()
    obs.obs_data_set_string(config, "quality", quality)
    obs.obs_data_set_string(config, "connection_mode", connection_mode)
    obs.obs_data_set_bool(config, "computer_audio", computer_audio)
    obs.obs_data_set_int(config, "port", port)
    obs.obs_data_set_int(config, "width", width)
    obs.obs_data_set_int(config, "height", height)
    obs.obs_data_set_int(config, "fps", fps)
    obs.obs_data_set_int(config, "bitrate_kbps", bitrate_kbps)
    obs.obs_data_set_obj(state, "settings", config)
    obs.obs_data_set_int(state, "updated_at", os.time())
    obs.obs_data_set_string(state, "last_command", last_command)
    obs.obs_data_set_string(state, "command_error", command_error)
    obs.obs_data_set_string(state, "sender_state", sender_state)
    obs.obs_data_set_string(state, "status_text", status_text)
    local temp = bridge_path .. ".tmp"
    if write_file(temp, obs.obs_data_get_json(state)) then
        remove_file(bridge_path)
        rename_file(temp, bridge_path)
    end
    obs.obs_data_release(config)
    obs.obs_data_release(state)
end

function script_description()
    return "AppleLive OBS 节目输出至越狱 iPhone。"
end

function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "quality", "standard")
    obs.obs_data_set_default_string(settings, "connection_mode", "lan")
    obs.obs_data_set_default_bool(settings, "computer_audio", false)
    obs.obs_data_set_default_bool(settings, "show_advanced", false)
    obs.obs_data_set_default_int(settings, "port", 8765)
    obs.obs_data_set_default_int(settings, "width", 720)
    obs.obs_data_set_default_int(settings, "height", 1280)
    obs.obs_data_set_default_int(settings, "fps", 30)
    obs.obs_data_set_default_int(settings, "bitrate_kbps", 5000)
    obs.obs_data_set_default_string(settings, "encoder", "auto")
    obs.obs_data_set_default_string(settings, "encoder_preset", "veryfast")
    obs.obs_data_set_default_string(settings, "video_device", "HD Camera")
    obs.obs_data_set_default_string(settings, "ffmpeg_path", "ffmpeg")
    obs.obs_data_set_default_string(settings, "audio_device", "CABLE Output (VB-Audio Virtual Cable)")
end

function script_update(settings)
    quality = obs.obs_data_get_string(settings, "quality")
    connection_mode = obs.obs_data_get_string(settings, "connection_mode")
    computer_audio = obs.obs_data_get_bool(settings, "computer_audio")
    show_advanced = obs.obs_data_get_bool(settings, "show_advanced")
    port = obs.obs_data_get_int(settings, "port")
    width = obs.obs_data_get_int(settings, "width")
    height = obs.obs_data_get_int(settings, "height")
    fps = obs.obs_data_get_int(settings, "fps")
    bitrate_kbps = obs.obs_data_get_int(settings, "bitrate_kbps")
    encoder = obs.obs_data_get_string(settings, "encoder")
    encoder_preset = obs.obs_data_get_string(settings, "encoder_preset")
    video_device = obs.obs_data_get_string(settings, "video_device")
    ffmpeg_path = obs.obs_data_get_string(settings, "ffmpeg_path")
    audio_device = obs.obs_data_get_string(settings, "audio_device")
    if quality == "smooth" then
        width, height, fps, bitrate_kbps = 540, 960, 30, 3000
    elseif quality == "standard" then
        width, height, fps, bitrate_kbps = 720, 1280, 30, 5000
    elseif quality == "high" then
        width, height, fps, bitrate_kbps = 1080, 1920, 30, 8000
    end
end

local advanced_names = {
    "port", "width", "height", "fps", "bitrate_kbps", "encoder",
    "encoder_preset", "video_device", "audio_device", "ffmpeg_path"
}

local function set_advanced_visibility(props, visible)
    for _, name in ipairs(advanced_names) do
        obs.obs_property_set_visible(obs.obs_properties_get(props, name), visible)
    end
end

local function advanced_modified(props, property, settings)
    set_advanced_visibility(props, obs.obs_data_get_bool(settings, "show_advanced"))
    return true
end

local function quality_modified(props, property, settings)
    if obs.obs_data_get_string(settings, "quality") == "custom" then
        obs.obs_data_set_bool(settings, "show_advanced", true)
        set_advanced_visibility(props, true)
    end
    return true
end

function script_properties()
    refresh_status()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "dock_url", "停靠窗口地址：http://127.0.0.1:18765/", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_button(props, "dock", "启动停靠面板服务", launch_dock)
    obs.obs_properties_add_text(props, "status", "状态: " .. status_text, obs.OBS_TEXT_INFO)
    local qualities = obs.obs_properties_add_list(props, "quality", "画质", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(qualities, "流畅", "smooth")
    obs.obs_property_list_add_string(qualities, "标准", "standard")
    obs.obs_property_list_add_string(qualities, "高清", "high")
    obs.obs_property_list_add_string(qualities, "自定义", "custom")
    obs.obs_property_set_modified_callback(qualities, quality_modified)
    local modes = obs.obs_properties_add_list(props, "connection_mode", "连接方式", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(modes, "局域网", "lan")
    obs.obs_property_list_add_string(modes, "USB 数据线", "usb")
    obs.obs_properties_add_bool(props, "computer_audio", "传输电脑声音")
    obs.obs_properties_add_button(props, "start", "启动", start_sender)
    obs.obs_properties_add_button(props, "stop", "停止", stop_sender)
    local advanced = obs.obs_properties_add_bool(props, "show_advanced", "高级设置")
    obs.obs_property_set_modified_callback(advanced, advanced_modified)
    obs.obs_properties_add_int(props, "port", "监听端口", 1024, 65535, 1)
    obs.obs_properties_add_int(props, "width", "输出宽度", 320, 3840, 2)
    obs.obs_properties_add_int(props, "height", "输出高度", 240, 2160, 2)
    obs.obs_properties_add_int(props, "fps", "帧率", 1, 60, 1)
    obs.obs_properties_add_int(props, "bitrate_kbps", "视频码率 (kbps)", 500, 30000, 100)
    local encoders = obs.obs_properties_add_list(props, "encoder", "H.264 编码器", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    obs.obs_property_list_add_string(encoders, "自动", "auto")
    obs.obs_property_list_add_string(encoders, "NVIDIA NVENC", "nvenc")
    obs.obs_property_list_add_string(encoders, "CPU x264", "x264")
    local presets = obs.obs_properties_add_list(props, "encoder_preset", "CPU 编码速度", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
    for _, preset in ipairs({ "ultrafast", "superfast", "veryfast", "faster", "fast" }) do
        obs.obs_property_list_add_string(presets, preset, preset)
    end
    obs.obs_properties_add_text(props, "video_device", "视频设备 (dshow)", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "audio_device", "音频设备 (dshow)", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "ffmpeg_path", "FFmpeg 路径", obs.OBS_TEXT_DEFAULT)
    set_advanced_visibility(props, show_advanced)
    return props
end

function script_load(settings)
    settings_ref = settings
    obs.obs_data_addref(settings_ref)
    remove_file(command_path)
    dock_tick()
    launch_dock()
    obs.timer_add(refresh_status, 1000)
    obs.timer_add(dock_tick, 500)
end

function script_save(settings)
    if settings_ref then obs.obs_data_apply(settings, settings_ref) end
end

function script_unload()
    obs.timer_remove(dock_tick)
    remove_file(bridge_path)
    if settings_ref then obs.obs_data_release(settings_ref); settings_ref = nil end
    obs.timer_remove(refresh_status)
    refresh_status()
    if sender_state == "running" or sender_state == "starting" or sender_state == "stopping" then
        request_stop()
    elseif owns_virtual_camera and obs.obs_frontend_virtualcam_active() then
        obs.obs_frontend_stop_virtualcam()
    end
end
