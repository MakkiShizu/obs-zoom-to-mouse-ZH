--
-- OBS Zoom to Mouse
-- 一个 OBS Lua 脚本，用于将显示器采集源放大到鼠标位置。
-- 基于 https://github.com/BlankSourceCode/obs-zoom-to-mouse 汉化，由 DeepSeek V4 Flash 翻译。
-- Copyright (c) BlankSourceCode.  All rights reserved.
--

local obs = obslua
local ffi = require("ffi")
local VERSION = "1.0.2"
local CROP_FILTER_NAME = "obs-zoom-to-mouse-crop"

local socket_available, socket = pcall(require, "ljsocket")
local socket_server = nil
local socket_mouse = nil

local source_name = ""
local source = nil
local sceneitem = nil
local sceneitem_info_orig = nil
local sceneitem_crop_orig = nil
local sceneitem_info = nil
local sceneitem_crop = nil
local crop_filter = nil
local crop_filter_temp = nil
local crop_filter_settings = nil
local crop_filter_info_orig = { x = 0, y = 0, w = 0, h = 0 }
local crop_filter_info = { x = 0, y = 0, w = 0, h = 0 }
local monitor_info = nil
local zoom_info = {
    source_size = { width = 0, height = 0 },
    source_crop = { x = 0, y = 0, w = 0, h = 0 },
    source_crop_filter = { x = 0, y = 0, w = 0, h = 0 },
    zoom_to = 2
}
local zoom_time = 0
local zoom_target = nil
local locked_center = nil
local locked_last_pos = nil
local hotkey_zoom_id = nil
local hotkey_follow_id = nil
local is_timer_running = false

local win_point = nil
local x11_display = nil
local x11_root = nil
local x11_mouse = nil
local osx_lib = nil
local osx_nsevent = nil
local osx_mouse_location = nil

local use_auto_follow_mouse = true
local use_follow_outside_bounds = false
local is_following_mouse = false
local follow_speed = 0.1
local follow_border = 0
local follow_safezone_sensitivity = 10
local use_follow_auto_lock = false
local zoom_value = 2
local zoom_speed = 0.1
local allow_all_sources = false
local use_monitor_override = false
local monitor_override_x = 0
local monitor_override_y = 0
local monitor_override_w = 0
local monitor_override_h = 0
local monitor_override_sx = 0
local monitor_override_sy = 0
local monitor_override_dw = 0
local monitor_override_dh = 0
local use_socket = false
local socket_port = 0
local socket_poll = 1000
local debug_logs = false
local is_obs_loaded = false
local is_script_loaded = false

local ZoomState = {
    None = 0,
    ZoomingIn = 1,
    ZoomingOut = 2,
    ZoomedIn = 3,
}
local zoom_state = ZoomState.None

local version = obs.obs_get_version_string()
local m1, m2 = version:match("(%d+%.%d+)%.(%d+)")
local major = tonumber(m1) or 0
local minor = tonumber(m2) or 0

-- 为各平台定义鼠标光标函数
if ffi.os == "Windows" then
    ffi.cdef([[
        typedef int BOOL;
        typedef struct{
            long x;
            long y;
        } POINT, *LPPOINT;
        BOOL GetCursorPos(LPPOINT);
    ]])
    win_point = ffi.new("POINT[1]")
elseif ffi.os == "Linux" then
    ffi.cdef([[
        typedef unsigned long XID;
        typedef XID Window;
        typedef void Display;
        Display* XOpenDisplay(char*);
        XID XDefaultRootWindow(Display *display);
        int XQueryPointer(Display*, Window, Window*, Window*, int*, int*, int*, int*, unsigned int*);
        int XCloseDisplay(Display*);
    ]])

    x11_lib = ffi.load("X11.so.6")
    x11_display = x11_lib.XOpenDisplay(nil)
    if x11_display ~= nil then
        x11_root = x11_lib.XDefaultRootWindow(x11_display)
        x11_mouse = {
            root_win = ffi.new("Window[1]"),
            child_win = ffi.new("Window[1]"),
            root_x = ffi.new("int[1]"),
            root_y = ffi.new("int[1]"),
            win_x = ffi.new("int[1]"),
            win_y = ffi.new("int[1]"),
            mask = ffi.new("unsigned int[1]")
        }
    end
elseif ffi.os == "OSX" then
    ffi.cdef([[
        typedef struct {
            double x;
            double y;
        } CGPoint;
        typedef void* SEL;
        typedef void* id;
        typedef void* Method;

        SEL sel_registerName(const char *str);
        id objc_getClass(const char*);
        Method class_getClassMethod(id cls, SEL name);
        void* method_getImplementation(Method);
        int access(const char *path, int amode);
    ]])

    osx_lib = ffi.load("libobjc")
    if osx_lib ~= nil then
        osx_nsevent = {
            class = osx_lib.objc_getClass("NSEvent"),
            sel = osx_lib.sel_registerName("mouseLocation")
        }
        local method = osx_lib.class_getClassMethod(osx_nsevent.class, osx_nsevent.sel)
        if method ~= nil then
            local imp = osx_lib.method_getImplementation(method)
            osx_mouse_location = ffi.cast("CGPoint(*)(void*, void*)", imp)
        end
    end
end

---
-- 获取当前鼠标位置
---@return table 鼠标位置
function get_mouse_pos()
    local mouse = { x = 0, y = 0 }

    if socket_mouse ~= nil then
        mouse.x = socket_mouse.x
        mouse.y = socket_mouse.y
    else
        if ffi.os == "Windows" then
            if win_point and ffi.C.GetCursorPos(win_point) ~= 0 then
                mouse.x = win_point[0].x
                mouse.y = win_point[0].y
            end
        elseif ffi.os == "Linux" then
            if x11_lib ~= nil and x11_display ~= nil and x11_root ~= nil and x11_mouse ~= nil then
                if x11_lib.XQueryPointer(x11_display, x11_root, x11_mouse.root_win, x11_mouse.child_win, x11_mouse.root_x, x11_mouse.root_y, x11_mouse.win_x, x11_mouse.win_y, x11_mouse.mask) ~= 0 then
                    mouse.x = tonumber(x11_mouse.win_x[0])
                    mouse.y = tonumber(x11_mouse.win_y[0])
                end
            end
        elseif ffi.os == "OSX" then
            if osx_lib ~= nil and osx_nsevent ~= nil and osx_mouse_location ~= nil then
                local point = osx_mouse_location(osx_nsevent.class, osx_nsevent.sel)
                mouse.x = point.x
                if monitor_info ~= nil then
                    if monitor_info.display_height > 0 then
                        mouse.y = monitor_info.display_height - point.y
                    else
                        mouse.y = monitor_info.height - point.y
                    end
                end
            end
        end
    end

    return mouse
end

---
-- 获取当前平台的显示器采集源信息
---@return any
function get_dc_info()
    if ffi.os == "Windows" then
        return {
            source_id = "monitor_capture",
            prop_id = "monitor_id",
            prop_type = "string"
        }
    elseif ffi.os == "Linux" then
        return {
            source_id = "xshm_input",
            prop_id = "screen",
            prop_type = "int"
        }
    elseif ffi.os == "OSX" then
        if major > 29.0 then
            return {
                source_id = "screen_capture",
                prop_id = "display_uuid",
                prop_type = "string"
            }
        else
            return {
                source_id = "display_capture",
                prop_id = "display",
                prop_type = "int"
            }
        end
    end

    return nil
end

---
-- 记录一条消息到 OBS 脚本控制台
---@param msg string 要记录的消息
function log(msg)
    if debug_logs then
        obs.script_log(obs.OBS_LOG_INFO, msg)
    end
