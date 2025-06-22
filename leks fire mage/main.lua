---@type spell_queue
local spell_queue = require("common/modules/spell_queue")
---@type spell_helper
local spell_helper = require("common/utility/spell_helper")
---@type unit_helper
local unit_helper = require("common/utility/unit_helper")
---@type target_selector
local target_selector = require("common/modules/target_selector")
---@type buff_manager
local buff_manager = require("common/modules/buff_manager")
---@type control_panel_helper
local control_panel_utility = require("common/utility/control_panel_helper")
---@type key_helper
local key_helper = require("common/utility/key_helper")
---@type enums
local enums = require("common/enums")
---@type color
local color = require("common/color")
---@type spell_prediction
local spell_prediction = require("common/modules/spell_prediction")
---@type health_prediction
local health_prediction = require("common/modules/health_prediction")
---@type combat_forecast
local combat_forecast = require("common/modules/combat_forecast")
---@type vec3
local vec3 = require("common/geometry/vector_3")

local SPELL = {
    FIREBALL = 133,
    PYROBLAST = 11366,
    FLAMESTRIKE = 2120,
    FIRE_BLAST = 108853,
    COMBUSTION = 190319,
    SCORCH = 2948,
    SHIFTING_POWER = 382440,
    PHOENIX_FLAMES = 257541,
    METEOR = 153561,
    BLAZING_BARRIER = 235313,
    ARCANE_INTELLECT = 1459,
    DRAGONS_BREATH = 31661,
}

local BUFF = {
    HEATING_UP = {48107},
    HOT_STREAK = {48108},
    COMBUSTION = {190319},
    IGNITE = {12846},
    ARCANE_INTELLECT = {1459},
    HYPERTHERMIA = {383860},
    FEEL_THE_BURN = {383391},
}

local last_action_timestamp = 0
local last_dragons_breath_cast = 0
local last_aoe_switch_time = 0

local FB_MAX_CHARGES = core.spell_book.get_spell_charge_max(SPELL.FIRE_BLAST) or 2
local PF_MAX_CHARGES = core.spell_book.get_spell_charge_max(SPELL.PHOENIX_FLAMES) or 3

local menu = {
    main_node = core.menu.tree_node(),
    enable_rotation = core.menu.keybind(7, true, "fire_mage_enable_rotation_kb"),
    use_combustion = core.menu.keybind(7, true, "fire_mage_use_combustion_kb"),
    use_shifting_power = core.menu.keybind(7, true, "fire_mage_use_shifting_power_kb"),
    aoe_mode = core.menu.combobox(1, "fire_mage_aoe_mode"),
    switch_aoe_mode = core.menu.keybind(7, false, "fire_mage_switch_aoe_kb"),
    aoe_mode_options = { "Auto-Detect", "Force Single Target", "Force AoE" },
    aoe_min_targets = core.menu.slider_int(2, 10, 3, "fire_mage_aoe_min_targets"),
    action_delay = core.menu.slider_int(50, 1500, 250, "fire_mage_action_delay"),
    use_phoenix_flames = core.menu.checkbox(true, "fire_mage_use_phoenix_flames_cb"),
    use_meteor = core.menu.checkbox(true, "fire_mage_use_meteor_cb"),
    meteor_min_targets = core.menu.slider_int(2, 10, 3, "fire_mage_meteor_min_targets"),
    use_blazing_barrier = core.menu.checkbox(true, "fire_mage_use_blazing_barrier_cb"),
    blazing_barrier_min_health_pct = core.menu.slider_float(0.1, 0.9, 0.5, "fire_mage_blazing_barrier_min_health_pct"),
    blazing_barrier_min_health_inc_pct = core.menu.slider_float(0.1, 0.9, 0.4, "fire_mage_blazing_barrier_min_health_inc_pct"),
    use_arcane_intellect = core.menu.checkbox(true, "fire_mage_use_arcane_intellect_cb"),
    use_dragons_breath = core.menu.checkbox(true, "fire_mage_use_dragons_breath_cb"),
    ftb_refresh_threshold = core.menu.slider_int(500, 5000, 1500, "fire_mage_ftb_refresh_threshold"),
}

