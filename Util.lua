-- =====================================================================
-- EXTENSION POINTS
-- =====================================================================
-- To add new features safely, touch the file that owns the layer:
--
--   * NEW data source          -> Util.lua  (GetPlayerRecord exists; add
--                                 beside for new lookups / aggregators).
--   * NEW tooltip source       -> Tooltip.lua  (add a Setup* function and
--                                 hook it in setupFrame's loop below).
--   * NEW aggregator            -> Util.lua  (use the local-upvalue pattern
--                                 from AggregateByDifficulty).
--   * NEW colour band           -> Util.lua  (extend GetPPColor's if/elseif
--                                 ladder; thresholds stay in code).
--   * NEW setting toggle        -> Settings.lua + ParseFiendConfig
--                                 (defaults come from this file).
--   * NEW render variant        -> Tooltip.lua  (AppendParsePoints stays
--                                 the single renderer; feature flags live
--                                 on the record).
--   * NEW file                  -> add to ParseFiend.toc in dependency
--                                 order. Util.lua must come first so the
--                                 ParseFiend namespace exists before anything
--                                 else reads it.
-- =====================================================================

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

-- Schema constants; update when changing tiers. The pp array is laid out
-- as [boss1_lfr, boss1_normal, boss1_heroic, boss1_mythic, boss2_lfr, ...]
-- so cell index = (boss-1)*DIFFICULTIES_PER_BOSS + DIFFICULTY_INDEX[difficulty].
-- Export pipeline tool (Celianware/Sunstrider-Auctioner-style entry)
-- reads these constants to validate its output.
ParseFiend.BOSSES_PER_TIER       = 10                                  -- bosses in current tier
ParseFiend.DIFFICULTIES_PER_BOSS = 4                                   -- lfr, normal, heroic, mythic
ParseFiend.PP_CELL_COUNT         = ParseFiend.BOSSES_PER_TIER * ParseFiend.DIFFICULTIES_PER_BOSS

ParseFiend.DIFFICULTY_INDEX = {
    lfr    = 1,
    normal = 2,
    heroic = 3,
    mythic = 4,
}

-- Trim whitespace. Keys are compared directly to Blizzard's
-- GetNormalizedRealmName() output, so the export pipeline must emit
-- canonical mixed-case strings ("Kazzak", not "KAZZAK").
---@param key string|nil
---@return string|nil
local function NormalizeKey(key)
    if not key or type(key) ~= "string" then return nil end
    if key == "" then return nil end
    return (key:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " "))
end
ParseFiend.NormalizeKey = NormalizeKey

---Convert a realm display name into the slug form used as the database key
---in Data.lua. The export pipeline generates these keys from the player-
---facing realm display name by:
---   1. Stripping every non-alphabetic / non-space character (apostrophes,
---      hyphens, special casing punctuation, etc).
---   2. Lower-casing any uppercase letter that is now sitting immediately
---      after a letter within the same "word" (i.e. CamelCase that was
---      created by step 1 joining two originally separate words).
---Examples (display -> slug):
---   "Quel'Thalas"      -> "Quelthalas"
---   "Twisting Nether"  -> "Twisting Nether"
---   "Tarren Mill"      -> "Tarren Mill"
---   "Blackmoore"       -> "Blackmoore"
---The display form is retained for chat/tooltip rendering; only this
---slug is used as the look-up key for the player record.
---@param displayRealm string|nil
---@return string|nil
local function SlugifyRealm(displayRealm)
    if not displayRealm or type(displayRealm) ~= "string" then return nil end
    -- Step 1: keep letters and spaces. (u)letter is `%a` in Lua patterns
    -- and includes our apostrophes, hyphens, accent chars, etc.
    local s = displayRealm:gsub("[^%a%s]", "")
    if s == "" then return nil end
    -- Step 2: collapse any lowercase-letter(+uppercase-letter) pattern
    -- that arose from joining two CamelCase words once punctuation was
    -- removed. Single-pass replacement — ordered left-to-right so each
    -- match is fed back into the engine exactly once.
    s = s:gsub("(%l)(%u)", function(prev, uc)
        return prev .. uc:lower()
    end)
    -- Trim any whitespace we might have left at the seams.
    s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("%s+", " ")
    return s ~= "" and s or nil
end
ParseFiend.SlugifyRealm = SlugifyRealm

---Fast path for the hot read: ppTable cells are already numbers in [0,100].
---Only the slow fallback tiers handle non-number input (legacy strings).
---@param pp number|string|nil
---@return number
local function SanitizePP(pp)
    if pp == nil then return 0 end
    local t = type(pp)
    if t == "number" then
        if pp ~= pp or pp <= 0 then return 0 end
        if pp > 100 then return 100 end
        return pp
    end
    if t ~= "string" or pp == "" or pp == "-" then return 0 end
    pp = tonumber(pp)
    if not pp or pp ~= pp or pp <= 0 then return 0 end
    if pp > 100 then return 100 end
    return pp
end
ParseFiend.SanitizePP = SanitizePP