end

---
-- 将 Lua 表格格式化为字符串
---@param tbl any
---@param indent any
---@return string 格式化后的字符串
function format_table(tbl, indent)
    if not indent then
        indent = 0
    end

    local str = "{\n"
    for key, value in pairs(tbl) do
        local tabs = string.rep("  ", indent + 1)
        if type(value) == "table" then
            str = str .. tabs .. key .. " = " .. format_table(value, indent + 1) .. ",\n"
        else
            str = str .. tabs .. key .. " = " .. tostring(value) .. ",\n"
        end
    end
    str = str .. string.rep("  ", indent) .. "}"

    return str
end

---
-- 线性插值
---@param v0 number 起始位置
---@param v1 number 结束位置
---@param t number 时间
---@return number 插值结果
function lerp(v0, v1, t)
    return v0 * (1 - t) + v1 * t;
end

---
-- 缓入缓出
---@param t number 时间（0 到 1 之间）
---@return number
function ease_in_out(t)
    t = t * 2
    if t < 1 then
        return 0.5 * t * t * t
    else
        t = t - 2
        return 0.5 * (t * t * t + 2)
    end
end

---
-- 将给定值限制在最小值和最大值之间
---@param min number 最小值
---@param max number 最大值
---@param value number 要限制的值
---@return number 限制后的值
function clamp(min, max, value)
    return math.max(min, math.min(max, value))
end

---
-- 获取显示器的尺寸和位置，以便确定鼠标左上角坐标
---@param source any OBS 源
---@return table|nil 显示器的尺寸/左上角坐标
function get_monitor_info(source)
    local info = nil

    -- 仅在使用显示器源的自动计算时才执行开销较大的查找
    if is_display_capture(source) and not use_monitor_override then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            local props = obs.obs_source_properties(source)
            if props ~= nil then
                local monitor_id_prop = obs.obs_properties_get(props, dc_info.prop_id)
                if monitor_id_prop then
                    local found = nil
                    local settings = obs.obs_source_get_settings(source)
                    if settings ~= nil then
                        local to_match
                        if dc_info.prop_type == "string" then
                            to_match = obs.obs_data_get_string(settings, dc_info.prop_id)
                        elseif dc_info.prop_type == "int" then
                            to_match = obs.obs_data_get_int(settings, dc_info.prop_id)
                        end

                        local item_count = obs.obs_property_list_item_count(monitor_id_prop);
                        for i = 0, item_count do
                            local name = obs.obs_property_list_item_name(monitor_id_prop, i)
                            local value
                            if dc_info.prop_type == "string" then
                                value = obs.obs_property_list_item_string(monitor_id_prop, i)
                            elseif dc_info.prop_type == "int" then
                                value = obs.obs_property_list_item_int(monitor_id_prop, i)
                            end

                            if value == to_match then
                                found = name
                                break
                            end
                        end
                        obs.obs_data_release(settings)
                    end

                    -- 这在我的机器上有效，显示器名称格式为 "U2790B: 3840x2160 @ -1920,0（主显示器）"
                    -- 不确定在其他机器和/或 OBS 版本上是否同样适用
                    -- TODO: 如果对其他人无效，请使用自定义 FFI 调用来查找显示器的左上角 x/y 坐标
                    -- TODO: 将其重构为适用于 Windows/Linux/Mac 的方法（假设不能这样处理）
                    if found then
                        log("正在解析显示名称：" .. found)
                        local x, y = found:match("(-?%d+),(-?%d+)")
                        local width, height = found:match("(%d+)x(%d+)")

                        info = { x = 0, y = 0, width = 0, height = 0 }
                        info.x = tonumber(x, 10)
                        info.y = tonumber(y, 10)
                        info.width = tonumber(width, 10)
                        info.height = tonumber(height, 10)
                        info.scale_x = 1
                        info.scale_y = 1
                        info.display_width = info.width
                        info.display_height = info.height

                        log("解析到以下显示信息\n" .. format_table(info))

                        if info.width == 0 and info.height == 0 then
                            info = nil
                        end
                    end
                end

                obs.obs_properties_destroy(props)
            end
        end
    end

    if use_monitor_override then
        info = {
            x = monitor_override_x,
            y = monitor_override_y,
            width = monitor_override_w,
            height = monitor_override_h,
            scale_x = monitor_override_sx,
            scale_y = monitor_override_sy,
            display_width = monitor_override_dw,
            display_height = monitor_override_dh
        }
    end

    if not info then
        log("警告：无法自动计算缩放源位置和尺寸。\n" ..
            "         请尝试使用「手动设置源位置」选项并添加覆盖值")
    end

    return info
end

---
-- 检查指定源是否为显示器采集源
-- 如果 source_to_check 为 nil，则返回 false
---@param source_to_check any 要检查的源
---@return boolean 如果是显示器采集源返回 true，否则返回 false
function is_display_capture(source_to_check)
    if source_to_check ~= nil then
        local dc_info = get_dc_info()
        if dc_info ~= nil then
            -- 快速检查确认这是显示器采集源
            if allow_all_sources then
                local source_type = obs.obs_source_get_id(source_to_check)
                if source_type == dc_info.source_id then
                    return true
                end
            else
                return true
            end
        end
    end

    return false
end

---
-- 释放当前的场景项并将数据重置为默认值
function release_sceneitem()
    if is_timer_running then
        obs.timer_remove(on_timer)
        is_timer_running = false
    end

    zoom_state = ZoomState.None

    if sceneitem ~= nil then
        if crop_filter ~= nil and source ~= nil then
            log("缩放裁剪滤镜已移除")
            obs.obs_source_filter_remove(source, crop_filter)
            obs.obs_source_release(crop_filter)
            crop_filter = nil
        end

        if crop_filter_temp ~= nil and source ~= nil then
            log("转换裁剪滤镜已移除")
            obs.obs_source_filter_remove(source, crop_filter_temp)
            obs.obs_source_release(crop_filter_temp)
            crop_filter_temp = nil
        end

        if crop_filter_settings ~= nil then
            obs.obs_data_release(crop_filter_settings)
            crop_filter_settings = nil
        end

        if sceneitem_info_orig ~= nil then
            log("变换信息已重置为原始值")
            obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info_orig)
            sceneitem_info_orig = nil
        end

        if sceneitem_crop_orig ~= nil then
            log("变换裁剪已重置为原始值")
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop_orig)
            sceneitem_crop_orig = nil
        end

        obs.obs_sceneitem_release(sceneitem)
        sceneitem = nil
    end

    if source ~= nil then
        obs.obs_source_release(source)
        source = nil
    end
end

