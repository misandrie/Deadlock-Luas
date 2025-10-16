-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.

local doorman_entry = Menu.Create("Heroes", "Hero List", "Doorman")
local doorman_belltab = doorman_entry:Create("Bell")
local doorman_carttab = doorman_entry:Create("Cart")
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
ui.fov_draw = ui.fov_settings:Switch("Draw circle", false)
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

local State = {
    bells_by_entity = {},
    bells_sorted = {},
    ability_radius = nil,
    ability_level = nil,
    last_scan_time = 0,
    last_shot_time = 0,
    bells_in_fov = {},
    legitbot_fov = nil,
    font = nil,
}

local Config = {
    scan_interval = 0.1,
    shot_cooldown = 0.05,
    max_dt = 1.0,
    min_velocity = 1.0,
}

local function get_local_pawn()
    local pawn = entity_list.local_pawn()
    return pawn and pawn:valid() and pawn or nil
end

local function is_doorman(pawn)
    if not pawn then return false end
    local name = pawn:get_name()
    return name and string.find(string.lower(name), "doorman") ~= nil or false
end

local function is_enabled()
    if not ui.enable:Get() then
        return false
    end

    local pawn = get_local_pawn()
    if not pawn then
        return false
    end

    if not is_doorman(pawn) then
        return false
    end

    return State.ability_radius ~= nil
end

local function get_fov_limit()
    if ui.fov_override:Get() then
        return ui.fov_slider:Get()
    end

    if not State.legitbot_fov then
        local success = pcall(function()
            State.legitbot_fov = Menu.Find("Legitbot", "", "Legitbot", "Main", "General", "PSilent FOV")
        end)
        if not success then
            return 2
        end
    end

    return State.legitbot_fov and State.legitbot_fov:Get() or 2
end

local function update_ability_radius()
    local pawn = get_local_pawn()
    if not pawn or not is_doorman(pawn) then
        return
    end

    local first_ability = pawn:get_ability_by_slot(EAbilitySlots_t.ESlot_Signature_1)
    if not first_ability then
        return
    end

    local radius = first_ability:get_aoe_radius()
    if radius and radius > 0 then
        State.ability_radius = radius
        State.ability_level = first_ability:get_level()
    end
end

local function predict_position(bell, time_delta)
    if not bell.last_position or not bell.last_update_time then
        return bell.position, Vector(0, 0, 0), false
    end

    local current_time = global_vars.curtime()
    local dt = current_time - bell.last_update_time

    if dt <= 0 or dt > Config.max_dt then
        return bell.position, Vector(0, 0, 0), false
    end

    local velocity = Vector(
        (bell.position.x - bell.last_position.x) / dt,
        (bell.position.y - bell.last_position.y) / dt,
        (bell.position.z - bell.last_position.z) / dt
    )

    local speed = velocity:Length()
    if speed < Config.min_velocity then
        return bell.position, velocity, false
    end

    local predicted_pos = Vector(
        bell.position.x + velocity.x * time_delta,
        bell.position.y + velocity.y * time_delta,
        bell.position.z + velocity.z * time_delta
    )

    return predicted_pos, velocity, true
end

local function get_enemies_in_range(position, radius)
    if not position or not radius then
        return {}
    end

    local pawn = get_local_pawn()
    if not pawn then
        return {}
    end

    local local_team = pawn.m_iTeamNum
    local enemies = {}
    local all_players = entity_list.by_class_name("C_CitadelPlayerPawn")

    for _, player in ipairs(all_players) do
        if player:valid() and player ~= pawn and player:is_alive() and player.m_iTeamNum ~= local_team then
            local distance = position:Distance(player:get_origin())
            if distance <= radius then
                table.insert(enemies, {
                    entity = player,
                    distance = distance,
                    name = player:get_name()
                })
            end
        end
    end

    table.sort(enemies, function(a, b) return a.distance < b.distance end)
    return enemies
end

local function evaluate_future_enemies(bell)
    if not ui.enable_prediction:Get() or not State.ability_radius then
        return false, bell.position, {}
    end

    local predicted_pos, _, is_moving = predict_position(bell, ui.prediction_time:Get())
    if not is_moving then
        return false, bell.position, {}
    end

    local future_enemies = get_enemies_in_range(predicted_pos, State.ability_radius)
    return #future_enemies >= ui.min_enemies:Get(), predicted_pos, future_enemies
end