local function on_render_menu()
    menu.main_node:render("Lek's Fire Mage", function()
        menu.enable_rotation:render("Enable Rotation", "Master on/off toggle for the script. Can be added to Control Panel.")

        core.menu.header():render("Cooldown Toggles", color.cyan(255))
        menu.use_combustion:render("Auto-Use Combustion", "Toggles automatic Combustion usage. Can be added to Control Panel.")
        menu.use_shifting_power:render("Auto-Use Shifting Power", "Toggles automatic Shifting Power usage. Can be added to Control Panel.")
        menu.use_phoenix_flames:render("Auto-Use Phoenix Flames")
        menu.use_meteor:render("Auto-Use Meteor")
        menu.use_blazing_barrier:render("Auto-Use Blazing Barrier")
        menu.use_arcane_intellect:render("Auto-Use Arcane Intellect")
        menu.use_dragons_breath:render("Auto-Use Dragon's Breath")

        core.menu.header():render("AoE Settings", color.cyan(255))
        menu.aoe_mode:render("Rotation Mode", menu.aoe_mode_options)
        menu.switch_aoe_mode:render("Switch AoE Mode Key", "Key to cycle AoE modes. Can be added to Control Panel.")
        menu.aoe_min_targets:render("Min targets for Auto AoE")
        if menu.use_meteor:get_state() then
            menu.meteor_min_targets:render("Min targets for Meteor AoE")
        end

        core.menu.header():render("Defensive & Utility", color.cyan(255))
        if menu.use_blazing_barrier:get_state() then
            menu.blazing_barrier_min_health_pct:render("Min Health % for Barrier (Current)")
            menu.blazing_barrier_min_health_inc_pct:render("Min Health % for Barrier (Predicted)")
        end

        core.menu.header():render("Timings & Network", color.cyan(255))
        menu.action_delay:render("Action Delay (ms)")
        menu.ftb_refresh_threshold:render("Feel the Burn Refresh (ms)")
    end)
end

