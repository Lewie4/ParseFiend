-- Parse Fiend database
--
-- Schema (region-aware, current tier only):
--
--   ParseFiendDB[region][realm][name] = {
--       updated = <unixTimestamp>,
--       pp      = { <num>, ... } -- exactly 40 entries; 0 (never killed) or positive number otherwise.
--   }
--
-- The 40 entries are stored per player in this order, repeating the pattern
--  [lfr, normal, heroic, mythic]  for each of the 10 bosses in the current
-- raid tier:
--
--   index  boss (1-based)  difficulty
--   ------   ---             ---
--      1       1              lfr
--      2       1              normal
--      3       1              heroic
--      4       1              mythic
--      5       2              lfr
--      6       2              normal
--      7       2              heroic
--      8       2              mythic
--    ...    ...             ...
--     37      10              lfr
--     38      10              normal
--     39      10              heroic
--     40      10              mythic
--
-- Region / realm / name use the canonical case returned by Blizzard's
-- GetNormalizedRealmName(). Keys are not lowercased on our side; trimming and
-- whitespace collapse happens in ParseFiend.NormalizeKey. Boss order is
-- implicit; the export pipeline that generates this file is expected to
-- honour it. Adjust ParseFiend.BOSSES_PER_TIER / DIFFICULTY_INDEX in
-- Util.lua when the tier changes.

ParseFiendDB = {
    ["EU"] = {
        ["Kazzak"] = {
            ["Kivral"] = {
                updated = 1752000000,
                pp = {
                    0, 0, 0, 50,   -- boss 1
                    0, 0, 0, 75,   -- boss 2
                    0, 0, 0, 33,   -- boss 3
                    0, 0, 0, 99,   -- boss 4
                    0, 0, 0, 50,   -- boss 5
                    0, 0, 0, 50,   -- boss 6
                    0, 0, 0, 25,   -- boss 7
                    0, 0, 0, 75,   -- boss 8
                    0, 0, 0, 33,   -- boss 9
                    0, 0, 0, 99,   -- boss 10
                },
            },
			["Stump"] = {
                updated = 1752000000,
                pp = {
                    0, 0, 0, 50,   -- boss 1
                    0, 0, 0, 75,   -- boss 2
                    0, 0, 0, 33,   -- boss 3
                    0, 0, 0, 99,   -- boss 4
                    0, 0, 0, 50,   -- boss 5
                    0, 0, 0, 50,   -- boss 6
                    0, 0, 0, 25,   -- boss 7
                    0, 0, 0, 75,   -- boss 8
                    0, 0, 0, 33,   -- boss 9
                    0, 0, 0, 99,   -- boss 10
                },
            },
        },
        ["Stormscale"] = {
            ["Dock"] = {
                updated = 1752000000,
                pp = {
                    100, 99, 99, 99,   -- boss 1
                    100, 100,  100,  99,   -- boss 2
                    100, 99,  99,  99,   -- boss 3
                    100, 99, 99, 99,   -- boss 4
                    100, 99,  99,  99,   -- boss 5
                    99,  99,  100,  100,   -- boss 6
                    99,  99,  99,  99,   -- boss 7
                    100, 99,  99,  94,   -- boss 8
                    100,  99,  98,  99,   -- boss 9
                    99, 99, 95, 95,   -- boss 10
                },
            },
        },
    },
}
