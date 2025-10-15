-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

local doorman_entry = Menu.Create("Heroes", "Hero List", "Doorman")
local doorman_belltab = doorman_entry:Create("Bell")
local doorman_carttab = doorman_entry:Create("Cart") -- Unused.
local bell_master = doorman_belltab:Create("Master")
local auto = doorman_belltab:Create("Auto Shoot")
local visual = doorman_belltab:Create("Visual/Debug")
local prediction = doorman_belltab:Create("Prediction")

local dumgroup = doorman_carttab:Create("Nothing here, so far!")
dumgroup:Label("")


local ui = {}

ui.enable = bell_master:Switch("Enable", false, "\u{f0f3}")
ui.auto_shoot = bell_master:Switch("Enable Auto Shoot", false, "\u{f05b}")
ui.shoot_key = bell_master:Bind("Activation Key", Enum.ButtonCode.KEY_NONE, "\u{f11c}")

ui.fov_override = bell_master:Switch("Override FOV", false, "\u{f1db}")
ui.fov_settings = ui.fov_override:Gear("FOV settings")
ui.fov_slider = ui.fov_settings:Slider("Bell PSilent FOV", 0.1, 15.0, 4)
ui.fov_draw = ui.fov_settings:Switch("Draw circle", false);

ui.aggressive_targeting = bell_master:Switch("Aggressive Targeting", false, "\u{f06d}")
ui.aggressive_targeting:ToolTip("Ignore psilent aim checks")

ui.min_enemies = bell_master:Slider("Min Enemies to Shoot", 1, 5, 1, "%d")

ui.draw_world = visual:Switch("Draw World Markers", false, "\u{f041}")
ui.draw_aoe = visual:Switch("Draw AOE Radius", false, "\u{f1db}")
ui.aoe_opacity = visual:Slider("AOE Opacity", 0, 255, 100, "%d")
ui.show_distance = visual:Switch("Show Distance", false, "\u{f124}")
ui.show_enemies = visual:Switch("Show Enemies in Range", false, "\u{f06e}")
ui.enemy_color = visual:ColorPicker("Enemy Indicator Color", Color(255, 0, 0, 255), "\u{f111}")

ui.enable_prediction = prediction:Switch("Enable Trajectory Prediction", true, "\u{f1e0}")
ui.enable_prediction:ToolTip("Shoots ahead of time predicting there will be enemies in range.")
ui.prediction_time = prediction:Slider("Prediction Time (seconds)", 0.1, 0.4, 1.0, "%.1f")
ui.draw_prediction = prediction:Switch("Draw Predicted Path", true, "\u{f1ec}")
ui.draw_future_aoe = prediction:Switch("Draw Future AOE", true, "\u{f140}")

local doorman_bells = {}
local last_scan = 0
local scan_interval = 0.1
local doorman_ability_radius = nil
local doorman_ability_level = nil
local bells_in_fov = {}
local last_shot_time = 0
local shot_cooldown = 0.05

local legitbot_fov = nil
local function get_legitbot_fov()
    if not legitbot_fov then
        local success = pcall(function()
            legitbot_fov = Menu.Find("Legitbot", "", "Legitbot", "Main", "General", "PSilent FOV")
        end)
        if not success then
            return 2
        end
    end
    return legitbot_fov and legitbot_fov:Get() or 2
end

local function update_doorman_ability_radius()
    local local_pawn = entity_list.local_pawn()
    if not local_pawn or not local_pawn:valid() then
        return
    end
    
    local first_ability = local_pawn:get_ability_by_slot(EAbilitySlots_t.ESlot_Signature_1)
    if first_ability then
        local radius = first_ability:get_aoe_radius()
        local level = first_ability:get_level()
        if radius and radius > 0 then
            doorman_ability_radius = radius
            doorman_ability_level = level
            return
        end
    end
end

local function predict_bell_position(bell_info, time_delta)
    if not bell_info.last_position or not bell_info.last_update_time then
        return bell_info.position, Vector(0, 0, 0), false
    end
    
    local current_time = global_vars.curtime()
    local dt = current_time - bell_info.last_update_time
    
    if dt <= 0 or dt > 1.0 then
        return bell_info.position, Vector(0, 0, 0), false
    end
    
    local velocity = Vector(
        (bell_info.position.x - bell_info.last_position.x) / dt,
        (bell_info.position.y - bell_info.last_position.y) / dt,
        (bell_info.position.z - bell_info.last_position.z) / dt
    )
    
    local speed = velocity:Length()
    if speed < 1.0 then
        return bell_info.position, velocity, false
    end
    
    local predicted_pos = Vector(
        bell_info.position.x + velocity.x * time_delta,
        bell_info.position.y + velocity.y * time_delta,
        bell_info.position.z + velocity.z * time_delta
    )
    
    return predicted_pos, velocity, true