---
-- 用刷新后的源数据更新当前场景项
-- 可选择释放现有场景项并从当前场景获取新的场景项
---@param find_newest boolean true 表示释放当前场景项并获取新的
function refresh_sceneitem(find_newest)
    -- TODO: 弄清楚为什么在更新时需要通过命名源获取尺寸，而不是通过 sceneitem source
    local source_raw = { width = 0, height = 0 }

    if find_newest then
        -- 释放当前的场景项，因为我们即将替换它
        release_sceneitem()

        -- 如果未选择缩放源则提前退出
        -- 这允许用户将裁剪数据重置为原始值，
        -- 更新设置，然后通过重新选择源强制进行转换
        if source_name == "obs-zoom-to-mouse-none" then
            return
        end

        -- 在当前场景中获取可用的缩放源
        log("正在查找缩放源 '" .. source_name .. "' 的场景项")
        if source_name ~= nil then
            source = obs.obs_get_source_by_name(source_name)
            if source ~= nil then
                -- 获取源尺寸，加载时有效但 sceneitem source 无效
                source_raw.width = obs.obs_source_get_width(source)
                source_raw.height = obs.obs_source_get_height(source)

                -- 获取当前场景
                local scene_source = obs.obs_frontend_get_current_scene()
                if scene_source ~= nil then
                    local function find_scene_item_by_name(root_scene)
                        local queue = {}
                        table.insert(queue, root_scene)

                        while #queue > 0 do
                            local s = table.remove(queue, 1)
                            log("正在检查场景 '" .. obs.obs_source_get_name(obs.obs_scene_get_source(s)) .. "'")

                            -- 检查当前场景是否有目标场景项
                            local found = obs.obs_scene_find_source(s, source_name)
                            if found ~= nil then
                                log("找到场景项 '" .. source_name .. "'")
                                obs.obs_sceneitem_addref(found)
                                return found
                            end

                            -- 如果当前场景包含嵌套场景，将其加入队列供后续检查
                            local all_items = obs.obs_scene_enum_items(s)
                            if all_items then
                                for _, item in pairs(all_items) do
                                    local nested = obs.obs_sceneitem_get_source(item)
                                    if nested ~= nil then
                                        if obs.obs_source_is_scene(nested) then
                                            local nested_scene = obs.obs_scene_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        elseif obs.obs_source_is_group(nested) then
                                            local nested_scene = obs.obs_group_from_source(nested)
                                            table.insert(queue, nested_scene)
                                        end
                                    end
                                end
                                obs.sceneitem_list_release(all_items)
                            end
                        end

                        return nil
                    end

                    -- 遍历所有项目查找 source_name 对应的场景项
                    -- 从当前场景开始，使用 BFS 搜索任何嵌套场景
                    local current = obs.obs_scene_from_source(scene_source)
                    sceneitem = find_scene_item_by_name(current)

                    obs.obs_source_release(scene_source)
                end

                if not sceneitem then
                    log("警告：源不属于当前场景层级。\n" ..
                        "         请尝试选择其他缩放源或切换场景。")
                    obs.obs_sceneitem_release(sceneitem)
                    obs.obs_source_release(source)

                    sceneitem = nil
                    source = nil
                    return
                end
            end
        end
    end

    if not monitor_info then
        monitor_info = get_monitor_info(source)
    end

    local is_non_display_capture = not is_display_capture(source)
    if is_non_display_capture then
        if not use_monitor_override then
            log("错误：选中的缩放源不是显示器采集源。\n" ..
                "       你必须启用「手动设置源位置」并为尺寸和位置设置正确的覆盖值。")
        end
    end

    if sceneitem ~= nil then
        -- 保存原始设置以便之后恢复
        sceneitem_info_orig = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info_orig)

        sceneitem_crop_orig = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop_orig)

        sceneitem_info = obs.obs_transform_info()
        obs.obs_sceneitem_get_info2(sceneitem, sceneitem_info)

        sceneitem_crop = obs.obs_sceneitem_crop()
        obs.obs_sceneitem_get_crop(sceneitem, sceneitem_crop)

        if is_non_display_capture then
            -- 非显示器采集源无法正确报告裁剪值
            sceneitem_crop_orig.left = 0
            sceneitem_crop_orig.top = 0
            sceneitem_crop_orig.right = 0
            sceneitem_crop_orig.bottom = 0
        end

        -- 获取当前源尺寸（经过任何裁剪滤镜后的值）
        if not source then
            log("错误：无法获取场景项对应的源 (" .. source_name .. ")")
        end

        -- TODO: 弄清楚为什么需要这个后备代码
        local source_width = obs.obs_source_get_base_width(source)
        local source_height = obs.obs_source_get_base_height(source)

        if source_width == 0 then
            source_width = source_raw.width
        end
        if source_height == 0 then
            source_height = source_raw.height
        end

        if source_width == 0 or source_height == 0 then
            if monitor_info ~= nil and monitor_info.width > 0 and monitor_info.height > 0 then
                log("警告：无法确定源尺寸。\n" ..
                    "         使用来自信息的源尺寸：" .. monitor_info.width .. ", " .. monitor_info.height)
                source_width = monitor_info.width
                source_height = monitor_info.height
            else
                log("错误：无法确定源尺寸。\n" ..
                "       请尝试使用「手动设置源位置」选项并添加覆盖值")
            end
        else
            log("使用源尺寸：" .. source_width .. ", " .. source_height)
        end

        -- 将当前变换转换为可正确修改的缩放变换
        -- 理想情况下用户已设置有效的变换，我们无需修改，因为这并非 100% 有效
        if sceneitem_info.bounds_type == obs.OBS_BOUNDS_NONE then
            sceneitem_info.bounds_type = obs.OBS_BOUNDS_SCALE_INNER
            sceneitem_info.bounds_alignment = 5 -- (5 == OBS_ALIGN_TOP | OBS_ALIGN_LEFT) (0 == OBS_ALIGN_CENTER)
            sceneitem_info.bounds.x = source_width * sceneitem_info.scale.x
            sceneitem_info.bounds.y = source_height * sceneitem_info.scale.y

            obs.obs_sceneitem_set_info2(sceneitem, sceneitem_info)

            log("警告：发现现有的非边界框变换，可能导致缩放问题。\n" ..
                "         设置已自动转换为边界框缩放变换。\n" ..
                "         如果布局出现问题，请考虑手动将变换设置为使用边界框。")
        end

        -- 获取现有裁剪滤镜的信息（非我们创建的）
        zoom_info.source_crop_filter = { x = 0, y = 0, w = 0, h = 0 }
        local found_crop_filter = false
        local filters = obs.obs_source_enum_filters(source)
        if filters ~= nil then
            for k, v in pairs(filters) do
                local id = obs.obs_source_get_id(v)
                if id == "crop_filter" then
                    local name = obs.obs_source_get_name(v)
                    if name ~= CROP_FILTER_NAME and name ~= "temp_" .. CROP_FILTER_NAME then
                        found_crop_filter = true
                        local settings = obs.obs_source_get_settings(v)
                        if settings ~= nil then
                            if not obs.obs_data_get_bool(settings, "relative") then
                                zoom_info.source_crop_filter.x =
                                    zoom_info.source_crop_filter.x + obs.obs_data_get_int(settings, "left")
                                zoom_info.source_crop_filter.y =
                                    zoom_info.source_crop_filter.y + obs.obs_data_get_int(settings, "top")
                                zoom_info.source_crop_filter.w =
                                    zoom_info.source_crop_filter.w + obs.obs_data_get_int(settings, "cx")
                                zoom_info.source_crop_filter.h =
                                    zoom_info.source_crop_filter.h + obs.obs_data_get_int(settings, "cy")
                                log("找到现有的非相对裁剪/填充滤镜 (" ..
                                    name ..
                                    ")。应用设置 " .. format_table(zoom_info.source_crop_filter))
                            else
                                log("警告：发现现有的相对裁剪/填充滤镜 (" .. name .. ")。\n" ..
                                    "         这将导致缩放问题。请转换为非相对设置。")
                            end
                            obs.obs_data_release(settings)
                        end
                    end
                end
            end

            obs.source_list_release(filters)
        end

        -- 如果用户设置了变换裁剪，需要将其转换为裁剪滤镜以正确缩放
        -- 理想情况下用户应手动操作，使用裁剪滤镜而非变换裁剪，因为这并非 100% 有效
        if not found_crop_filter and (sceneitem_crop_orig.left ~= 0 or sceneitem_crop_orig.top ~= 0 or sceneitem_crop_orig.right ~= 0 or sceneitem_crop_orig.bottom ~= 0) then
            log("正在创建新的裁剪滤镜")

            -- 更新源尺寸
            source_width = source_width - (sceneitem_crop_orig.left + sceneitem_crop_orig.right)
            source_height = source_height - (sceneitem_crop_orig.top + sceneitem_crop_orig.bottom)

            -- 更新源裁剪滤镜信息
            zoom_info.source_crop_filter.x = sceneitem_crop_orig.left
            zoom_info.source_crop_filter.y = sceneitem_crop_orig.top
            zoom_info.source_crop_filter.w = source_width
            zoom_info.source_crop_filter.h = source_height

            -- 添加模拟现有变换裁剪的新裁剪滤镜
            local settings = obs.obs_data_create()
            obs.obs_data_set_bool(settings, "relative", false)
            obs.obs_data_set_int(settings, "left", zoom_info.source_crop_filter.x)
            obs.obs_data_set_int(settings, "top", zoom_info.source_crop_filter.y)
            obs.obs_data_set_int(settings, "cx", zoom_info.source_crop_filter.w)
            obs.obs_data_set_int(settings, "cy", zoom_info.source_crop_filter.h)
            crop_filter_temp = obs.obs_source_create_private("crop_filter", "temp_" .. CROP_FILTER_NAME, settings)
            obs.obs_source_filter_add(source, crop_filter_temp)
            obs.obs_data_release(settings)

            -- 清除变换裁剪
            sceneitem_crop.left = 0
            sceneitem_crop.top = 0
            sceneitem_crop.right = 0
            sceneitem_crop.bottom = 0
            obs.obs_sceneitem_set_crop(sceneitem, sceneitem_crop)

            log("警告：发现现有的变换裁剪，可能导致缩放问题。\n" ..
                "         设置已自动转换为非相对裁剪/填充滤镜。\n" ..
                "         如果布局出现问题，请考虑手动添加滤镜。")
        elseif found_crop_filter then
            source_width = zoom_info.source_crop_filter.w
            source_height = zoom_info.source_crop_filter.h
        end

        -- 获取正确缩放所需的其余信息
        zoom_info.source_size = { width = source_width, height = source_height }
        zoom_info.source_crop = {
            l = sceneitem_crop_orig.left,
            t = sceneitem_crop_orig.top,
            r = sceneitem_crop_orig.right,
            b = sceneitem_crop_orig.bottom
        }
        --log("变换已更新。使用以下值 -\n" .. format_table(zoom_info))

        -- 设置与源匹配的初始裁剪滤镜数据
        crop_filter_info_orig = { x = 0, y = 0, w = zoom_info.source_size.width, h = zoom_info.source_size.height }
        crop_filter_info = {
            x = crop_filter_info_orig.x,
            y = crop_filter_info_orig.y,
            w = crop_filter_info_orig.w,
            h = crop_filter_info_orig.h
        }

        -- 获取或创建用于缩放的裁剪滤镜
        crop_filter = obs.obs_source_get_filter_by_name(source, CROP_FILTER_NAME)
        if crop_filter == nil then
            crop_filter_settings = obs.obs_data_create()
            obs.obs_data_set_bool(crop_filter_settings, "relative", false)
            crop_filter = obs.obs_source_create_private("crop_filter", CROP_FILTER_NAME, crop_filter_settings)
            obs.obs_source_filter_add(source, crop_filter)
        else
            crop_filter_settings = obs.obs_source_get_settings(crop_filter)
        end

        obs.obs_source_filter_set_order(source, crop_filter, obs.OBS_ORDER_MOVE_BOTTOM)
        set_crop_settings(crop_filter_info_orig)
    end
