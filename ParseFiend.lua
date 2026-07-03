ParseFiend = ParseFiend or {}

ParseFiendConfig = ParseFiendConfig or {}

local defaults = {
    -- Default toggles. To add a new user-facing setting:
    --   1. Add the key here.
    --   2. Register the proxy in Settings.lua.
    --   3. Read/write through Util/UI modules.
    debug = false,
}

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()
    for k, v in pairs(defaults) do
        if ParseFiendConfig[k] == nil then
            ParseFiendConfig[k] = v
        end
    end
    print("|cff00ff96Parse Fiend loaded.|r")
end)