ParseFiend = ParseFiend or {}

ParseFiendConfig = ParseFiendConfig or {}

local defaults = {
    debug = false,
}

local frame = CreateFrame("Frame")

frame:RegisterEvent("PLAYER_LOGIN")

frame:SetScript("OnEvent", function()

    -- apply defaults
    for k, v in pairs(defaults) do
        if ParseFiendConfig[k] == nil then
            ParseFiendConfig[k] = v
        end
    end

    print("|cff00ff96Parse Fiend loaded.|r")

end)