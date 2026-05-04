-- cover_loader.lua
-- N-slot LRU of HIGH-RESOLUTION cover bbs for the hero card.
--
-- Why this exists: BookInfoManager caches a downscaled THUMBNAIL (sized
-- for the largest shelf cell that ever indexed the file). Painting that
-- thumbnail at hero size requires an UPSCALE in RenderImage:scaleBlitBuffer,
-- which corrupts on Kindle (horizontal-stripe static). By opening the
-- document fresh and asking it for its publisher cover, we get a bb at
-- native resolution (typically 600×900+), so every render becomes a
-- DOWNSCALE — the safe direction.
--
-- Multi-slot rationale: the hero often hosts a back-and-forth between two
-- or three recently-previewed books (tap shelf cover A → B → A). With a
-- single slot, A reloaded from disk every time (~100–500 ms for fat EPUBs).
-- An LRU keyed by filepath makes recently-previewed books re-hero instantly.
--
-- Lifetime: the cache OWNS each bb — it is NOT in BookInfoManager's cache
-- and won't be freed by anyone else. Pass it to ImageWidget with
-- image_disposable = false. Eviction frees the bb via bb:free() (FFI
-- finalizer cleared, memory released immediately). clear() drops everything.

local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
local logger              = require("logger")

local CoverLoader = {
    _capacity = 4,     -- ~4 MiB at typical 600×900 grayscale bbs
    _cache    = {},    -- filepath → bb
    _order    = {},    -- list of filepaths, oldest at front, MRU at back
}

function CoverLoader:_removeKey(filepath)
    for i, p in ipairs(self._order) do
        if p == filepath then
            table.remove(self._order, i)
            return
        end
    end
end

function CoverLoader:_evictIfNeeded()
    while #self._order > self._capacity do
        local fp = table.remove(self._order, 1)
        local bb = self._cache[fp]
        self._cache[fp] = nil
        if bb and bb.free then pcall(function() bb:free() end) end
    end
end

-- get(filepath) — returns a high-res cover bb, or nil on failure. Hits
-- are cheap (LRU promotion); misses open the document fresh and may take
-- 100–500 ms on fat EPUBs.
function CoverLoader:get(filepath)
    if not filepath or filepath == "" then return nil end

    local cached = self._cache[filepath]
    if cached then
        self:_removeKey(filepath)
        self._order[#self._order + 1] = filepath
        return cached
    end

    -- FileManagerBookInfo:getCoverImage(document, file) — passing nil for
    -- document forces it to open `file` fresh (do_open=true), grab the
    -- publisher cover via doc:getCoverPageImage(), close the document,
    -- and return the bb. The function doesn't actually use `self`, so the
    -- method-call form is purely for symmetry with how coverimage.koplugin
    -- invokes it.
    local ok, bb = pcall(FileManagerBookInfo.getCoverImage,
                         FileManagerBookInfo, nil, filepath)
    if not ok or not bb then
        logger.info("[bookshelf] high-res cover load failed for "
                    .. tostring(filepath)
                    .. (ok and "" or (": " .. tostring(bb))))
        return nil
    end

    self._cache[filepath] = bb
    self._order[#self._order + 1] = filepath
    self:_evictIfNeeded()
    return bb
end

-- clear — drop everything. Call from plugin teardown if you want the
-- session's cache memory back before KOReader exits.
function CoverLoader:clear()
    for _, bb in pairs(self._cache) do
        if bb and bb.free then pcall(function() bb:free() end) end
    end
    self._cache = {}
    self._order = {}
end

return CoverLoader
