
local plugin = {}

plugin["name"] = "Leks fire mage"
plugin["version"] = "3.3.0"
plugin["author"] = "Lekora"
plugin["load"] = true


local local_player = core.object_manager.get_local_player()
if not local_player then
    plugin["load"] = false
    return plugin
end

---@type enums
local enums = require("common/enums")
local player_class = local_player:get_class()

local is_valid_class = player_class == enums.class_id.MAGE

if not is_valid_class then
    plugin["load"] = false
    return plugin
end

local player_spec_id = core.spell_book.get_specialization_id()
local fire_mage = enums.class_spec_id.get_spec_id_from_enum(enums.class_spec_id.spec_enum.FIRE_MAGE)

if player_spec_id ~= fire_mage then
    plugin["load"] = false
    return plugin
end

return plugin