end

---
-- 获取缩放目标位置
---@param zoom any
---@return table
function get_target_position(zoom)
    local mouse = get_mouse_pos()

    -- 如果有显示器信息，我们可以通过显示器左上角偏移鼠标位置
    -- 这是因为显示器采集源假设左上角为 0,0，但鼠标使用的是整个桌面区域，
    -- 例如第二个显示器从 x:1920, y:0 开始，在 1920,0 点击时应显示为源上的 0,0
    if monitor_info then
        mouse.x = mouse.x - monitor_info.x
        mouse.y = mouse.y - monitor_info.y
    end

    -- 通过裁剪左上角偏移鼠标位置，因为如果从显示器裁剪了 100px，在 100,0 点击时应是左上角 0,0
    mouse.x = mouse.x - zoom.source_crop_filter.x
    mouse.y = mouse.y - zoom.source_crop_filter.y

    -- 如果源使用与显示器不同的缩放比例，则应用该比例
    -- 这可能在克隆源时发生，克隆的场景包含全屏显示器
    -- 显示器是全桌面像素尺寸，但克隆场景被缩放到画布大小
    -- 因此需要按比例缩放鼠标移动
    if monitor_info and monitor_info.scale_x and monitor_info.scale_y then
        mouse.x = mouse.x * monitor_info.scale_x
        mouse.y = mouse.y * monitor_info.scale_y
    end

    -- 获取缩放后的新尺寸
    -- 注意：使用裁剪/填充滤镜时，尺寸变小（除以缩放倍数）意味着在相同空间中看到更少的图像
    -- 从而使其看起来更大（即放大）
    local new_size = {
        width = zoom.source_size.width / zoom.zoom_to,
        height = zoom.source_size.height / zoom.zoom_to
    }

    -- 裁剪/填充滤镜的新偏移量 = 点击位置减去尺寸的一半，使点击点成为新中心
    local pos = {
        x = mouse.x - new_size.width * 0.5,
        y = mouse.y - new_size.height * 0.5
    }

    -- 创建完整的裁剪结果
    local crop = {
        x = pos.x,
        y = pos.y,
        w = new_size.width,
        h = new_size.height,
    }

    -- 确保缩放范围在源边界内，避免显示用户通过裁剪设置隐藏的内容
    crop.x = math.floor(clamp(0, (zoom.source_size.width - new_size.width), crop.x))
    crop.y = math.floor(clamp(0, (zoom.source_size.height - new_size.height), crop.y))

    return { crop = crop, raw_center = mouse, clamped_center = { x = math.floor(crop.x + crop.w * 0.5), y = math.floor(crop.y + crop.h * 0.5) } }
end

function on_toggle_follow(pressed)
    if pressed then
        is_following_mouse = not is_following_mouse
        log("鼠标追踪已" .. (is_following_mouse and "开启" or "关闭"))

        if is_following_mouse and zoom_state == ZoomState.ZoomedIn then
            -- 正在缩放，需要启动定时器运行动画和追踪
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_toggle_zoom(pressed)
    if pressed then
        -- 检查是否处于安全的缩放状态
        if zoom_state == ZoomState.ZoomedIn or zoom_state == ZoomState.None then
            if zoom_state == ZoomState.ZoomedIn then
                log("正在缩小")
                -- 缩小：将目标设置回原始值
                zoom_state = ZoomState.ZoomingOut
                zoom_time = 0
                locked_center = nil
                locked_last_pos = nil
                zoom_target = { crop = crop_filter_info_orig, c = sceneitem_crop_orig }
                if is_following_mouse then
                    is_following_mouse = false
                    log("鼠标追踪已关闭（因缩小）")
                end
            else
                log("正在放大")
                -- 放大：根据点击缩放时的鼠标位置计算新目标
                zoom_state = ZoomState.ZoomingIn
                zoom_info.zoom_to = zoom_value
                zoom_time = 0
                locked_center = nil
                locked_last_pos = nil
                zoom_target = get_target_position(zoom_info)
            end

            -- 正在缩放，需要启动定时器运行动画和追踪
            if is_timer_running == false then
                is_timer_running = true
                local timer_interval = math.floor(obs.obs_get_frame_interval_ns() / 1000000)
                obs.timer_add(on_timer, timer_interval)
            end
        end
    end
