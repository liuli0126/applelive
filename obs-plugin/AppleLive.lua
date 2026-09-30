obs = obslua

local separator = package.config:sub(1, 1)
local script_dir = script_path()
if script_dir:lower():match("%.lua$") then
    script_dir = script_dir:match("^(.*)[/\\]") or ""
end
if script_dir:sub(-1) ~= "\\" and script_dir:sub(-1) ~= "/" then
    script_dir = script_dir .. separator
end
local sender_path = script_dir .. "AppleLiveSender.exe"
local status_path = script_dir .. "applelive-status.json"
local stop_path = script_dir .. "applelive-stop.flag"
local log_path = script_dir .. "applelive-sender.log"

local port = 8765
local width = 1280
local height = 720
local fps = 30
local ffmpeg_path = "ffmpeg"
local audio_device = ""
local owns_virtual_camera = false
local sender_state = "stopped"
local launch_started_at = 0
local status_text = "未启动"
local last_logged_status = ""

local function log(level, message)
    obs.script_log(level, "[AppleLive] " .. message)
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if not file then return false end
    file:close()
    return true
end

local function write_file(path, content)
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

local function status_label(state, clients)
    if state == "running" then
        return "运行中 | iPhone 连接数 " .. tostring(clients or 0)
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
    local updated_at = obs.obs_data_get_int(data, "updated_at")
    obs.obs_data_release(data)
    if not state then return end
    if updated_at > 0 and os.time() - updated_at > 5 then
        state = "error"
        status_text = "发送器无响应，请查看日志"
    else
        if state == "running" and file_exists(stop_path) then state = "stopping" end
        status_text = status_label(state, clients)
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
    for _, value in ipairs({ sender_path, ffmpeg_path, audio_device, status_path, stop_path, log_path }) do
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

    os.remove(stop_path)
    os.remove(status_path)
    if not obs.obs_frontend_virtualcam_active() then
        obs.obs_frontend_start_virtualcam()
        owns_virtual_camera = true
    end
    if not obs.obs_frontend_virtualcam_active() then
        owns_virtual_camera = false
        status_text = "OBS 虚拟摄像头启动失败"
        log(obs.LOG_ERROR, status_text)
        return true
    end

    sender_state = "starting"
    launch_started_at = os.time()
    local command = 'cmd /d /c start "" /min ' .. quoted(sender_path) ..
        ' --host "0.0.0.0" --port ' .. port ..
        ' --video-device "OBS Virtual Camera"' ..
        ' --width ' .. width .. ' --height ' .. height .. ' --fps ' .. fps ..
        ' --ffmpeg ' .. quoted(ffmpeg_path) ..
        ' --status-file ' .. quoted(status_path) ..
        ' --stop-file ' .. quoted(stop_path) ..
        ' --log-file ' .. quoted(log_path)
    if audio_device ~= "" then
        command = command .. ' --audio-device ' .. quoted(audio_device)
    end

    local result = os.execute(command)
    if result ~= true and result ~= 0 then
        sender_state = "error"
        status_text = "发送器启动命令失败"
        log(obs.LOG_ERROR, status_text .. ": " .. tostring(result))
        if owns_virtual_camera then obs.obs_frontend_stop_virtualcam() end
        owns_virtual_camera = false
    else
        status_text = "正在启动"
        log(obs.LOG_INFO, "发送器已启动，监听端口 " .. port)
    end
    return true
end

local function stop_sender(props, property)
    request_stop()
    return true
end

function script_description()
    return "AppleLive OBS 节目输出至越狱 iPhone。"
end

function script_defaults(settings)
    obs.obs_data_set_default_int(settings, "port", 8765)
    obs.obs_data_set_default_int(settings, "width", 1280)
    obs.obs_data_set_default_int(settings, "height", 720)
    obs.obs_data_set_default_int(settings, "fps", 30)
    obs.obs_data_set_default_string(settings, "ffmpeg_path", "ffmpeg")
    obs.obs_data_set_default_string(settings, "audio_device", "")
end

function script_update(settings)
    port = obs.obs_data_get_int(settings, "port")
    width = obs.obs_data_get_int(settings, "width")
    height = obs.obs_data_get_int(settings, "height")
    fps = obs.obs_data_get_int(settings, "fps")
    ffmpeg_path = obs.obs_data_get_string(settings, "ffmpeg_path")
    audio_device = obs.obs_data_get_string(settings, "audio_device")
end

function script_properties()
    refresh_status()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "status", "状态: " .. status_text, obs.OBS_TEXT_INFO)
    obs.obs_properties_add_int(props, "port", "监听端口", 1024, 65535, 1)
    obs.obs_properties_add_int(props, "width", "输出宽度", 320, 3840, 2)
    obs.obs_properties_add_int(props, "height", "输出高度", 240, 2160, 2)
    obs.obs_properties_add_int(props, "fps", "帧率", 1, 60, 1)
    obs.obs_properties_add_text(props, "audio_device", "音频设备 (dshow)", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_text(props, "ffmpeg_path", "FFmpeg 路径", obs.OBS_TEXT_DEFAULT)
    obs.obs_properties_add_button(props, "start", "启动传输", start_sender)
    obs.obs_properties_add_button(props, "stop", "停止传输", stop_sender)
    return props
end

function script_load(settings)
    obs.timer_add(refresh_status, 1000)
end

function script_unload()
    obs.timer_remove(refresh_status)
    refresh_status()
    if sender_state == "running" or sender_state == "starting" or sender_state == "stopping" then
        request_stop()
    elseif owns_virtual_camera and obs.obs_frontend_virtualcam_active() then
        obs.obs_frontend_stop_virtualcam()
    end
end
