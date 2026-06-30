ParseFiend = ParseFiend or {}

function ParseFiend:GetCharacterKey(name, realm)

    if not name or not realm then
        return nil
    end

    realm = realm:gsub("%s+", "")

    return name .. "-" .. realm

end

function ParseFiend:GetPlayerData(name, realm)

    local key = self:GetCharacterKey(name, realm)

    if not key then
        return nil
    end

    return ParseFiendDB[key]

end