local function scan_bells()
    local pawn = get_local_pawn()
    if not pawn then
        return
    end

    local new_bells = {}
    local current_time = global_vars.curtime()
    local local_pos = pawn:get_origin()

    for _, entity in ipairs(entity_list.get_all()) do
        if entity:valid() and entity:get_class_name() == "CDoormanBombProjectile" then
            local entity_pos = entity:get_origin()
            local distance = local_pos:Distance(entity_pos)

            local bell = State.bells_by_entity[entity]
            if bell then
                bell.last_position = bell.position
                bell.last_update_time = bell.current_update_time or current_time
                bell.position = entity_pos
                bell.current_update_time = current_time
                bell.distance = distance
            else
                bell = {
                    entity = entity,
                    position = entity_pos,
                    last_position = entity_pos,
                    last_update_time = current_time,
                    current_update_time = current_time,
                    distance = distance,
                    class_name = entity:get_class_name(),
                    name = entity:get_name(),
                    spawn_time = current_time,
                }
            end

            if State.ability_radius then
                bell.enemies = get_enemies_in_range(entity_pos, State.ability_radius)
            else
                bell.enemies = {}
            end

            new_bells[entity] = bell
            table.insert(State.bells_sorted, bell)
        end
    end

    State.bells_by_entity = new_bells
    table.sort(State.bells_sorted, function(a, b) return a.distance < b.distance end)
end

local function get_shootable_bells(fov_limit)
    local shootable = {}
    local pawn = get_local_pawn()
    local camera_pos = utils.get_camera_pos()
    local camera_angles = utils.get_camera_angles()

    if not camera_pos or not camera_angles or not pawn then
        return shootable
    end

    for _, bell in ipairs(State.bells_sorted) do
        if not bell.entity:valid() then
            goto skip_bell
        end

        local enemy_count = #bell.enemies
        local aim_angle = utils.calc_angle(camera_pos, bell.position)
        local fov = utils.get_fov(camera_angles, aim_angle)
        local distance_to_player = pawn:get_origin():Distance(bell.position)

        local will_have_enemies, predicted_pos, future_enemies = evaluate_future_enemies(bell)

        bell.predicted_position = predicted_pos
        bell.future_enemies = future_enemies
        bell.will_have_enemies = will_have_enemies

        local has_min_enemies = enemy_count >= ui.min_enemies:Get()
        local is_shootable = (has_min_enemies or will_have_enemies) and fov <= fov_limit

        if is_shootable then
            table.insert(shootable, {
                bell = bell,
                fov = fov,
                enemy_count = enemy_count,
                future_enemy_count = #future_enemies,
                distance_to_player = distance_to_player,
                is_prediction_shot = will_have_enemies and not has_min_enemies
            })
        end

        ::skip_bell::
    end

    table.sort(shootable, function(a, b)
        if ui.enable_prediction:Get() then
            if a.is_prediction_shot and not b.is_prediction_shot then return true end
            if not a.is_prediction_shot and b.is_prediction_shot then return false end
        end

        local a_total = a.enemy_count + a.future_enemy_count
        local b_total = b.enemy_count + b.future_enemy_count

        if a_total == b_total then
            return a.fov < b.fov
        end
        return a_total > b_total
    end)

    return shootable
end

local function draw_circle_3d(center, radius, color, segments)
    segments = segments or 32
    local points = {}

    for i = 0, segments do
        local angle = (i / segments) * math.pi * 2
        local point = Vector(
            center.x + math.cos(angle) * radius,
            center.y + math.sin(angle) * radius,
            center.z
        )

        local screen_pos, visible = Render.WorldToScreen(point)
        if visible then
            table.insert(points, screen_pos)
        end
    end

    for i = 1, #points - 1 do
        Render.Line(points[i], points[i + 1], color, 2)
    end
end

local function draw_prediction_path(bell)
    if not ui.draw_prediction:Get() or not bell.last_position then
        return
    end

    local _, _, is_moving = predict_position(bell, 0)
    if not is_moving then
        return
    end

    local num_points = 10
    local time_step = ui.prediction_time:Get() / num_points

    for i = 0, num_points - 1 do
        local pos1, _, _ = predict_position(bell, i * time_step)
        local pos2, _, _ = predict_position(bell, (i + 1) * time_step)

        local screen_pos1, visible1 = Render.WorldToScreen(pos1)
        local screen_pos2, visible2 = Render.WorldToScreen(pos2)

        if visible1 and visible2 then
            local alpha = 255 * ((i + 1) / num_points)
            Render.Line(screen_pos1, screen_pos2, Color(255, 255, 0, alpha), 2)
        end
    end
end

local function draw_bell_marker(bell, screen_pos)
    local enemy_count = #bell.enemies
    local has_min_enemies = enemy_count >= ui.min_enemies:Get()
    local will_have_enemies = bell.will_have_enemies or false

    local color = Color(255, 165, 0, 255)
    if has_min_enemies or will_have_enemies then
        color = Color(255, 255, 0, 255)
    end

    if ui.draw_aoe:Get() and State.ability_radius then
        local aoe_color = Color(255, 0, 0, ui.aoe_opacity:Get())
        if has_min_enemies or will_have_enemies then
            aoe_color = Color(255, 255, 0, ui.aoe_opacity:Get() + 50)
        end
        draw_circle_3d(bell.position, State.ability_radius, aoe_color, 64)
    end

    if ui.draw_future_aoe:Get() and will_have_enemies and bell.predicted_position then
        local future_aoe_color = Color(255, 100, 255, ui.aoe_opacity:Get() + 40)
        draw_circle_3d(bell.predicted_position, State.ability_radius, future_aoe_color, 48)

        local pred_screen, pred_vis = Render.WorldToScreen(bell.predicted_position)
        if pred_vis then
            Render.Line(screen_pos, pred_screen, Color(255, 100, 255, 150), 2)
        end
    end

    Render.FilledCircle(screen_pos, 10, color)
    Render.Circle(screen_pos, 12, Color(0, 0, 0, 255), 2)