end

function on_timer()
    if crop_filter_info ~= nil and zoom_target ~= nil then
        -- 更新用于动画的缩放时间
        zoom_time = zoom_time + zoom_speed

        if zoom_state == ZoomState.ZoomingOut or zoom_state == ZoomState.ZoomingIn then
            -- 执行缩放动画时，对裁剪进行线性插值到目标值
            if zoom_time <= 1 then
                -- 如果开启了自动跟随，确保在缩放过程中鼠标保持在视野内
                -- 防止用户在动画播放时大量移动鼠标
                if zoom_state == ZoomState.ZoomingIn and use_auto_follow_mouse then
                    zoom_target = get_target_position(zoom_info)
                end
                crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, ease_in_out(zoom_time))
                crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, ease_in_out(zoom_time))
                crop_filter_info.w = lerp(crop_filter_info.w, zoom_target.crop.w, ease_in_out(zoom_time))
                crop_filter_info.h = lerp(crop_filter_info.h, zoom_target.crop.h, ease_in_out(zoom_time))
                set_crop_settings(crop_filter_info)
            end
        else
            -- 非缩放状态时，仅移动 x/y 来跟随鼠标（宽/高保持不变）
            if is_following_mouse then
                zoom_target = get_target_position(zoom_info)

                local skip_frame = false
                if not use_follow_outside_bounds then
                    if zoom_target.raw_center.x < zoom_target.crop.x or
                        zoom_target.raw_center.x > zoom_target.crop.x + zoom_target.crop.w or
                        zoom_target.raw_center.y < zoom_target.crop.y or
                        zoom_target.raw_center.y > zoom_target.crop.y + zoom_target.crop.h then
                        -- 超出源边界时不跟随鼠标
                        skip_frame = true
                    end
                end

                if not skip_frame then
                    -- locked_center 存在表示当前处于锁定区域
                    -- 在鼠标移出该区域前不追踪
                    if locked_center ~= nil then
                        local diff = {
                            x = zoom_target.raw_center.x - locked_center.x,
                            y = zoom_target.raw_center.y - locked_center.y
                        }

                        local track = {
                            x = zoom_target.crop.w * (0.5 - (follow_border * 0.01)),
                            y = zoom_target.crop.h * (0.5 - (follow_border * 0.01))
                        }

                        if math.abs(diff.x) > track.x or math.abs(diff.y) > track.y then
                            -- 光标进入活动边界区域，清除锁定中心以恢复追踪
                            locked_center = nil
                            locked_last_pos = {
                                x = zoom_target.raw_center.x,
                                y = zoom_target.raw_center.y,
                                diff_x = diff.x,
                                diff_y = diff.y
                            }
                            log("已离开锁定区域 — 恢复追踪")
                        end
                    end

                    if locked_center == nil and (zoom_target.crop.x ~= crop_filter_info.x or zoom_target.crop.y ~= crop_filter_info.y) then
                        crop_filter_info.x = lerp(crop_filter_info.x, zoom_target.crop.x, follow_speed)
                        crop_filter_info.y = lerp(crop_filter_info.y, zoom_target.crop.y, follow_speed)
                        set_crop_settings(crop_filter_info)

                        -- 检查鼠标是否已停止移动足够长时间，以创建新的安全区
                        if is_following_mouse and locked_center == nil and locked_last_pos ~= nil then
                            local diff = {
                                x = math.abs(crop_filter_info.x - zoom_target.crop.x),
                                y = math.abs(crop_filter_info.y - zoom_target.crop.y),
                                auto_x = zoom_target.raw_center.x - locked_last_pos.x,
                                auto_y = zoom_target.raw_center.y - locked_last_pos.y
                            }

                            locked_last_pos.x = zoom_target.raw_center.x
                            locked_last_pos.y = zoom_target.raw_center.y

                            local lock = false
                            if math.abs(locked_last_pos.diff_x) > math.abs(locked_last_pos.diff_y) then
                                if (diff.auto_x < 0 and locked_last_pos.diff_x > 0) or (diff.auto_x > 0 and locked_last_pos.diff_x < 0) then
                                    lock = true
                                end
                            else
                                if (diff.auto_y < 0 and locked_last_pos.diff_y > 0) or (diff.auto_y > 0 and locked_last_pos.diff_y < 0) then
                                    lock = true
                                end
                            end

                            if (lock and use_follow_auto_lock) or (diff.x <= follow_safezone_sensitivity and diff.y <= follow_safezone_sensitivity) then
                                -- 将新中心设为当前镜头位置（可能与鼠标位置不同，因为我们使用插值靠近鼠标）
                                locked_center = {
                                    x = math.floor(crop_filter_info.x + zoom_target.crop.w * 0.5),
                                    y = math.floor(crop_filter_info.y + zoom_target.crop.h * 0.5)
                                }
                                log("光标停止。追踪锁定至 " .. locked_center.x .. ", " .. locked_center.y)
                            end
                        end
                    end
                end
            end
        end

        -- 检查动画是否结束
        if zoom_time >= 1 then
            local should_stop_timer = false
            -- 缩小完成后移除定时器
            if zoom_state == ZoomState.ZoomingOut then
                log("已缩小")
                zoom_state = ZoomState.None
                should_stop_timer = true
            elseif zoom_state == ZoomState.ZoomingIn then
                log("已放大")
                zoom_state = ZoomState.ZoomedIn
                -- 放大完成后若未追踪鼠标也移除定时器
                should_stop_timer = (not use_auto_follow_mouse) and (not is_following_mouse)

                if use_auto_follow_mouse then
                    is_following_mouse = true
                    log("鼠标追踪已" .. (is_following_mouse and "开启" or "关闭") .. "（因自动跟随）")
                end

                -- 将当前位置设为跟随安全区的中心
                if is_following_mouse and follow_border < 50 then
                    zoom_target = get_target_position(zoom_info)
                    locked_center = { x = zoom_target.clamped_center.x, y = zoom_target.clamped_center.y }
                    log("光标停止。追踪锁定至 " .. locked_center.x .. ", " .. locked_center.y)
                end
            end

            if should_stop_timer then
                is_timer_running = false
                obs.timer_remove(on_timer)
            end
        end
    end
end

function on_socket_timer()
    if not socket_server then
        return
    end

    repeat
        local data, status = socket_server:receive_from()
        if data then
            local sx, sy = data:match("(-?%d+) (-?%d+)")
            if sx and sy then
                local x = tonumber(sx, 10)
                local y = tonumber(sy, 10)
                if not socket_mouse then
                    log("套接字服务器客户端已连接")
                    socket_mouse = { x = x, y = y }
                else
                    socket_mouse.x = x
                    socket_mouse.y = y
                end
            end
        elseif status ~= "timeout" then
            error(status)
        end
    until data == nil
end

function start_server()
    if socket_available then
        local address = socket.find_first_address("*", socket_port)

        socket_server = socket.create("inet", "dgram", "udp")
        if socket_server ~= nil then
            socket_server:set_option("reuseaddr", 1)
            socket_server:set_blocking(false)
            socket_server:bind(address, socket_port)
            obs.timer_add(on_socket_timer, socket_poll)
            log("套接字服务器正在监听端口 " .. socket_port .. "...")
        end
    end
end

function stop_server()
    if socket_server ~= nil then
        log("套接字服务器已停止")
        obs.timer_remove(on_socket_timer)
        socket_server:close()
        socket_server = nil
        socket_mouse = nil
    end
end

