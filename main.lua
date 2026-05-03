-- main.lua
-- Plugin entry point. Registers start_with=bookshelf, hooks close-document,
-- and takes over the home screen on launch when configured to do so.
--
-- KOReader API notes (verified against KOReader source):
--
--   * FileManagerMenu.menu_items is an *instance* attribute built lazily in
--     setUpdateItemTable(), which is called the first time the menu opens.
--     The class table itself has no menu_items — so we cannot patch it via
--     FMMenu.menu_items at init time.
--
--   * The start_with sub_item_table is constructed inside
--     FileManagerMenu:getStartWithMenuTable() and assigned to
--     self.menu_items.start_with only *after* addToMainMenu callbacks have
--     already fired (addToMainMenu runs at line ~458, start_with is set at
--     line ~491 in filemanagermenu.lua).
--
--   * Therefore we monkey-patch FileManagerMenu.getStartWithMenuTable at the
--     *class* level so that every instance builds the table with our entry
--     already included. The patch is idempotent (duplicate-guard on "bookshelf").
--
--   * onCloseDocument is dispatched via ReaderUI:handleEvent(Event:new(
--     "CloseDocument")) which propagates to all registered child widgets
--     (plugins are inserted via registerModule → table.insert(self, ...)). So
--     defining Bookshelf:onCloseDocument() is sufficient — no manual subscribe
--     needed.
--
--   * is_doc_only = false — plugin loads in both FileManager and Reader contexts,
--     which is required so the close-document hook fires inside the Reader.

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local logger          = require("logger")
local _               = require("bookshelf_i18n").gettext

local Bookshelf = WidgetContainer:extend{
    name        = "bookshelf",
    is_doc_only = false, -- must be false: hook fires in Reader context
}

-- ---------------------------------------------------------------------------
-- init
-- ---------------------------------------------------------------------------

function Bookshelf:init()
    -- Patch the start_with menu so users can pick Bookshelf as their home.
    self:_registerStartWithMenu()

    -- Register "Open Bookshelf" in the main menu (works in both FM and Reader).
    self.ui.menu:registerToMainMenu(self)

    -- Takeover: if start_with=bookshelf and we're in the FileManager context
    -- (no document currently being opened), close FM and present Bookshelf.
    if G_reader_settings:readSetting("start_with") == "bookshelf"
            and not (self.ui and self.ui.document) then
        UIManager:nextTick(function() self:_takeOver() end)
    end
end

-- ---------------------------------------------------------------------------
-- Start-with menu registration
-- ---------------------------------------------------------------------------

function Bookshelf:_registerStartWithMenu()
    -- Monkey-patch FileManagerMenu.getStartWithMenuTable at the class level.
    -- This is the only reliable way to inject into the lazy-built start_with
    -- sub_item_table (see API notes at top of file).
    local ok, FMMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FMMenu then
        logger.dbg("[bookshelf] FileManagerMenu not available; skipping start_with registration")
        return
    end

    local orig_fn = FMMenu.getStartWithMenuTable
    if type(orig_fn) ~= "function" then
        logger.dbg("[bookshelf] getStartWithMenuTable not found; skipping start_with registration")
        return
    end

    -- Wrap once — idempotent across multiple plugin init() calls.
    if FMMenu._bookshelf_patched then return end
    FMMenu._bookshelf_patched = true

    FMMenu.getStartWithMenuTable = function(self_fm)
        local result = orig_fn(self_fm)
        -- result = { text_func = ..., sub_item_table = {...} }
        if type(result) ~= "table" or type(result.sub_item_table) ~= "table" then
            return result
        end

        -- Duplicate guard (safety net in case patch fires more than once).
        for _, entry in ipairs(result.sub_item_table) do
            if entry.text == _("Bookshelf") then return result end
        end

        table.insert(result.sub_item_table, {
            text    = _("Bookshelf"),
            radio   = true,
            checked_func = function()
                return G_reader_settings:readSetting("start_with") == "bookshelf"
            end,
            callback = function()
                G_reader_settings:saveSetting("start_with", "bookshelf")
            end,
        })
        return result
    end
end

-- ---------------------------------------------------------------------------
-- Main menu entry
-- ---------------------------------------------------------------------------

function Bookshelf:addToMainMenu(menu_items)
    menu_items.bookshelf = {
        text         = _("Open Bookshelf"),
        sorting_hint = "more_tools",
        callback     = function() self:show() end,
    }
end

-- ---------------------------------------------------------------------------
-- Show / takeover
-- ---------------------------------------------------------------------------

function Bookshelf:show()
    local BookshelfWidget = require("bookshelf_widget")
    UIManager:show(BookshelfWidget:new{})
end

function Bookshelf:_takeOver()
    -- Close FileManager if it was the boot path, then show Bookshelf.
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and FileManager.instance then
        UIManager:close(FileManager.instance)
    end
    self:show()
end

-- ---------------------------------------------------------------------------
-- Close-document hook
-- ---------------------------------------------------------------------------

function Bookshelf:onCloseDocument()
    -- Re-home to Bookshelf when a book closes, if it is the configured home.
    if G_reader_settings:readSetting("start_with") == "bookshelf" then
        UIManager:nextTick(function() self:show() end)
    end
end

return Bookshelf
