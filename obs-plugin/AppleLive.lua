obs = obslua

-- Use a wide Windows process launch so OBS paths containing Chinese text work.
local ffi, kernel
if package.config:sub(1, 1) == "\\" then
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
            ]]
        end
        ffi.cdef[[
            int __stdcall MultiByteToWideChar(unsigned int, unsigned long, const char *, int, unsigned short *, int);
            int __stdcall CreateProcessW(const unsigned short *, unsigned short *, void *, void *, int,
                unsigned long, void *, const unsigned short *, AL_STARTUPINFOW *, AL_PROCESS_INFORMATION *);
            int __stdcall CloseHandle(void *);
            unsigned long __stdcall GetCurrentProcessId(void);
        ]]
        kernel = ffi.load("kernel32")
    end
end

local directory = script_path()
if directory:lower():match("%.lua$") then directory = directory:match("^(.*)[/\\]") or "" end
if directory:sub(-1) ~= "\\" and directory:sub(-1) ~= "/" then directory = directory .. package.config:sub(1, 1) end
local dock_started = false

local function launch_dock()
    if dock_started then return true end
    local path = directory:gsub("[/\\]+$", "")
    local command = '"' .. directory .. 'AppleLiveDock.exe" --directory "' .. path ..
        '" --obs-pid ' .. (kernel and tonumber(kernel.GetCurrentProcessId()) or 0)
    if not kernel then
        local result = os.execute(command)
        if result then dock_started = true end
        return result
    end
    local length = kernel.MultiByteToWideChar(65001, 0, command, #command, nil, 0)
    if length == 0 then return false end
    local wide = ffi.new("unsigned short[?]", length + 1)
    if kernel.MultiByteToWideChar(65001, 0, command, #command, wide, length) == 0 then return false end
    local startup, process = ffi.new("AL_STARTUPINFOW"), ffi.new("AL_PROCESS_INFORMATION")
    startup.cb = ffi.sizeof(startup)
    if kernel.CreateProcessW(nil, wide, nil, nil, 0, 0x08000000, nil, nil, startup, process) == 0 then return false end
    kernel.CloseHandle(process.thread)
    kernel.CloseHandle(process.process)
    dock_started = true
    return true
end

local function delayed_launch()
    obs.timer_remove(delayed_launch)
    launch_dock()
end

local function frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then launch_dock() end
end

function script_description() return "AppleLive：OBS 推本地 RTMP，iPhone 拉 RTSP。" end
function script_properties()
    local props = obs.obs_properties_create()
    obs.obs_properties_add_text(props, "dock_url", "停靠窗口：http://127.0.0.1:18765/", obs.OBS_TEXT_INFO)
    obs.obs_properties_add_button(props, "dock", "启动停靠面板", launch_dock)
    return props
end
function script_load()
    obs.obs_frontend_add_event_callback(frontend_event)
    obs.timer_add(delayed_launch, 3000)
end

function script_unload()
    obs.timer_remove(delayed_launch)
    obs.obs_frontend_remove_event_callback(frontend_event)
end