function set_crop_settings(crop)
    if crop_filter ~= nil and crop_filter_settings ~= nil then
        -- 调用 OBS 更新裁剪滤镜设置
        -- 不确定这个操作的性能开销，可以只在有变化时执行
        obs.obs_data_set_int(crop_filter_settings, "left", math.floor(crop.x))
        obs.obs_data_set_int(crop_filter_settings, "top", math.floor(crop.y))
        obs.obs_data_set_int(crop_filter_settings, "cx", math.floor(crop.w))
        obs.obs_data_set_int(crop_filter_settings, "cy", math.floor(crop.h))
        obs.obs_source_update(crop_filter, crop_filter_settings)
    end
end

function on_transition_start(t)
    log("转场开始")
    -- 我们需要在转场开始时移除裁剪，以避免渲染延迟导致旧裁剪跳到新裁剪
    release_sceneitem()
end

function on_frontend_event(event)
    if event == obs.OBS_FRONTEND_EVENT_SCENE_CHANGED then
        log("OBS 场景已切换")
        -- 如果场景改变，尝试在新场景中查找同名的源
        -- TODO: 可能需要让用户指定在每个场景中使用哪个源
        -- 场景切换可能在 OBS 完全加载前发生，因此需要检查
        if is_obs_loaded then
            refresh_sceneitem(true)
        end
    elseif event == obs.OBS_FRONTEND_EVENT_FINISHED_LOADING then
        log("OBS 加载完成")
        -- 加载完成后执行初始查找
        is_obs_loaded = true
        monitor_info = get_monitor_info(source)
        refresh_sceneitem(true)
    elseif event == obs.OBS_FRONTEND_EVENT_SCRIPTING_SHUTDOWN then
        log("OBS 正在关闭")
        -- 添加关闭时的卸载防护
        if is_script_loaded then
            script_unload()
        end
    end
end

function on_update_transform()
    -- 根据当前场景中源的状态更新裁剪/尺寸设置
    if is_obs_loaded then
        refresh_sceneitem(true)
    end

    return true
end

function on_settings_modified(props, prop, settings)
    local name = obs.obs_property_name(prop)

    -- 根据复选框状态显示/隐藏设置
    if name == "use_monitor_override" then
        local visible = obs.obs_data_get_bool(settings, "use_monitor_override")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_x"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_y"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_w"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_h"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sx"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_sy"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dw"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "monitor_override_dh"), visible)
        return true
    elseif name == "use_socket" then
        local visible = obs.obs_data_get_bool(settings, "use_socket")
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_label"), not visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_port"), visible)
        obs.obs_property_set_visible(obs.obs_properties_get(props, "socket_poll"), visible)
        return true
    elseif name == "allow_all_sources" then
        local sources_list = obs.obs_properties_get(props, "source")
        populate_zoom_sources(sources_list)
        return true
    elseif name == "debug_logs" then
        if obs.obs_data_get_bool(settings, "debug_logs") then
            log_current_settings()
        end
    end

    return false
end

---
-- 将当前设置写入日志，用于调试和问题报告
function log_current_settings()
    local settings = {
        zoom_value = zoom_value,
        zoom_speed = zoom_speed,
        use_auto_follow_mouse = use_auto_follow_mouse,
        use_follow_outside_bounds = use_follow_outside_bounds,
        follow_speed = follow_speed,
        follow_border = follow_border,
        follow_safezone_sensitivity = follow_safezone_sensitivity,
        use_follow_auto_lock = use_follow_auto_lock,
        use_monitor_override = use_monitor_override,
        monitor_override_x = monitor_override_x,
        monitor_override_y = monitor_override_y,
        monitor_override_w = monitor_override_w,
        monitor_override_h = monitor_override_h,
        monitor_override_sx = monitor_override_sx,
        monitor_override_sy = monitor_override_sy,
        monitor_override_dw = monitor_override_dw,
        monitor_override_dh = monitor_override_dh,
        use_socket = use_socket,
        socket_port = socket_port,
        socket_poll = socket_poll,
        debug_logs = debug_logs,
        version = VERSION
    }

    log("OBS 版本：" .. string.format("%.1f", major) .. "." .. minor)
    log("平台：" .. ffi.os)
    log("当前设置：")
    log(format_table(settings))
end

function on_print_help()
    local help = "\n----------------------------------------------------\n" ..
        "OBS-Zoom-To-Mouse v" .. VERSION .. " 帮助信息\n" ..
        "https://github.com/BlankSourceCode/obs-zoom-to-mouse\n" ..
        "----------------------------------------------------\n" ..
        "此脚本用于将选中的显示器采集源放大到鼠标位置\n\n" ..
        "缩放源：当前场景中用于缩放的显示器采集源\n" ..
        "缩放倍数：放大倍数\n" ..
        "缩放速度：放大/缩小动画的速度\n" ..
        "自动跟随鼠标：开启后在放大状态下自动追踪鼠标\n" ..
        "越界跟随：开启后即使鼠标超出源边界也会继续追踪\n" ..
        "跟随速度：缩放区域跟随鼠标移动的速度\n" ..
        "跟随边界：从源边缘开始的百分比距离，到达此区域时将重新启用鼠标追踪\n" ..
        "锁定灵敏度：追踪锁定位置的精度阈值，锁定后将停止追踪，直到鼠标再次进入跟随边界\n" ..
        "反向自动锁定：鼠标反向移动时自动停止追踪\n" ..
        "显示所有源：开启后允许选择任意源作为缩放源 — 非显示器采集源必须手动设置源位置\n" ..
        "手动设置源位置：开启后覆盖计算出的 x/y（左上角位置）、宽/高（尺寸）和 scaleX/scaleY（画布缩放比例）值\n" ..
        "X：源最左侧像素的坐标\n" ..
        "Y：源最顶部像素的坐标\n" ..
        "宽度：源的宽度（像素）\n" ..
        "高度：源的高度（像素）\n" ..
        "缩放 X：如果源尺寸不是 1:1 时应用于鼠标位置的 X 轴缩放因子（对于克隆源有用）\n" ..
        "缩放 Y：如果源尺寸不是 1:1 时应用于鼠标位置的 Y 轴缩放因子（对于克隆源有用）\n" ..
        "显示器宽度：显示该源的显示器的宽度（像素）\n" ..
        "显示器高度：显示该源的显示器的高度（像素）\n"

    if socket_available then
        help = help ..
            "启用远程鼠标监听：开启后启动 UDP 套接字服务器，监听来自远程客户端的鼠标位置消息，参见：https://github.com/BlankSourceCode/obs-zoom-to-mouse-remote\n" ..
            "端口：套接字服务器使用的端口号\n" ..
            "轮询延迟：更新鼠标位置的时间间隔（毫秒）\n"
    end

    help = help ..
        "更多信息：在脚本日志中显示此文本\n" ..
        "启用调试日志：在脚本日志中显示额外的调试信息\n\n"

    obs.script_log(obs.OBS_LOG_INFO, help)
end

function script_description()
    return "将选中的显示器采集源放大到鼠标位置"
end

