-- tests/_test_tokens.lua
-- Pure-Lua test runner. No KOReader dependencies.
-- Usage: cd into the plugin dir, then `lua tests/_test_tokens.lua`.

package.loaded["device"] = {
    getPowerDevice = function() return nil end,
    isKindle = function() return false end,
    hasNaturalLight = function() return false end,
    home_dir = "/",
}
package.loaded["datetime"] = {
    secondsToClockDuration = function(s)
        if not s or s <= 0 then return "" end
        local h = math.floor(s / 3600)
        local m = math.floor((s % 3600) / 60)
        return string.format("%dh %02dm", h, m)
    end,
}
package.loaded["bookshelf_i18n"] = {
    gettext = function(t) return t end,
    ngettext = function(s, p, n) return n == 1 and s or p end,
}
_G.G_reader_settings = setmetatable({}, {
    readSetting = function() return nil end,
    isTrue = function() return false end,
    __index = function() return function() return false end end,
})

local Tokens = dofile("tokens.lua")

local pass, fail = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1
    else fail = fail + 1; io.stderr:write("FAIL  " .. name .. "\n  " .. tostring(err) .. "\n") end
end
local function eq(a, e, msg)
    if a ~= e then error((msg or "") .. " expected=" .. tostring(e) .. " got=" .. tostring(a), 2) end
end

-- ============================================================================
test("smoke: Tokens module loads", function()
    assert(type(Tokens) == "table", "Tokens is not a table")
    assert(type(Tokens.expand) == "function", "Tokens.expand missing")
end)

io.write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail == 0 and 0 or 1)
