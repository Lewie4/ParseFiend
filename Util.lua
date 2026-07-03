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

-- Schema constants; update when changing tiers.
ParseFiend.BOSSES_PER_TIER       = 10   -- bosses per raid tier
ParseFiend.DIFFICULTIES_PER_BOSS = 4    -- lfr, normal, heroic, mythic
ParseFiend.PP_CELL_COUNT         = ParseFiend.BOSSES_PER_TIER * ParseFiend.DIFFICULTIES_PER_BOSS

-- Difficulty column index *inside* the 40-cell pp array. Boss N's difficulty
-- column is at cell index `(N-1)*4 + DIFFICULTY_INDEX[difficulty]`.
ParseFiend.DIFFICULTY_INDEX = {
    lfr    = 1,
    normal = 2,
    heroic = 3,
    mythic = 4,
}

-- Trim and collapse whitespace. We deliberately do NOT change case here so
-- the export pipeline can write canonical names ("Kazzak", not "KAZZAK"); keys
-- are compared directly to Blizzard's GetNormalizedRealmName() output.
---@param key string|nil
---@return string|nil
local function NormalizeKey(key)
    if not key or type(key) ~= "string" then return nil end
    if key == "" then return nil end
    key = key:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    return key ~= "" and key or nil
end
ParseFiend.NormalizeKey = NormalizeKey

---@param pp number|string|nil
---@return number # Always a number in [0,100].
local function SanitizePP(pp)
    if pp == nil or pp == "-" or pp == "" then return 0 end
    if type(pp) == "string" then pp = tonumber(pp) end
    if type(pp) ~= "number" or pp ~= pp then return 0 end -- NaN guard
    if pp < 0 then return 0 end
    if pp > 100 then return 100 end
    return pp
end
ParseFiend.SanitizePP = SanitizePP

---@return string|nil region  "US"|"EU"|"KR"|"TW"|"CN" depending on login portal.
function ParseFiend:GetRegion()
    if GetCurrentRegionName then
        local ok, name = pcall(GetCurrentRegionName)
        if ok and type(name) == "string" and name ~= "" then
            return name:upper()
        end
    end
    if GetCurrentRegion then
        local ok, id = pcall(GetCurrentRegion)
        if ok and type(id) == "number" then
            local mapping = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
            return mapping[id]
        end
    end
    return "US"
end

---Look up a character record. Returns the table or nil.
---@param name string
---@param realm string|nil
---@param region string|nil
---@return table?
function ParseFiend:GetPlayerRecord(name, realm, region)
    if not ParseFiendDB or not name then return nil end

    name = NormalizeKey(name)
    if not name then return nil end

    region  = NormalizeKey(region) or self:GetRegion()
    realm   = NormalizeKey(realm)
    if not realm then return nil end

    local byRegion = ParseFiendDB[region]
    if not byRegion then return nil end

    local byRealm = byRegion[realm]
    if not byRealm then return nil end

    return byRealm[name]
end

---Compute the per-difficulty aggregate: sum of all 10 boss cells in a single
---difficulty column. Maxes at 1000 (10*100).
---@param ppTable table|number[]
---@param difficultyIndex integer 1..4  Use ParseFiend.DIFFICULTY_INDEX[difficulty].
---@return number
function ParseFiend:AggregateByDifficulty(ppTable, difficultyIndex)
    if not ppTable then return 0 end
    if type(difficultyIndex) ~= "number" then return 0 end
    if difficultyIndex < 1 or difficultyIndex > ParseFiend.DIFFICULTIES_PER_BOSS then return 0 end

    local total = 0
    for bossIndex = 1, ParseFiend.BOSSES_PER_TIER do
        local cell = (bossIndex - 1) * ParseFiend.DIFFICULTIES_PER_BOSS + difficultyIndex
        total = total + SanitizePP(ppTable[cell])
    end
    return total
end

---Convenience: aggregate by difficulty *name* (e.g. "mythic") rather than index.
---@param ppTable table|number[]
---@param difficultyName string # "lfr"|"normal"|"heroic"|"mythic"
---@return number
function ParseFiend:AggregatePerDifficulty(ppTable, difficultyName)
    local diffIndex = self.DIFFICULTY_INDEX[(difficultyName or ""):lower()]
    if not diffIndex then return 0 end
    return self:AggregateByDifficulty(ppTable, diffIndex)
end

---Compute the overall aggregate: sum of all 40 cells (maxes at 4000).
---This is the value used for the parse-point colour band on the tooltip.
---@param ppTable table|number[]
---@return number
function ParseFiend:AggregateTotal(ppTable)
    if not ppTable then return 0 end
    local total = 0
    for i = 1, ParseFiend.PP_CELL_COUNT do
        total = total + SanitizePP(ppTable[i])
    end
    return total
end

---Colour band for a parse-points value (max 4000).
---@param pp number
---@return string|nil colour escape code (|cxxxxxxxxxx) or nil if pp is invalid.
function ParseFiend:GetPPColor(pp)
    pp = tonumber(pp)
    if not pp or pp ~= pp then return self.Colors.GREY end

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