function script_properties()
    local props = obs.obs_properties_create()

    -- 填充已知的显示器采集源列表（OBS 内部称为 'monitor_capture'，尽管 UI 中显示为"显示器采集"）
    local sources_list = obs.obs_properties_add_list(props, "source", "缩放源", obs.OBS_COMBO_TYPE_LIST,
        obs.OBS_COMBO_FORMAT_STRING)

    populate_zoom_sources(sources_list)

    local refresh_sources = obs.obs_properties_add_button(props, "refresh", "刷新缩放源列表",
        function()
            populate_zoom_sources(sources_list)
            monitor_info = get_monitor_info(source)
            return true
        end)
    obs.obs_property_set_long_description(refresh_sources,
        "点击重新填充缩放源下拉列表")

    -- 添加其余设置界面
    local zoom = obs.obs_properties_add_float(props, "zoom_value", "缩放倍数", 1, 5, 0.5)
    local zoom_speed = obs.obs_properties_add_float_slider(props, "zoom_speed", "缩放速度", 0.01, 1, 0.01)
    local follow = obs.obs_properties_add_bool(props, "follow", "自动跟随鼠标")
    obs.obs_property_set_long_description(follow,
        "开启后，放大状态下鼠标追踪将自动启动，无需等待按下追踪切换快捷键")

    local follow_outside_bounds = obs.obs_properties_add_bool(props, "follow_outside_bounds", "越界跟随")
    obs.obs_property_set_long_description(follow_outside_bounds,
        "开启后，即使鼠标超出缩放源边界也会继续追踪")

    local follow_speed = obs.obs_properties_add_float_slider(props, "follow_speed", "跟随速度", 0.01, 1, 0.01)
    local follow_border = obs.obs_properties_add_int_slider(props, "follow_border", "跟随边界", 0, 50, 1)
    local safezone_sense = obs.obs_properties_add_int_slider(props,
        "follow_safezone_sensitivity", "锁定灵敏度", 1, 20, 1)
    local follow_auto_lock = obs.obs_properties_add_bool(props, "follow_auto_lock", "反向自动锁定")
    obs.obs_property_set_long_description(follow_auto_lock,
        "开启后，鼠标移动到缩放源边缘将开始追踪，\n" ..
        "但移回中心时将停止追踪，类似 RTS 游戏中的镜头平移")

    local allow_all = obs.obs_properties_add_bool(props, "allow_all_sources", "允许任何缩放源")
    obs.obs_property_set_long_description(allow_all, "开启后允许选择任意源作为缩放源\n" ..
        "非显示器采集源必须手动设置源位置")

    local override_props = obs.obs_properties_create();
    local override_label = obs.obs_properties_add_text(override_props, "monitor_override_label", "", obs.OBS_TEXT_INFO)
    local override_x = obs.obs_properties_add_int(override_props, "monitor_override_x", "X", -10000, 10000, 1)
    local override_y = obs.obs_properties_add_int(override_props, "monitor_override_y", "Y", -10000, 10000, 1)
    local override_w = obs.obs_properties_add_int(override_props, "monitor_override_w", "宽度", 0, 10000, 1)
    local override_h = obs.obs_properties_add_int(override_props, "monitor_override_h", "高度", 0, 10000, 1)
    local override_sx = obs.obs_properties_add_float(override_props, "monitor_override_sx", "缩放 X", 0, 100, 0.01)
    local override_sy = obs.obs_properties_add_float(override_props, "monitor_override_sy", "缩放 Y", 0, 100, 0.01)
    local override_dw = obs.obs_properties_add_int(override_props, "monitor_override_dw", "显示器宽度", 0, 10000, 1)
    local override_dh = obs.obs_properties_add_int(override_props, "monitor_override_dh", "显示器高度", 0, 10000, 1)
    local override = obs.obs_properties_add_group(props, "use_monitor_override", "手动设置源位置",
        obs.OBS_GROUP_CHECKABLE, override_props)

    obs.obs_property_set_long_description(override_label,
        "开启后，将使用指定的尺寸/位置设置替代自动计算的值")
    obs.obs_property_set_long_description(override_sx, "通常为 1，除非你使用了缩放源")
    obs.obs_property_set_long_description(override_sy, "通常为 1，除非你使用了缩放源")
    obs.obs_property_set_long_description(override_dw, "显示器的 X 分辨率")
    obs.obs_property_set_long_description(override_dh, "显示器的 Y 分辨率")

    if socket_available then
        local socket_props = obs.obs_properties_create();
        local r_label = obs.obs_properties_add_text(socket_props, "socket_label", "", obs.OBS_TEXT_INFO)
        local r_port = obs.obs_properties_add_int(socket_props, "socket_port", "端口", 1024, 65535, 1)
        local r_poll = obs.obs_properties_add_int(socket_props, "socket_poll", "轮询延迟(毫秒)", 0, 1000, 1)
        local socket = obs.obs_properties_add_group(props, "use_socket", "启用远程鼠标监听",
            obs.OBS_GROUP_CHECKABLE, socket_props)

        obs.obs_property_set_long_description(r_label,
            "开启后，UDP 套接字服务器将监听来自远程客户端的鼠标位置消息")
        obs.obs_property_set_long_description(r_port,
            "更改端口后必须重启服务器（取消再重新勾选「启用远程鼠标监听」）")
        obs.obs_property_set_long_description(r_poll,
            "更改轮询延迟后必须重启服务器（取消再重新勾选「启用远程鼠标监听」）")

        obs.obs_property_set_visible(r_label, not use_socket)
        obs.obs_property_set_visible(r_port, use_socket)
        obs.obs_property_set_visible(r_poll, use_socket)
        obs.obs_property_set_modified_callback(socket, on_settings_modified)
    end

    -- 添加"更多信息"按钮
    local help = obs.obs_properties_add_button(props, "help_button", "更多信息", on_print_help)
    obs.obs_property_set_long_description(help,
        "点击显示帮助信息（通过脚本日志输出）")

    local debug = obs.obs_properties_add_bool(props, "debug_logs", "启用调试日志")
    obs.obs_property_set_long_description(debug,
        "开启后，脚本将输出诊断信息到脚本日志（用于调试/报告问题）")

    obs.obs_property_set_visible(override_label, not use_monitor_override)
    obs.obs_property_set_visible(override_x, use_monitor_override)
    obs.obs_property_set_visible(override_y, use_monitor_override)
    obs.obs_property_set_visible(override_w, use_monitor_override)
    obs.obs_property_set_visible(override_h, use_monitor_override)
    obs.obs_property_set_visible(override_sx, use_monitor_override)
    obs.obs_property_set_visible(override_sy, use_monitor_override)
    obs.obs_property_set_visible(override_dw, use_monitor_override)
    obs.obs_property_set_visible(override_dh, use_monitor_override)
    obs.obs_property_set_modified_callback(override, on_settings_modified)

    obs.obs_property_set_modified_callback(allow_all, on_settings_modified)
    obs.obs_property_set_modified_callback(debug, on_settings_modified)

    return props
end