end

local function get_enemies_in_range(position, radius)
    if not position or not radius then
        return {}
    end
    
    local local_pawn = entity_list.local_pawn()
    if not local_pawn or not local_pawn:valid() then
        return {}
    end
    
    local local_team = local_pawn.m_iTeamNum
    local enemies_in_range = {}
    local all_players = entity_list.by_class_name("C_CitadelPlayerPawn")
    
    for _, player in ipairs(all_players) do
        if player:valid() and player ~= local_pawn and player:is_alive() then
            if player.m_iTeamNum ~= local_team then
                local distance = position:Distance(player:get_origin())
                if distance <= radius then
                    table.insert(enemies_in_range, {
                        entity = player,
                        distance = distance,
                        name = player:get_name()
                    })
                end
            end
        end
    end
    
    table.sort(enemies_in_range, function(a, b) return a.distance < b.distance end)
    return enemies_in_range
end

local function will_have_enemies_in_future(bell_info, prediction_time)
    if not ui.enable_prediction:Get() or not doorman_ability_radius then
        return false, bell_info.position, {}
    end
    
    local predicted_pos, velocity, is_moving = predict_bell_position(bell_info, prediction_time)
    if not is_moving then
        return false, bell_info.position, {}
    end
    
    local future_enemies = get_enemies_in_range(predicted_pos, doorman_ability_radius)
    return #future_enemies >= ui.min_enemies:Get(), predicted_pos, future_enemies
end

local function get_bells_in_fov(fov_limit)
    local shootable_bells = {}
    local camera_pos = utils.get_camera_pos()
    local camera_angles = utils.get_camera_angles()
    
    if not camera_pos or not camera_angles then
        return shootable_bells
    end
    
    for _, bell_info in ipairs(doorman_bells) do
        if bell_info.entity:valid() then
            local enemy_count = #bell_info.enemies
            local aim_angle = utils.calc_angle(camera_pos, bell_info.position)
            local fov = utils.get_fov(camera_angles, aim_angle)
            
            local local_pawn = entity_list.local_pawn()
            local distance_to_player = local_pawn and local_pawn:valid() and 
                local_pawn:get_origin():Distance(bell_info.position) or 0
            
            local will_have_enemies, predicted_pos, future_enemies = 
                will_have_enemies_in_future(bell_info, ui.prediction_time:Get())
            
            bell_info.predicted_position = predicted_pos
            bell_info.future_enemies = future_enemies
            bell_info.will_have_enemies = will_have_enemies
            
            local is_shootable = (enemy_count >= ui.min_enemies:Get() or will_have_enemies) and 
                fov <= fov_limit
            
            if is_shootable then
                table.insert(shootable_bells, {
                    bell = bell_info,
                    fov = fov,
                    enemy_count = enemy_count,
                    future_enemy_count = #future_enemies,
                    distance_to_player = distance_to_player,
                    is_prediction_shot = will_have_enemies and enemy_count < ui.min_enemies:Get()
                })
            end
        end
    end
    
    table.sort(shootable_bells, function(a, b)
        if ui.enable_prediction:Get() then
            if a.is_prediction_shot and not b.is_prediction_shot then
                return true
            elseif not a.is_prediction_shot and b.is_prediction_shot then
                return false
            end
        end
        
        local a_total = a.enemy_count + a.future_enemy_count
        local b_total = b.enemy_count + b.future_enemy_count
        
        if a_total == b_total then
            return a.fov < b.fov
        end
        return a_total > b_total
    end)
    
    return shootable_bells
end

