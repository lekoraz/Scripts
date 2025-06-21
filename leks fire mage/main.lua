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

local SPELL = {
    FIREBALL = 133,
    PYROBLAST = 11366,
    FLAMESTRIKE = 2120,
    FIRE_BLAST = 108853,
    COMBUSTION = 190319,
    SCORCH = 2948,
    SHIFTING_POWER = 314791
}

local BUFF = {
    HEATING_UP = {48107},
    HOT_STREAK = {48108},
    COMBUSTION = {190319},
    IGNITE = {12654}
}

local last_action_timestamp = 0

local menu = {
    main_node = core.menu.tree_node(),
    enable_rotation = core.menu.keybind(7, true, "fire_mage_enable_rotation"),
    use_combustion = core.menu.keybind(7, true, "fire_mage_use_combustion_kb"),
    use_shifting_power = core.menu.keybind(7, true, "fire_mage_use_shifting_power_kb"),
    aoe_mode = core.menu.combobox(1, "fire_mage_aoe_mode"),
    aoe_mode_options = { "Auto-Detect", "Force Single Target", "Force AoE" },
    aoe_min_targets = core.menu.slider_int(2, 10, 3, "fire_mage_aoe_min_targets"),
    action_delay = core.menu.slider_int(50, 1500, 800, "fire_mage_action_delay")
}

local function on_render_menu()
    menu.main_node:render("Fire Mage Rotation", function()
        menu.enable_rotation:render("Enable Rotation", "Master on/off toggle for the script.")

        core.menu.header():render("Cooldown Toggles", color.cyan(255))
        menu.use_combustion:render("Auto-Use Combustion", "Toggles automatic Combustion usage.")
        menu.use_shifting_power:render("Auto-Use Shifting Power", "Toggles automatic Shifting Power usage.")

        core.menu.header():render("AoE Settings", color.cyan(255))
        menu.aoe_mode:render("Rotation Mode", menu.aoe_mode_options, "Auto-Detect: Switches to AoE automatically.\\nForce options override auto-detection.")
        menu.aoe_min_targets:render("Min targets for Auto AoE")

        core.menu.header():render("Timings & Network", color.cyan(255))
        menu.action_delay:render("Action Delay (ms)", "Time to wait after an action. Increase if you have high latency.")
    end)
end

local function on_render_control_panel()
    local control_panel_elements = {}

    local key_name_main = key_helper:get_key_name(menu.enable_rotation:get_key_code())
    control_panel_utility:insert_toggle_(control_panel_elements, "[Fire] Rotation (" .. key_name_main .. ")", menu.enable_rotation, false)

    local key_name_comb = key_helper:get_key_name(menu.use_combustion:get_key_code())
    control_panel_utility:insert_toggle_(control_panel_elements, "[Fire] Combustion (" .. key_name_comb .. ")", menu.use_combustion, false)

    local key_name_sp = key_helper:get_key_name(menu.use_shifting_power:get_key_code())
    control_panel_utility:insert_toggle_(control_panel_elements, "[Fire] Shifting Power (" .. key_name_sp .. ")", menu.use_shifting_power, false)

    return control_panel_elements
end

local function queue_action(spell_id, target, priority, message, is_positional)
    if not target then return end
    local cast_target = is_positional and target:get_position() or target
    if is_positional then
        spell_queue:queue_spell_position(spell_id, cast_target, priority, message)
    else
        spell_queue:queue_spell_target(spell_id, cast_target, priority, message)
    end
    last_action_timestamp = core.game_time()
end

local function get_primary_rotation_target(player, nearby_enemies, consider_cleave)
    local player_target = player:get_target()

    if player_target and unit_helper:is_unit_enemy(player_target) and unit_helper:is_target_valid(player_target) then
        return player_target
    end

    if consider_cleave and #nearby_enemies >= 2 then
        local highest_ignite_target = nil
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
        if highest_ignite_target then
            return highest_ignite_target
        end
    end

    local highest_health_target = nil
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

local function get_fire_blast_target(nearby_enemies)
    local highest_ignite_target = nil
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

    if not highest_ignite_target then
        return get_primary_rotation_target(core.object_manager.get_local_player(), nearby_enemies, false)
    end
    return highest_ignite_target
end

local function get_scorch_target(nearby_enemies)
    local lowest_health_target = nil
    local min_health_percent = 101

    for _, enemy in ipairs(nearby_enemies) do
        local health_percent = unit_helper:get_health_percentage(enemy)
        if health_percent < min_health_percent then
            min_health_percent = health_percent
            lowest_health_target = enemy
        end
    end

    return lowest_health_target
end