---@return string|nil region  "US"|"EU"|"KR"|"TW"|"CN" depending on login portal.
function ParseFiend:GetRegion()
    if GetCurrentRegionName then
        local ok, name = pcall(GetCurrentRegionName)
        if ok and type(name) == "string" and name ~= "" then return name:upper() end
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
---The realm argument is the *display* form (e.g. "Quel'Thalas" — what the
---in-game tooltips and chat filter pass through). The database key is the
---slug form ("Quelthalas") produced by the export pipeline. We slugify
---once here so every caller benefits without having to know the encoding.
---@param name string
---@param realm string|nil
---@param region string|nil
---@return table?
function ParseFiend:GetPlayerRecord(name, realm, region)
    if not ParseFiendDB or not name then return nil end

    name = NormalizeKey(name)
    if not name then return nil end
    realm = SlugifyRealm(realm)
    if not realm then return nil end
    if not region then region = self:GetRegion() end

    return ParseFiendDB[region] and ParseFiendDB[region][realm] and ParseFiendDB[region][realm][name]
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

    -- Local-upvalue bind: the constant-folded loop is faster than repeated
    -- table lookups in a hot path called on every tooltip hover.
    local _sanitize = SanitizePP
    local _diffMul = ParseFiend.DIFFICULTIES_PER_BOSS

    local total = 0
    for bossIndex = 1, ParseFiend.BOSSES_PER_TIER do
        total = total + _sanitize(ppTable[(bossIndex - 1) * _diffMul + difficultyIndex])
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
    if #ppTable == 0 then return 0 end

    -- Hot path: numbers go through SanitizePP without tonumber. Two
    -- upvalues closed over to skip repeated table lookups inside the loop.
    local _sanitize = SanitizePP
    local n = #ppTable < ParseFiend.PP_CELL_COUNT and #ppTable or ParseFiend.PP_CELL_COUNT

    local total = 0
    for i = 1, n do
        total = total + _sanitize(ppTable[i])
    end
    return total
end

---Colour band for a parse-points *percent* (0‑100). The thresholds match
---the historical point‑based colour bands (1000 / 2000 / 3000 / 3800 / 3960
---out of 4000) expressed as percentages (25 % / 50 % / 75 % / 95 % / 99 %).
---Using percentages keeps the colour mapping tier‑agnostic and reusable for
---per‑difficulty aggregates (max 1000) and any future tier with a different
---max value.
---@param percent number
---@return string colour escape code (|cxxxxxxxxxx)
function ParseFiend:GetPPColor(percent)
    percent = tonumber(percent)
    if not percent or percent ~= percent then return self.Colors.GREY end

    if percent >= 100 then
        return self.Colors.GOLD
    elseif percent >= 99 then
        return self.Colors.PINK
    elseif percent >= 95 then
        return self.Colors.ORANGE
    elseif percent >= 75 then
        return self.Colors.PURPLE
    elseif percent >= 50 then
        return self.Colors.BLUE
    elseif percent >= 25 then
        return self.Colors.GREEN
    else
        return self.Colors.GREY
    end
end

---Round to nearest integer using "half up" rounding (0.5 -> 1, 1.5 -> 2,
----0.5 -> 0). Lua's built-in `string.format("%.0f", x)` uses platform
---banker's rounding on some runtimes which gives 0.5 -> 0; we want
---half-up so .5 always bumps to the next integer in the player-facing
---display. Only positive values are expected in practice (parse points
---are always >= 0) but the helper handles negatives the conventional way.
---@param x number
---@return integer
function ParseFiend:RoundHalfUp(x)
    x = tonumber(x)
    if not x or x ~= x then return 0 end
    if x >= 0 then
        return math.floor(x + 0.5)
    end
    -- Negative .5 rounds toward zero (i.e. up). Defensive only — not used.
    return -math.floor(-x + 0.5)
end

---Format a parse-points aggregate for player display:
---  * `value` – the sum of parse points to show (e.g. overall `totalPoints`
---    or a single difficulty `diffPoints`).
---  * `max`   – the maximum possible value for that aggregation (e.g. 4000
---    for the overall tier, 1000 per difficulty). Used only to compute the
---    percent that drives the colour band so the same colour ladder works
---    across any tier or metric.
---The display number is the rounded sum of points (half‑up) while the colour
---band is taken from the percent value (`100 * value / max`) which matches
---the existing colour thresholds (25 % grey, 50 % green, 75 % blue, 95 %
---purple, 99 % orange, 100 % gold, etc.).
---@param value number
---@param max number
---@return string|nil
function ParseFiend:FormatPP(value, max)
    value = tonumber(value)
    max = tonumber(max)
    if not value or value ~= value or value <= 0 then return nil end
    if not max or max ~= max or max <= 0 then return nil end

    local rounded = self:RoundHalfUp(value)
    if rounded <= 0 then return nil end

    local percent = (value / max) * 100
    local color = self:GetPPColor(percent) or self.Colors.GREY
    return color .. tostring(rounded) .. "|r"
end