local function scan_for_bells()
    local temp_bells = {}
    local local_pawn = entity_list.local_pawn()
    if not local_pawn or not local_pawn:valid() then
        return
    end
    
    local all_entities = entity_list.get_all()
    local current_time = global_vars.curtime()
    
    for _, entity in ipairs(all_entities) do
        if entity:valid() and entity:get_class_name() == "CDoormanBombProjectile" then
            local entity_pos = entity:get_origin()
            local local_pos = local_pawn:get_origin()
            local distance = local_pos:Distance(entity_pos)
            
            local existing_bell = nil
            for _, existing in ipairs(doorman_bells) do
                if existing.entity == entity then
                    existing_bell = existing
                    break
                end
            end
            
            local enemies = doorman_ability_radius and 
                get_enemies_in_range(entity_pos, doorman_ability_radius) or {}
            
            if existing_bell then
                existing_bell.last_position = existing_bell.position
                existing_bell.last_update_time = existing_bell.current_update_time or current_time
                existing_bell.position = entity_pos
                existing_bell.current_update_time = current_time
                existing_bell.distance = distance
                existing_bell.enemies = enemies
                table.insert(temp_bells, existing_bell)
            else
                table.insert(temp_bells, {
                    entity = entity,
                    position = entity_pos,
                    last_position = entity_pos,
                    last_update_time = current_time,
                    current_update_time = current_time,
                    distance = distance,
                    class_name = entity:get_class_name(),
                    name = entity:get_name(),
                    spawn_time = current_time,
                    enemies = enemies
                })
            end
        end
    end
    
    table.sort(temp_bells, function(a, b) return a.distance < b.distance end)
    doorman_bells = temp_bells
end

local function draw_circle_3d(center, radius, color, segments)
    segments = segments or 32
    local points = {}
    
    for i = 0, segments do
        local angle = (i / segments) * math.pi * 2
        local x = center.x + math.cos(angle) * radius
        local y = center.y + math.sin(angle) * radius
        local point = Vector(x, y, center.z)
        
        local screen_pos, visible = Render.WorldToScreen(point)
        if visible then
            table.insert(points, screen_pos)
        end
    end
    
    if #points > 2 then
        for i = 1, #points - 1 do
            Render.Line(points[i], points[i + 1], color, 2)
        end
    end
end

