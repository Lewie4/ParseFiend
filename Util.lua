ParseFiend = ParseFiend or {}

ParseFiend.Colors = {
    GREY   = "|cff666666",
    GREEN  = "|cff1eff00",
    BLUE   = "|cff0070ff",
    PURPLE = "|cffa335ee",
    ORANGE = "|cffff8000",
    PINK   = "|cffe268a8",
    GOLD   = "|cffe5cc80",
    WHITE  = "|cffffffff",
}

function ParseFiend:GetPPColor(pp)

    pp = tonumber(pp) or 0

    if pp >= 4000 then
        return self.Colors.GOLD
    elseif pp >= 3960 then
        return self.Colors.PINK
    elseif pp >= 3800 then
        return self.Colors.ORANGE
    elseif pp >= 3000 then
        return self.Colors.PURPLE
    elseif pp >= 2000 then
        return self.Colors.BLUE
    elseif pp >= 1000 then
        return self.Colors.GREEN
    else
        return self.Colors.GREY
    end
end

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