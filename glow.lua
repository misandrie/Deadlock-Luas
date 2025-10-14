-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

local glow_tab = NEW_UI_LIB.create_tab(false, Menu.Find("Visuals", "", "Visuals"), "Self", "Glow")
local color_tab = NEW_UI_LIB.create_tab(false, Menu.Find("Visuals", "", "Visuals"), "Self", "Glow Color")
local transparency_tab = NEW_UI_LIB.create_tab(false, Menu.Find("Visuals", "", "Visuals"), "Self", "Transparency")

local ui = {}

ui.enable = glow_tab:switch("Enable", false, "\u{f06e}")
-- ui.debug = glow_tab:switch("Debug", false, "\u{f188}")

ui.rgb_mode = color_tab:switch("RGB Mode", false, "\u{f0c8}")
ui.rgb_speed = color_tab:slider("RGB Speed", 0.01, 100, 11, "%.2f")

local glow_color_picker = nil
pcall(function()
    local vis = Menu.Find("Visuals", "", "Visuals")
    local selftab = vis:Find("Self")
    local color_group = selftab:Find("Glow Color")
    
    if color_group then
        glow_color_picker = color_group:ColorPicker("Glow Color", Color(0, 255, 0, 255), "\u{f111}")
    end
end)

ui.transparency = transparency_tab:switch("Enable Transparency", false, "\u{f21b}")
ui.alpha = transparency_tab:slider("Alpha", 0, 255, 128, "%d")

local debug_info = {
    local_valid = false,
    current_hue = 0,
    alpha_property_exists = false
}

local function update_glow()
    if not ui.enable() then
        return
    end
    
    local local_pawn = entity_list.local_pawn()
    if not local_pawn or not local_pawn:valid() then
        debug_info.local_valid = false
        return
    end

    debug_info.local_valid = true

    local glow_color
    
    if ui.rgb_mode() then
        debug_info.current_hue = debug_info.current_hue + (ui.rgb_speed() * 0.1)
        if debug_info.current_hue >= 360 then
            debug_info.current_hue = 0
        end
        
        local color = Color(255, 255, 255, 255)
        color:AsHsv(debug_info.current_hue / 360, 1.0, 1.0, 1.0)
        glow_color = color
    else
        glow_color = glow_color_picker:Get()
    end
    
    local_pawn.m_Glow.m_glowColorOverride = glow_color
    local_pawn.m_Glow.m_bGlowing = true
    local_pawn.m_Glow.m_iGlowType = 3
    
    if ui.transparency() then
        local alpha_prop = local_pawn.m_pClientAlphaProperty
        
        if alpha_prop then
            debug_info.alpha_property_exists = true
            
            alpha_prop.m_nAlpha = ui.alpha()
            alpha_prop.m_nRenderMode = 2
            alpha_prop.m_bAlphaOverride = true
        else
            debug_info.alpha_property_exists = false
        end
    else
        local alpha_prop = local_pawn.m_pClientAlphaProperty
        
        if alpha_prop then
            alpha_prop.m_nAlpha = 255
            alpha_prop.m_nRenderMode = 0
            alpha_prop.m_bAlphaOverride = false
        end
    end
end

local function clear_glow()
    local local_pawn = entity_list.local_pawn()
    if local_pawn and local_pawn:valid() then
        local_pawn.m_Glow.m_bGlowing = false
        
        local alpha_prop = local_pawn.m_pClientAlphaProperty
        if alpha_prop then
            alpha_prop.m_nAlpha = 255
            alpha_prop.m_nRenderMode = 0
            alpha_prop.m_bAlphaOverride = false
        end
    end
end

local function draw_debug()
    if not ui.debug() then
        return
    end

    local x, y = 20, 200
    local line_height = 20
    
    local font = Render.LoadFont("Verdana", Enum.FontCreate.FONTFLAG_OUTLINE, Enum.FontWeight.BOLD)
    local font_size = 14
    
    Render.FilledRect(Vec2(x - 10, y - 10), Vec2(x + 290, y + 140), Color(0, 0, 0, 180), 4)
    
    Render.Text(font, font_size, "=== Glow ESP Debug ===", Vec2(x, y), Color(255, 200, 0, 255))
    y = y + line_height + 5
    
    local status = ui.enable() and "Enabled" or "Disabled"
    local status_color = ui.enable() and Color(0, 255, 0, 255) or Color(255, 0, 0, 255)
    Render.Text(font, font_size, "Status: " .. status, Vec2(x, y), status_color)
    y = y + line_height
    
    local mode = ui.rgb_mode() and "RGB Mode" or "Color Picker"
    Render.Text(font, font_size, "Mode: " .. mode, Vec2(x, y), Color(255, 255, 255, 255))
    y = y + line_height
    
    local valid_text = debug_info.local_valid and "Yes" or "No"
    local valid_color = debug_info.local_valid and Color(0, 255, 0, 255) or Color(255, 0, 0, 255)
    Render.Text(font, font_size, "Local Valid: " .. valid_text, Vec2(x, y), valid_color)
    y = y + line_height
    
    if ui.rgb_mode() then
        Render.Text(font, font_size, "Current Hue: " .. string.format("%.1f", debug_info.current_hue), Vec2(x, y), Color(255, 255, 255, 255))
        y = y + line_height
    end
    
    if ui.transparency() then
        Render.Text(font, font_size, "Alpha: " .. tostring(ui.alpha()), Vec2(x, y), Color(255, 255, 255, 255))
        y = y + line_height
        
        local alpha_exists = debug_info.alpha_property_exists and "Yes" or "No"
        local alpha_color = debug_info.alpha_property_exists and Color(0, 255, 0, 255) or Color(255, 0, 0, 255)
        Render.Text(font, font_size, "AlphaProp: " .. alpha_exists, Vec2(x, y), alpha_color)
    end
end

callback.on_frame:set(function()
    if not ui.enable() then
        clear_glow()
        return
    end
    
    update_glow()
end)

--callback.on_draw:set(function()
--    draw_debug()
--end)
