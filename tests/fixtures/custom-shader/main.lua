local mod = RegisterMod("ModSync Live Reload Fixture B", 1)
local item = Isaac.GetItemIdByName("ModSync Live Reload B")
local ok, animation = pcall(function()
    local sprite = Sprite()
    sprite:Load("gfx/modsync_live_reload_probe.anm2", true)
    sprite:Play("Probe", true)
    return sprite:GetAnimation()
end)
Isaac.DebugString("[live-reload-fixture] B loaded; item=" .. tostring(item) .. " resource_ok=" .. tostring(ok) .. " animation=" .. tostring(animation))

-- Custom-shader fixture: registering a shader from this mod puts an entry into
-- REPENTOGON's shader map. ShaderLoader::ResetAfterModReload() must recompile it
-- after `new`, drop it after `remove`, and recompile it again after `new`.
local shaderOk, shaderErr = pcall(function()
    local fmt = Renderer.VertexAttributeFormat
    local vertexDesc = {
        {"Position", fmt.POSITION},
        {"Color", fmt.COLOR},
        {"TexCoord", fmt.TEX_COORD},
        {"ColorizeIn", fmt.VEC4},
        {"ColorOffsetIn", fmt.VEC3},
        {"TextureSize", fmt.VEC2},
        {"PixelationAmount", fmt.FLOAT},
        {"ClipPlane", fmt.VEC3},
    }
    return Renderer.LoadShader("shaders/modsync_probe", vertexDesc)
end)
Isaac.DebugString("[live-reload-fixture] custom shader registered=" .. tostring(shaderOk))

local checks = 0
local function verify()
    checks = checks + 1
    if checks ~= 30 then return end
    local id = Isaac.GetItemIdByName("ModSync Live Reload B")
    local xmlOk, entry = pcall(XMLData.GetEntryByName, XMLNode.ITEM, "ModSync Live Reload B")
    local configOk, config = pcall(function() return Isaac.GetItemConfig():GetCollectible(id) end)
    Isaac.DebugString("[live-reload-fixture] B after reset; item=" .. tostring(id) .. " xml_ok=" .. tostring(xmlOk and entry ~= nil) .. " config_ok=" .. tostring(configOk and config ~= nil))
end
mod:AddCallback(ModCallbacks.MC_MAIN_MENU_RENDER, verify)