local function main_logic()
    if not menu.enable_rotation:get_toggle_state() then return end
    local player = core.object_manager.get_local_player()
    if not player or player:is_dead() or not core.spell_book.is_player_in_control() then return end
    if core.game_time() - last_action_timestamp < menu.action_delay:get() then return end
    if not unit_helper:is_in_combat(player) then return end
    local latency = core.get_ping()
    if player:is_casting_spell(latency) or player:is_channelling_spell(latency) then return end

    local player_position = player:get_position()
    local nearby_enemies = unit_helper:get_enemy_list_around(player_position, 40.0)
    if #nearby_enemies == 0 then return end

    local nearby_enemies_count = #nearby_enemies
    local use_aoe_rotation = false
    local selected_mode = menu.aoe_mode:get()
    if selected_mode == 1 then
        if nearby_enemies_count >= menu.aoe_min_targets:get() then use_aoe_rotation = true end
    elseif selected_mode == 3 then
        use_aoe_rotation = true
    end

    local primary_target = get_primary_rotation_target(player, nearby_enemies, use_aoe_rotation)
    if not primary_target then return end

    local is_moving = player:is_moving()
    local has_heating_up = buff_manager:get_buff_data(player, BUFF.HEATING_UP).is_active
    local has_hot_streak = buff_manager:get_buff_data(player, BUFF.HOT_STREAK).is_active
    local is_in_combustion = buff_manager:get_buff_data(player, BUFF.COMBUSTION).is_active
    local fire_blast_charges = core.spell_book.get_spell_charge(SPELL.FIRE_BLAST)
    local combustion_cd = core.spell_book.get_spell_cooldown(SPELL.COMBUSTION)

    if is_in_combustion then
        if has_hot_streak then
            if use_aoe_rotation and spell_helper:is_spell_castable(SPELL.FLAMESTRIKE, player, primary_target) then
                queue_action(SPELL.FLAMESTRIKE, primary_target, 7, "[Fire] Combustion Flamestrike", true)
            elseif spell_helper:is_spell_castable(SPELL.PYROBLAST, player, primary_target) then
                queue_action(SPELL.PYROBLAST, primary_target, 7, "[Fire] Combustion Pyroblast")
            end
        elseif has_heating_up and fire_blast_charges > 0 then
            local fb_target = get_fire_blast_target(nearby_enemies)
            if fb_target and spell_helper:is_spell_castable(SPELL.FIRE_BLAST, player, fb_target) then
                queue_action(SPELL.FIRE_BLAST, fb_target, 6, "[Fire] Combustion Fire Blast")
            end
        else
            local scorch_target = get_scorch_target(nearby_enemies)
            if scorch_target and spell_helper:is_spell_castable(SPELL.SCORCH, player, scorch_target) then
                queue_action(SPELL.SCORCH, scorch_target, 7, "[Fire] Combustion Scorch")
            end
        end
    elseif menu.use_combustion:get_toggle_state() and combustion_cd == 0 and fire_blast_charges > 0 and spell_helper:is_spell_castable(SPELL.COMBUSTION, player, player) then
        queue_action(SPELL.COMBUSTION, player, 9, "[Fire] Activating Combustion")
    elseif has_hot_streak then
        if use_aoe_rotation and spell_helper:is_spell_castable(SPELL.FLAMESTRIKE, player, primary_target) then
            queue_action(SPELL.FLAMESTRIKE, primary_target, 4, "[Fire] Hot Streak Flamestrike", true)
        elseif spell_helper:is_spell_castable(SPELL.PYROBLAST, player, primary_target) then
            queue_action(SPELL.PYROBLAST, primary_target, 4, "[Fire] Hot Streak Pyroblast")
        end
    elseif has_heating_up and fire_blast_charges > 0 then
        local fb_target = get_fire_blast_target(nearby_enemies)
        if fb_target and spell_helper:is_spell_castable(SPELL.FIRE_BLAST, player, fb_target) then
            queue_action(SPELL.FIRE_BLAST, fb_target, 5, "[Fire] Convert Heating Up")
        end
    elseif menu.use_shifting_power:get_toggle_state() and fire_blast_charges == 0 and not is_moving and spell_helper:is_spell_castable(SPELL.SHIFTING_POWER, player, player) then
        queue_action(SPELL.SHIFTING_POWER, player, 2, "[Fire] Shifting Power")
    else
        if is_moving or (unit_helper:get_health_percentage(primary_target) <= 0.30) then
            local scorch_target = get_scorch_target(nearby_enemies)
            if scorch_target and unit_helper:get_health_percentage(scorch_target) <= 0.30 and spell_helper:is_spell_castable(SPELL.SCORCH, player, scorch_target) then
                queue_action(SPELL.SCORCH, scorch_target, 1, "[Fire] Filler Scorch (Low Health)")
            elseif spell_helper:is_spell_castable(SPELL.SCORCH, player, primary_target) then
                queue_action(SPELL.SCORCH, primary_target, 1, "[Fire] Filler Scorch (Moving)")
            end
        elseif spell_helper:is_spell_castable(SPELL.FIREBALL, player, primary_target) then
            queue_action(SPELL.FIREBALL, primary_target, 1, "[Fire] Filler Fireball")
        end
    end
end

local function on_update()
    control_panel_utility:on_update(menu)
    main_logic()
end

core.register_on_update_callback(on_update)
core.register_on_render_menu_callback(on_render_menu)
core.register_on_render_control_panel_callback(on_render_control_panel)