local function on_render_control_panel()
    local control_panel_elements = {}

    local enable_key_code = menu.enable_rotation:get_key_code()
    local enable_name = "[Fire] Rotation (" .. key_helper:get_key_name(enable_key_code) .. ")"
    control_panel_utility:insert_toggle_(control_panel_elements, enable_name, menu.enable_rotation, false)

    local comb_key_code = menu.use_combustion:get_key_code()
    local comb_name = "[Fire] Use Combustion (" .. key_helper:get_key_name(comb_key_code) .. ")"
    control_panel_utility:insert_toggle_(control_panel_elements, comb_name, menu.use_combustion, false)

    local sp_key_code = menu.use_shifting_power:get_key_code()
    local sp_name = "[Fire] Use Shifting Power (" .. key_helper:get_key_name(sp_key_code) .. ")"
    control_panel_utility:insert_toggle_(control_panel_elements, sp_name, menu.use_shifting_power, false)

    local switch_key_code = menu.switch_aoe_mode:get_key_code()
    local combo_name = "[Fire] AoE Mode (" .. key_helper:get_key_name(switch_key_code) .. ")"
    local current_aoe_mode_text = menu.aoe_mode_options[menu.aoe_mode:get()]
    control_panel_utility:insert_combo_(control_panel_elements, combo_name, menu.aoe_mode, current_aoe_mode_text, #menu.aoe_mode_options, menu.switch_aoe_mode, false)
    
    return control_panel_elements
end

local function queue_action(spell_id, target, priority, message, is_positional)
    if not target then return end
    local cast_target = is_positional and target or target
    
    if is_positional then
        spell_queue:queue_spell_position(spell_id, cast_target, priority, message)
    else
        spell_queue:queue_spell_target(spell_id, cast_target, priority, message)
    end
    last_action_timestamp = core.game_time()
end

local function get_primary_rotation_target(player, nearby_enemies, consider_cleave)
    local player_target = player:get_target()
    if player_target and unit_helper:is_valid_enemy(player_target) then return player_target end
    if consider_cleave and #nearby_enemies >= 2 then
        local highest_ignite_target
        local max_ignite_value = -1
        for _, enemy in ipairs(nearby_enemies) do
            local ignite_buff = buff_manager:get_buff_data(enemy, BUFF.IGNITE)
            if ignite_buff.is_active then
                local current_ignite_value = ignite_buff.value or 1
                if current_ignite_value > max_ignite_value then
                    max_ignite_value = current_ignite_value
                    highest_ignite_target = enemy
                end
            end
        end
        if highest_ignite_target then return highest_ignite_target end
    end
    local highest_health_target
    local max_health_percent = -1
    for _, enemy in ipairs(nearby_enemies) do
        local health_percent = unit_helper:get_health_percentage(enemy)
        if health_percent > max_health_percent then
            max_health_percent = health_percent
            highest_health_target = enemy
        end
    end
    return highest_health_target
end

local function should_cast_meteor(player, nearby_enemies, use_aoe_rotation, primary_target)
    if not menu.use_meteor:get_state() then return false, nil end
    if not use_aoe_rotation then return false, nil end 
    if #nearby_enemies < menu.meteor_min_targets:get() then return false, nil end 

    if core.spell_book.get_spell_cooldown(SPELL.METEOR) > 0 then return false, nil end

    local player_position = player:get_position()
    local meteor_prediction_data = spell_prediction:new_spell_data(
        SPELL.METEOR, 40, 8, 1.5, 0.0,
        spell_prediction.prediction_type.MOST_HITS,
        spell_prediction.geometry_type.CIRCLE,
        player_position
    )
    local best_meteor_pos_info = spell_prediction:get_cast_position(player, meteor_prediction_data)
    
    if best_meteor_pos_info and best_meteor_pos_info.amount_of_hits >= menu.meteor_min_targets:get() then
        if spell_helper:is_spell_castable(SPELL.METEOR, player, primary_target, false, true) then
            return true, best_meteor_pos_info.cast_position
        end
    end
    return false, nil
end

local function should_refresh_feel_the_burn(player)
    local ftb_buff = buff_manager:get_buff_data(player, BUFF.FEEL_THE_BURN)
    return ftb_buff.is_active and ftb_buff.remaining < menu.ftb_refresh_threshold:get()
end

local function should_cast_blazing_barrier(player)
    if not menu.use_blazing_barrier:get_state() then return false end
    local current_health_pct = unit_helper:get_health_percentage(player)
    local predicted_health_pct, _, _, _ = unit_helper:get_health_percentage_inc(player, 3.0) 
    if current_health_pct <= menu.blazing_barrier_min_health_pct:get() then
        return spell_helper:is_spell_castable(SPELL.BLAZING_BARRIER, player, player)
    end
    if predicted_health_pct <= menu.blazing_barrier_min_health_inc_pct:get() then
        return spell_helper:is_spell_castable(SPELL.BLAZING_BARRIER, player, player)
    end
    return false
end

local function should_cast_arcane_intellect(player, nearby_allies)
    if not menu.use_arcane_intellect:get_state() then return false end
    if player:is_moving() then return false end 
    local has_ai_on_player = buff_manager:get_buff_data(player, BUFF.ARCANE_INTELLECT).is_active
    if not has_ai_on_player then
        return spell_helper:is_spell_castable(SPELL.ARCANE_INTELLECT, player, player)
    end
    return false
end

local function main_logic()
    if not menu.enable_rotation:get_toggle_state() then return end
    
    local player = core.object_manager.get_local_player()
    if not player or player:is_dead() or not core.spell_book.is_player_in_control() then return end
    if core.game_time() - last_action_timestamp < menu.action_delay:get() then return end
    
    local latency = core.get_ping()
    if player:is_casting_spell(latency) or player:is_channelling_spell(latency) then return end

    local player_position = player:get_position()
    local nearby_enemies = unit_helper:get_enemy_list_around(player_position, 40.0)
    
    if #nearby_enemies == 0 or not unit_helper:is_in_combat(player) then
        local nearby_allies = unit_helper:get_ally_list_around(player_position, 40.0, true, true) 
        if should_cast_arcane_intellect(player, nearby_allies) then
            queue_action(SPELL.ARCANE_INTELLECT, player, 1, "[Fire] Arcane Intellect")
        end
        if should_cast_blazing_barrier(player) then
            queue_action(SPELL.BLAZING_BARRIER, player, 3, "[Fire] Blazing Barrier")
        end
        return
    end

    local use_aoe_rotation = false
    local selected_mode = menu.aoe_mode:get()
    if selected_mode == 1 then
        if #nearby_enemies >= menu.aoe_min_targets:get() then use_aoe_rotation = true end
    elseif selected_mode == 3 then
        use_aoe_rotation = true
    end

    local primary_target = get_primary_rotation_target(player, nearby_enemies, use_aoe_rotation)
    if not primary_target then return end

    local is_moving = player:is_moving()
    local has_heating_up = buff_manager:get_buff_data(player, BUFF.HEATING_UP).is_active
    local has_hot_streak = buff_manager:get_buff_data(player, BUFF.HOT_STREAK).is_active
    local is_in_combustion = buff_manager:get_buff_data(player, BUFF.COMBUSTION).is_active
    local has_hyperthermia = buff_manager:get_buff_data(player, BUFF.HYPERTHERMIA).is_active
    local ftb_needs_refresh = should_refresh_feel_the_burn(player)
    
    local fire_blast_charges = core.spell_book.get_spell_charge(SPELL.FIRE_BLAST)
    local phoenix_flames_charges = core.spell_book.get_spell_charge(SPELL.PHOENIX_FLAMES)
    local combustion_cd = core.spell_book.get_spell_cooldown(SPELL.COMBUSTION)
    local dragons_breath_cd = core.spell_book.get_spell_cooldown(SPELL.DRAGONS_BREATH)
    
    if should_cast_blazing_barrier(player) then
        queue_action(SPELL.BLAZING_BARRIER, player, 8, "[Fire] Defensive")
        return

    elseif is_in_combustion then
        if has_hot_streak then
            if use_aoe_rotation and spell_helper:is_spell_castable(SPELL.FLAMESTRIKE, player, primary_target, true, true) then
                queue_action(SPELL.FLAMESTRIKE, primary_target:get_position(), 7, "[Fire] Combustion Flamestrike", true)
            else
                queue_action(SPELL.PYROBLAST, primary_target, 7, "[Fire] Combustion Pyroblast")
            end
        elseif phoenix_flames_charges > 0 and menu.use_phoenix_flames:get_state() then
             queue_action(SPELL.PHOENIX_FLAMES, primary_target, 6, "[Fire] Combustion Phoenix")
        elseif fire_blast_charges > 0 then
             queue_action(SPELL.FIRE_BLAST, primary_target, 6, "[Fire] Combustion Fire Blast")
        else
            queue_action(SPELL.SCORCH, primary_target, 6, "[Fire] Combustion Scorch")
        end
        return
        
    elseif has_hyperthermia then
         queue_action(SPELL.PYROBLAST, primary_target, 8, "[Fire] Hyperthermia Pyroblast")
        return

    elseif menu.use_combustion:get_toggle_state() and combustion_cd == 0 and fire_blast_charges > 0 then
        local time_to_die = combat_forecast:get_forecast_single(primary_target)
        if time_to_die > 8.0 then 
            if spell_helper:is_spell_castable(SPELL.COMBUSTION, player, player) then
                queue_action(SPELL.COMBUSTION, player, 9, "[Fire] Activating Combustion")
                return
            end
        end
    
    elseif has_hot_streak then
        if use_aoe_rotation then
             local prediction_result = spell_prediction:get_cast_position(primary_target, spell_prediction:new_spell_data(SPELL.FLAMESTRIKE, 40, 8, 0, 0, spell_prediction.prediction_type.MOST_HITS, spell_prediction.geometry_type.CIRCLE, player:get_position()))
             if prediction_result and prediction_result.cast_position then
                 queue_action(SPELL.FLAMESTRIKE, prediction_result.cast_position, 4, "[Fire] Hot Streak Flamestrike", true)
             end
        else
            queue_action(SPELL.PYROBLAST, primary_target, 4, "[Fire] Hot Streak Pyroblast")
        end
        return

    elseif (fire_blast_charges == FB_MAX_CHARGES or (ftb_needs_refresh and fire_blast_charges > 0)) and spell_helper:is_spell_castable(SPELL.FIRE_BLAST, player, primary_target) then
        queue_action(SPELL.FIRE_BLAST, primary_target, 5, "[Fire] Fire Blast (Overcap/FtB)")
        return
    elseif menu.use_phoenix_flames:get_state() and (phoenix_flames_charges == PF_MAX_CHARGES or (ftb_needs_refresh and phoenix_flames_charges > 0)) and spell_helper:is_spell_castable(SPELL.PHOENIX_FLAMES, player, primary_target) then
        queue_action(SPELL.PHOENIX_FLAMES, primary_target, 5, "[Fire] Phoenix Flames (Overcap/FtB)")
        return

    elseif has_heating_up then
        local distance_sq_to_target = player_position:squared_dist_to_ignore_z(primary_target:get_position())
        if menu.use_dragons_breath:get_state() and dragons_breath_cd == 0 and (core.game_time() - last_dragons_breath_cast > 1500) and distance_sq_to_target < (12*12) and spell_helper:is_spell_castable(SPELL.DRAGONS_BREATH, player, primary_target, true, false) then
            queue_action(SPELL.DRAGONS_BREATH, primary_target, 6, "[Fire] Dragon's Breath (Proc Gen)")
            last_dragons_breath_cast = core.game_time()
            return
        elseif fire_blast_charges > 0 and spell_helper:is_spell_castable(SPELL.FIRE_BLAST, player, primary_target) then
            queue_action(SPELL.FIRE_BLAST, primary_target, 5, "[Fire] Convert Heating Up with Fire Blast")
            return
        elseif phoenix_flames_charges > 0 and menu.use_phoenix_flames:get_state() and spell_helper:is_spell_castable(SPELL.PHOENIX_FLAMES, player, primary_target) then
            queue_action(SPELL.PHOENIX_FLAMES, primary_target, 5, "[Fire] Convert Heating Up with Phoenix Flames")
            return
        end
        
    elseif menu.use_meteor:get_state() then
        local overall_combat_ttd = combat_forecast:get_forecast()
        if overall_combat_ttd > 5.0 then 
            local can_cast_meteor, meteor_pos = should_cast_meteor(player, nearby_enemies, use_aoe_rotation, primary_target)
            if can_cast_meteor then
                queue_action(SPELL.METEOR, meteor_pos, 2, "[Fire] Meteor AoE", true) 
                return
            end
        end
    elseif menu.use_shifting_power:get_toggle_state() and fire_blast_charges == 0 and phoenix_flames_charges == 0 and not is_moving and spell_helper:is_spell_castable(SPELL.SHIFTING_POWER, player, player) then
        queue_action(SPELL.SHIFTING_POWER, player, 2, "[Fire] Shifting Power")
        return
        
    else
        if menu.use_phoenix_flames:get_state() and phoenix_flames_charges > 0 and spell_helper:is_spell_castable(SPELL.PHOENIX_FLAMES, player, primary_target) then
            queue_action(SPELL.PHOENIX_FLAMES, primary_target, 1, "[Fire] Filler Phoenix Flames")
        elseif is_moving or (unit_helper:get_health_percentage(primary_target) <= 0.30) then
            queue_action(SPELL.SCORCH, primary_target, 1, "[Fire] Filler Scorch")
        else
            queue_action(SPELL.FIREBALL, primary_target, 1, "[Fire] Filler Fireball")
        end
    end
end

local function handle_control_panel_actions()
    if menu.switch_aoe_mode:get_state() and (core.game_time() - last_aoe_switch_time > 250) then
        local current_mode = menu.aoe_mode:get()
        local next_mode = current_mode + 1
        if next_mode > #menu.aoe_mode_options then
            next_mode = 1
        end
        menu.aoe_mode:set(next_mode)
        last_aoe_switch_time = core.game_time()
    end
end

local function on_update()
    handle_control_panel_actions()
    control_panel_utility:on_update(menu)
    main_logic()
end

core.register_on_update_callback(on_update)
core.register_on_render_menu_callback(on_render_menu)
core.register_on_render_control_panel_callback(on_render_control_panel)
