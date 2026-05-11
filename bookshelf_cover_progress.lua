-- bookshelf_cover_progress.lua
-- Pure decision logic for per-book progress indicators (bar + glyphs).
--
-- decide(book) maps a book's KOReader sidecar status + percent to a render
-- intent: whether to draw a top-edge progress bar, what fill ratio, and
-- which (if any) status glyph to overlay. Master toggle from
-- G_reader_settings["bookshelf_progress_enabled"].
--
-- Widget builders (buildBarWidget, buildGlyphWidget) live in this file
-- alongside the decision logic so SpineWidget has a single require to
-- pull in everything it needs.

local M = {}

-- Glyph code points (KOReader's bundled nerd font).
M.GLYPH_BOOKMARK       = "\u{e7bf}"  -- in-progress
M.GLYPH_BOOKMARK_CHECK = "\u{e7c0}"  -- finished

-- Read the master toggle. Default true (feature on) when unset.
local function _enabled()
    local v = G_reader_settings:readSetting("bookshelf_progress_enabled")
    if v == nil then return true end
    return v == true
end

-- Pure decision.
-- @param book table|nil with keys `status` (string|nil) and `book_pct` (number|nil)
-- @return table { bar=bool, bar_pct=number, glyph="in_progress"|"complete"|nil }
function M.decide(book)
    local none = { bar = false, bar_pct = 0, glyph = nil }
    if not _enabled()  then return none end
    if not book        then return none end
    local status = book.status
    local pct    = book.book_pct
    if status == "reading" then
        return { bar = (pct ~= nil), bar_pct = pct or 0, glyph = "in_progress" }
    elseif status == "complete" then
        return { bar = false, bar_pct = 0, glyph = "complete" }
    elseif status == "abandoned" then
        return { bar = (pct ~= nil), bar_pct = pct or 0, glyph = "in_progress" }
    end
    -- status = "new" or nil: nothing.
    return none
end

return M