local function draw_prediction_path(bell_info)
    if not ui.draw_prediction:Get() or not bell_info.last_position then
        return
    end
    
    local _, velocity, is_moving = predict_bell_position(bell_info, 0)
    if not is_moving then
        return
    end
    
    local num_points = 10
    local time_step = ui.prediction_time:Get() / num_points
    local path_points = {}
    
    for i = 0, num_points do
        local pred_pos, _, _ = predict_bell_position(bell_info, i * time_step)
        local screen_pos, visible = Render.WorldToScreen(pred_pos)
        if visible then
            table.insert(path_points, screen_pos)
        end
    end
    
    if #path_points > 1 then
        for i = 1, #path_points - 1 do
            local alpha = 255 * (i / #path_points)
            Render.Line(path_points[i], path_points[i + 1], Color(255, 255, 0, alpha), 2)
        end
    end
end

local function draw_world_markers()
    if not ui.draw_world:Get() then
        return
    end
    
    local current_time = global_vars.curtime()
    
    for _, bell_info in ipairs(doorman_bells) do
        if bell_info.entity:valid() then
            draw_prediction_path(bell_info)
            
            local screen_pos, visible = Render.WorldToScreen(bell_info.position)
            if not visible then
                goto continue
            end
            
            local enemy_count = #bell_info.enemies
            local has_min_enemies = enemy_count >= ui.min_enemies:Get()
            local will_have_enemies = bell_info.will_have_enemies or false
            
            local color = Color(255, 165, 0, 255)
            if has_min_enemies or will_have_enemies then
                color = Color(255, 255, 0, 255)
            end
            
            if ui.draw_aoe:Get() and doorman_ability_radius then
                local aoe_color = Color(255, 0, 0, ui.aoe_opacity:Get())
                if has_min_enemies or will_have_enemies then
                    aoe_color = Color(255, 255, 0, ui.aoe_opacity:Get() + 50)
                end
                draw_circle_3d(bell_info.position, doorman_ability_radius, aoe_color, 64)
            end
            
            if ui.draw_future_aoe:Get() and will_have_enemies and bell_info.predicted_position then
                local future_aoe_color = Color(255, 100, 255, ui.aoe_opacity:Get() + 40)
                draw_circle_3d(bell_info.predicted_position, doorman_ability_radius, future_aoe_color, 48)
                
                local pred_screen, pred_vis = Render.WorldToScreen(bell_info.predicted_position)
                if pred_vis then
                    Render.Line(screen_pos, pred_screen, Color(255, 100, 255, 150), 2)
                end
            end
            
            Render.FilledCircle(screen_pos, 10, color)
            Render.Circle(screen_pos, 12, Color(0, 0, 0, 255), 2)
            
            local font = Render.LoadFont("Verdana", Enum.FontCreate.FONTFLAG_OUTLINE, Enum.FontWeight.BOLD)
            local y_offset = 15
            
            if ui.show_distance:Get() then
                local distance_text = string.format("%.0fm", bell_info.distance / 100)
                local text_size = Render.TextSize(font, 12, distance_text)
                Render.Text(font, 12, distance_text, 
                    Vec2(screen_pos.x - text_size.x / 2, screen_pos.y + y_offset), 
                    Color(255, 255, 255, 255))
                y_offset = y_offset + 15
            end
            
            if ui.show_enemies:Get() and enemy_count > 0 then
                local enemy_text = string.format("%d %s", enemy_count, enemy_count == 1 and "enemy" or "enemies")
                local text_size = Render.TextSize(font, 12, enemy_text)
                Render.Text(font, 12, enemy_text, 
                    Vec2(screen_pos.x - text_size.x / 2, screen_pos.y + y_offset), 
                    has_min_enemies and Color(255, 255, 0, 255) or ui.enemy_color:Get())
                y_offset = y_offset + 15
            end
            
            if will_have_enemies and bell_info.future_enemies and #bell_info.future_enemies > 0 then
                local future_text = string.format("WILL HIT: %d", #bell_info.future_enemies)
                local text_size = Render.TextSize(font, 11, future_text)
                Render.Text(font, 11, future_text, 
                    Vec2(screen_pos.x - text_size.x / 2, screen_pos.y + y_offset), 
                    Color(255, 100, 255, 255))
            end
            
            ::continue::
        end
    end
end

local function handle_auto_shoot(cmd)
    bells_in_fov = {}
    
    if not ui.enable:Get() or not ui.auto_shoot:Get() then
        return
    end
    
    if ui.shoot_key:Get(0) ~= Enum.ButtonCode.KEY_NONE then
        if not ui.shoot_key:IsDown() then
            return
        end
    end
    
    local local_pawn = entity_list.local_pawn()
    if not local_pawn or not local_pawn:valid() then
        return
    end
    
    local fov_limit
    if ui.fov_override:Get() then
        fov_limit = ui.fov_slider:Get()
    else
        fov_limit = get_legitbot_fov()
    end
    bells_in_fov = get_bells_in_fov(fov_limit)
    
    if #bells_in_fov == 0 then
        return
    end
    
    local current_time = global_vars.curtime()
    local aggressive = ui.aggressive_targeting:Get()
    
    local best_target = bells_in_fov[1]
    if best_target then
        local target_pos = best_target.bell.position
        
        local can_shoot = aggressive or cmd:can_psilent_at_pos(target_pos)
        
        if can_shoot then
            cmd:set_psilent_at_pos(target_pos)
            
            if (current_time - last_shot_time) >= shot_cooldown then
                cmd:add_buttonstate1(InputBitMask_t.IN_ATTACK)
                last_shot_time = current_time
            end
        end
    end
end

local function draw_override_circle()
    if not ui.fov_override:Get() or not ui.fov_draw:Get() then
        return
    end

    local size = Render.ScreenSize()

    local fov = ui.fov_slider:Get()
    local radius = fov * (Render.ScreenSize().y / 90) -- scale FOV 90° to full screen height
    Render.Circle(Vec2(size.x/2, size.y/2), radius, Color(255, 203, 125), 1)
end

callback.on_received_net_message:set(function(id, msg)
    if not ui.enable:Get() then
        return
    end
    
    local success, json = pcall(function()
        return protobuf.decodeToJSONfromObject(msg)
    end)
    
    if success and json then
        if string.find(json, "upgrade") or string.find(json, "ability") then
            update_doorman_ability_radius()
        end
    end
end)

callback.on_remove_entity:set(function(entity)
    for i = #doorman_bells, 1, -1 do
        if doorman_bells[i].entity == entity then
            table.remove(doorman_bells, i)
        end
    end
end)

callback.on_createmove:set(function(cmd)
    handle_auto_shoot(cmd)
end)

callback.on_frame:set(function()
    if not ui.enable:Get() then
        doorman_bells = {}
        doorman_ability_radius = nil
        doorman_ability_level = nil
        bells_in_fov = {}
        return
    end
    
    if not doorman_ability_radius then
        update_doorman_ability_radius()
    end
    
    local current_time = global_vars.curtime()
    if current_time - last_scan >= scan_interval then
        scan_for_bells()
        last_scan = current_time
    end
end)

callback.on_draw:set(function()
    if not ui.enable:Get() then
        return
    end
    
    draw_world_markers()
    draw_override_circle()
end)