end

local function draw_bell_text(bell, screen_pos)
    if not State.font then
        State.font = Render.LoadFont("Verdana", Enum.FontCreate.FONTFLAG_OUTLINE, Enum.FontWeight.BOLD)
    end

    local y_offset = 15
    local enemy_count = #bell.enemies
    local has_min_enemies = enemy_count >= ui.min_enemies:Get()
    local will_have_enemies = bell.will_have_enemies or false

    if ui.show_distance:Get() then
        local distance_text = string.format("%.0fm", bell.distance / 100)
        local text_size = Render.TextSize(State.font, 12, distance_text)
        Render.Text(State.font, 12, distance_text,
            Vec2(screen_pos.x - text_size.x / 2, screen_pos.y + y_offset),
            Color(255, 255, 255, 255))
        y_offset = y_offset + 15
    end

    if ui.show_enemies:Get() and enemy_count > 0 then
        local enemy_text = string.format("%d %s", enemy_count, enemy_count == 1 and "enemy" or "enemies")
        local text_size = Render.TextSize(State.font, 12, enemy_text)
        Render.Text(State.font, 12, enemy_text,
            Vec2(screen_pos.x - text_size.x / 2, screen_pos.y + y_offset),
            has_min_enemies and Color(255, 255, 0, 255) or ui.enemy_color:Get())
        y_offset = y_offset + 15
    end

    if will_have_enemies and bell.future_enemies and #bell.future_enemies > 0 then
        local future_text = string.format("WILL HIT: %d", #bell.future_enemies)
        local text_size = Render.TextSize(State.font, 11, future_text)
        Render.Text(State.font, 11, future_text,
            Vec2(screen_pos.x - text_size.x / 2, screen_pos.y + y_offset),
            Color(255, 100, 255, 255))
    end
end

local function draw_world()
    if not ui.draw_world:Get() then
        return
    end

    for _, bell in ipairs(State.bells_sorted) do
        if bell.entity:valid() then
            draw_prediction_path(bell)

            local screen_pos, visible = Render.WorldToScreen(bell.position)
            if visible then
                draw_bell_marker(bell, screen_pos)
                draw_bell_text(bell, screen_pos)
            end
        end
    end
end

local function draw_fov_circle()
    if not ui.fov_override:Get() or not ui.fov_draw:Get() then
        return
    end

    local size = Render.ScreenSize()
    local fov = ui.fov_slider:Get()
    local radius = fov * (size.y / 90)
    Render.Circle(Vec2(size.x / 2, size.y / 2), radius, Color(255, 203, 125), 1)
end

local function handle_shoot(cmd)
    State.bells_in_fov = {}

    if not is_enabled() or not ui.auto_shoot:Get() then
        return
    end

    if ui.shoot_key:Get(0) ~= Enum.ButtonCode.KEY_NONE and not ui.shoot_key:IsDown() then
        return
    end

    local pawn = get_local_pawn()
    if not pawn then
        return
    end

    local fov_limit = get_fov_limit()
    State.bells_in_fov = get_shootable_bells(fov_limit)

    if #State.bells_in_fov == 0 then
        return
    end

    local best_target = State.bells_in_fov[1]
    local target_pos = best_target.bell.position
    local aggressive = ui.aggressive_targeting:Get()

    local can_shoot = aggressive or cmd:can_psilent_at_pos(target_pos)

    if can_shoot then
        cmd:set_psilent_at_pos(target_pos)

        local current_time = global_vars.curtime()
        if (current_time - State.last_shot_time) >= Config.shot_cooldown then
            cmd:add_buttonstate1(InputBitMask_t.IN_ATTACK)
            State.last_shot_time = current_time
        end
    end
end

local function reset_state()
    State.bells_by_entity = {}
    State.bells_sorted = {}
    State.ability_radius = nil
    State.ability_level = nil
    State.bells_in_fov = {}
    State.font = nil
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
            update_ability_radius()
        end
    end
end)

callback.on_remove_entity:set(function(entity)
    if State.bells_by_entity[entity] then
        State.bells_by_entity[entity] = nil
    end
end)

callback.on_createmove:set(function(cmd)
    handle_shoot(cmd)
end)

callback.on_frame:set(function()
    if not ui.enable:Get() then
        reset_state()
        return
    end

    if not State.ability_radius then
        update_ability_radius()
    end

    if not is_doorman(get_local_pawn()) then
        reset_state()
        return
    end

    local current_time = global_vars.curtime()
    if current_time - State.last_scan_time >= Config.scan_interval then
        State.bells_sorted = {}
        scan_bells()
        State.last_scan_time = current_time
    end
end)

callback.on_draw:set(function()
    if not is_enabled() then
        return
    end

    draw_world()
    draw_fov_circle()
end)