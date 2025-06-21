
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
    COMBUSTION = {190319}
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
        menu.aoe_mode:render("Rotation Mode", menu.aoe_mode_options, "Auto-Detect: Switches to AoE automatically.\nForce options override auto-detection.")
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

local function main_logic()
    -- Primary Guard Clauses
    if not menu.enable_rotation:get_toggle_state() then return end
    local player = core.object_manager.get_local_player()
    if not player or player:is_dead() or not core.spell_book.is_player_in_control() then return end
    if core.game_time() - last_action_timestamp < menu.action_delay:get() then return end
    if not unit_helper:is_in_combat(player) then return end
    local latency = core.get_ping()
    if player:is_casting_spell(latency) or player:is_channelling_spell(latency) then return end
    
    -- Targeting
    local target = target_selector:get_targets(1)[1]
    if not target then return end

    -- Gather Data for this Frame
    local nearby_enemies_count = #unit_helper:get_enemy_list_around(target:get_position(), 10.0)
    local is_moving = player:is_moving()
    local has_heating_up = buff_manager:get_buff_data(player, BUFF.HEATING_UP).is_active
    local has_hot_streak = buff_manager:get_buff_data(player, BUFF.HOT_STREAK).is_active
    local is_in_combustion = buff_manager:get_buff_data(player, BUFF.COMBUSTION).is_active
    local fire_blast_charges = core.spell_book.get_spell_charge(SPELL.FIRE_BLAST)
    local combustion_cd = core.spell_book.get_spell_cooldown(SPELL.COMBUSTION)
    
    -- Determine if we should use AoE spells
    local use_aoe_rotation = false
    local selected_mode = menu.aoe_mode:get()
    if selected_mode == 1 then -- Auto-Detect
        if nearby_enemies_count >= menu.aoe_min_targets:get() then use_aoe_rotation = true end
    elseif selected_mode == 3 then -- Force AoE
        use_aoe_rotation = true
    end
    
    -- === SCRIPT ACTION PRIORITY LIST ===

    -- P1: Handle active Combustion phase
    if is_in_combustion then
        if has_hot_streak then
            if use_aoe_rotation and spell_helper:is_spell_castable(SPELL.FLAMESTRIKE, player, target) then
                queue_action(SPELL.FLAMESTRIKE, target, 7, "[Fire] Combustion Flamestrike", true)
            elseif spell_helper:is_spell_castable(SPELL.PYROBLAST, player, target) then
                queue_action(SPELL.PYROBLAST, target, 7, "[Fire] Combustion Pyroblast")
            end
        elseif has_heating_up and spell_helper:is_spell_castable(SPELL.FIRE_BLAST, player, target) then
            queue_action(SPELL.FIRE_BLAST, target, 6, "[Fire] Combustion Fire Blast")
        else
            if spell_helper:is_spell_castable(SPELL.SCORCH, player, target) then
                queue_action(SPELL.SCORCH, target, 7, "[Fire] Combustion Scorch")
            end
        end

    -- P2: Use main Combustion cooldown
    elseif menu.use_combustion:get_toggle_state() and combustion_cd == 0 and fire_blast_charges > 0 and spell_helper:is_spell_castable(SPELL.COMBUSTION, player, player) then
        queue_action(SPELL.COMBUSTION, player, 9, "[Fire] Activating Combustion")
    
    -- P3: Spend Hot Streak proc
    elseif has_hot_streak then
        if use_aoe_rotation and spell_helper:is_spell_castable(SPELL.FLAMESTRIKE, player, target) then
            queue_action(SPELL.FLAMESTRIKE, target, 4, "[Fire] Hot Streak Flamestrike", true)
        elseif spell_helper:is_spell_castable(SPELL.PYROBLAST, player, target) then
            queue_action(SPELL.PYROBLAST, target, 4, "[Fire] Hot Streak Pyroblast")
        end

    -- P4: Convert Heating Up proc
    elseif has_heating_up and fire_blast_charges > 0 and spell_helper:is_spell_castable(SPELL.FIRE_BLAST, player, target) then
        queue_action(SPELL.FIRE_BLAST, target, 5, "[Fire] Convert Heating Up")
    
    -- P5: Use Shifting Power for resource recovery
    elseif menu.use_shifting_power:get_toggle_state() and fire_blast_charges == 0 and not is_moving and spell_helper:is_spell_castable(SPELL.SHIFTING_POWER, player, player) then
        queue_action(SPELL.SHIFTING_POWER, player, 2, "[Fire] Shifting Power")

    -- P6: Cast filler spells (Guaranteed Fallback)
    else
        if is_moving or (unit_helper:get_health_percentage(target) <= 0.30) then
            if spell_helper:is_spell_castable(SPELL.SCORCH, player, target) then
                queue_action(SPELL.SCORCH, target, 1, "[Fire] Filler Scorch")
            end
        elseif spell_helper:is_spell_castable(SPELL.FIREBALL, player, target) then
            queue_action(SPELL.FIREBALL, target, 1, "[Fire] Filler Fireball")
        end
    end
end

--[[-------------------------------------------------------------------
    7. MAIN UPDATE AND CALLBACK REGISTRATION
---------------------------------------------------------------------]]
local function on_update()
    control_panel_utility:on_update(menu)
    main_logic()
end

core.register_on_update_callback(on_update)
core.register_on_render_menu_callback(on_render_menu)
core.register_on_render_control_panel_callback(on_render_control_panel)