function script_load(settings)
    sceneitem_info_orig = nil

    -- 检测 OBS 是否已加载（以支持"重新加载脚本"功能）
    local current_scene = obs.obs_frontend_get_current_scene()
    is_obs_loaded = current_scene ~= nil -- 首次加载时当前场景为 nil
    obs.obs_source_release(current_scene)

    -- 注册我们的快捷键
    hotkey_zoom_id = obs.obs_hotkey_register_frontend("toggle_zoom_hotkey", "切换缩放至鼠标",
        on_toggle_zoom)

    hotkey_follow_id = obs.obs_hotkey_register_frontend("toggle_follow_hotkey", "切换鼠标跟随",
        on_toggle_follow)

    -- 尝试重新加载已有的快捷键绑定
    local hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.zoom")
    obs.obs_hotkey_load(hotkey_zoom_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    hotkey_save_array = obs.obs_data_get_array(settings, "obs_zoom_to_mouse.hotkey.follow")
    obs.obs_hotkey_load(hotkey_follow_id, hotkey_save_array)
    obs.obs_data_array_release(hotkey_save_array)

    -- 加载其他设置
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    obs.obs_frontend_add_event_callback(on_frontend_event)

    if debug_logs then
        log_current_settings()
    end

    -- 为每个转场添加 transition_start 事件处理器（全局 source_transition_start 事件不会触发）
    local transitions = obs.obs_frontend_get_transitions()
    if transitions ~= nil then
        for i, s in pairs(transitions) do
            local name = obs.obs_source_get_name(s)
            log("正在为 " .. name .. " 添加 transition_start 监听器")
            local handler = obs.obs_source_get_signal_handler(s)
            obs.signal_handler_connect(handler, "transition_start", on_transition_start)
        end
        obs.source_list_release(transitions)
    end

    if ffi.os == "Linux" and not x11_display then
        log("错误：无法获取 Linux 的 X11 Display\n" ..
            "鼠标位置将不正确。")
    end

    source_name = ""
    use_socket = false
    is_script_loaded = true
end

function script_unload()
    is_script_loaded = false

    -- 清理内存使用
    if major > 29.1 or (major == 29.1 and minor > 2) then -- 29.1.2 及以下版本执行此操作会导致崩溃，脚本关闭时忽略
        local transitions = obs.obs_frontend_get_transitions()
        if transitions ~= nil then
            for i, s in pairs(transitions) do
                local handler = obs.obs_source_get_signal_handler(s)
                obs.signal_handler_disconnect(handler, "transition_start", on_transition_start)
            end
            obs.source_list_release(transitions)
        end

        obs.obs_hotkey_unregister(on_toggle_zoom)
        obs.obs_hotkey_unregister(on_toggle_follow)
        obs.obs_frontend_remove_event_callback(on_frontend_event)
        release_sceneitem()
    end

    if x11_lib ~= nil and x11_display ~= nil then
        x11_lib.XCloseDisplay(x11_display)
        x11_display = nil
        x11_lib = nil
    end

    if socket_server ~= nil then
        stop_server()
    end
end

function script_defaults(settings)
    -- 脚本默认值
    obs.obs_data_set_default_double(settings, "zoom_value", 2)
    obs.obs_data_set_default_double(settings, "zoom_speed", 0.06)
    obs.obs_data_set_default_bool(settings, "follow", true)
    obs.obs_data_set_default_bool(settings, "follow_outside_bounds", false)
    obs.obs_data_set_default_double(settings, "follow_speed", 0.25)
    obs.obs_data_set_default_int(settings, "follow_border", 8)
    obs.obs_data_set_default_int(settings, "follow_safezone_sensitivity", 4)
    obs.obs_data_set_default_bool(settings, "follow_auto_lock", false)
    obs.obs_data_set_default_bool(settings, "allow_all_sources", false)
    obs.obs_data_set_default_bool(settings, "use_monitor_override", false)
    obs.obs_data_set_default_int(settings, "monitor_override_x", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_y", 0)
    obs.obs_data_set_default_int(settings, "monitor_override_w", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_h", 1080)
    obs.obs_data_set_default_double(settings, "monitor_override_sx", 1)
    obs.obs_data_set_default_double(settings, "monitor_override_sy", 1)
    obs.obs_data_set_default_int(settings, "monitor_override_dw", 1920)
    obs.obs_data_set_default_int(settings, "monitor_override_dh", 1080)
    obs.obs_data_set_default_bool(settings, "use_socket", false)
    obs.obs_data_set_default_int(settings, "socket_port", 12345)
    obs.obs_data_set_default_int(settings, "socket_poll", 10)
    obs.obs_data_set_default_bool(settings, "debug_logs", false)
end

function script_save(settings)
    -- 保存自定义快捷键信息
    if hotkey_zoom_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_zoom_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.zoom", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end

    if hotkey_follow_id ~= nil then
        local hotkey_save_array = obs.obs_hotkey_save(hotkey_follow_id)
        obs.obs_data_set_array(settings, "obs_zoom_to_mouse.hotkey.follow", hotkey_save_array)
        obs.obs_data_array_release(hotkey_save_array)
    end
end

function script_update(settings)
    local old_source_name = source_name
    local old_override = use_monitor_override
    local old_x = monitor_override_x
    local old_y = monitor_override_y
    local old_w = monitor_override_w
    local old_h = monitor_override_h
    local old_sx = monitor_override_sx
    local old_sy = monitor_override_sy
    local old_dw = monitor_override_dw
    local old_dh = monitor_override_dh
    local old_socket = use_socket
    local old_port = socket_port
    local old_poll = socket_poll

    -- 更新设置
    source_name = obs.obs_data_get_string(settings, "source")
    zoom_value = obs.obs_data_get_double(settings, "zoom_value")
    zoom_speed = obs.obs_data_get_double(settings, "zoom_speed")
    use_auto_follow_mouse = obs.obs_data_get_bool(settings, "follow")
    use_follow_outside_bounds = obs.obs_data_get_bool(settings, "follow_outside_bounds")
    follow_speed = obs.obs_data_get_double(settings, "follow_speed")
    follow_border = obs.obs_data_get_int(settings, "follow_border")
    follow_safezone_sensitivity = obs.obs_data_get_int(settings, "follow_safezone_sensitivity")
    use_follow_auto_lock = obs.obs_data_get_bool(settings, "follow_auto_lock")
    allow_all_sources = obs.obs_data_get_bool(settings, "allow_all_sources")
    use_monitor_override = obs.obs_data_get_bool(settings, "use_monitor_override")
    monitor_override_x = obs.obs_data_get_int(settings, "monitor_override_x")
    monitor_override_y = obs.obs_data_get_int(settings, "monitor_override_y")
    monitor_override_w = obs.obs_data_get_int(settings, "monitor_override_w")
    monitor_override_h = obs.obs_data_get_int(settings, "monitor_override_h")
    monitor_override_sx = obs.obs_data_get_double(settings, "monitor_override_sx")
    monitor_override_sy = obs.obs_data_get_double(settings, "monitor_override_sy")
    monitor_override_dw = obs.obs_data_get_int(settings, "monitor_override_dw")
    monitor_override_dh = obs.obs_data_get_int(settings, "monitor_override_dh")
    use_socket = obs.obs_data_get_bool(settings, "use_socket")
    socket_port = obs.obs_data_get_int(settings, "socket_port")
    socket_poll = obs.obs_data_get_int(settings, "socket_poll")
    debug_logs = obs.obs_data_get_bool(settings, "debug_logs")

    -- 仅在用户选择了新源时才执行开销较大的刷新
    if source_name ~= old_source_name and is_obs_loaded then
        refresh_sceneitem(true)
    end

    -- 如果设置发生改变，更新 monitor_info
    if source_name ~= old_source_name or
        use_monitor_override ~= old_override or
        monitor_override_x ~= old_x or
        monitor_override_y ~= old_y or
        monitor_override_w ~= old_w or
        monitor_override_h ~= old_h or
        monitor_override_sx ~= old_sx or
        monitor_override_sy ~= old_sy or
        monitor_override_w ~= old_dw or
        monitor_override_h ~= old_dh then
        if is_obs_loaded then
            monitor_info = get_monitor_info(source)
        end
    end

    if old_socket ~= use_socket then
        if use_socket then
            start_server()
        else
            stop_server()
        end
    elseif use_socket and (old_poll ~= socket_poll or old_port ~= socket_port) then
        stop_server()
        start_server()
    end
end

function populate_zoom_sources(list)
    obs.obs_property_list_clear(list)

    local sources = obs.obs_enum_sources()
    if sources ~= nil then
        local dc_info = get_dc_info()
        obs.obs_property_list_add_string(list, "<无>", "obs-zoom-to-mouse-none")
        for _, source in ipairs(sources) do
            local source_type = obs.obs_source_get_id(source)
            if source_type == dc_info.source_id or allow_all_sources then
                local name = obs.obs_source_get_name(source)
                obs.obs_property_list_add_string(list, name, name)
            end
        end

        obs.source_list_release(sources)
    end
end
