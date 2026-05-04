-- hero_line_editor.lua
-- Per-region line editor for the hero card. Live preview is driven by
-- an in-memory `draft` table — settings are NOT written on every edit
-- (that would flush to disk on every keystroke and chew Kindle flash).
-- Settings are persisted only on Save; Cancel restores from the
-- entry-time snapshot as a safety net in case anything else wrote.

local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local Regions     = require("hero_regions")
local _           = require("bookshelf_i18n").gettext

local LineEditor = {}

-- show(region_key, bw, settings_module)
--   region_key      — one of Regions.ORDER
--   bw              — live BookshelfWidget (live preview target). May be nil.
--   settings_module — Settings handle (for the token picker fallback path).
function LineEditor.show(region_key, bw, settings_module)
    local snapshot = Regions.snapshot(region_key)
    local current  = Regions.read()[region_key]

    -- In-memory draft. Mutated on every keystroke / button tap; written
    -- to settings only on Save.
    local draft = {
        template  = current.template,
        font_face = current.font_face,
        font_size = current.font_size,
        bold      = current.bold,
        uppercase = current.uppercase,
        alignment = current.alignment,
        bar_height= current.bar_height,
        bar_style = current.bar_style,
    }

    local dialog

    -- Build a fully-populated regions table for the renderer: the four
    -- inactive regions come from Regions.read() (i.e. stored values), the
    -- active region is the current draft. No settings write happens here.
    local function previewRegions()
        local regions = Regions.read()
        regions[region_key] = draft
        return regions
    end

    local function applyLivePreview()
        if bw and bw._swapHeroRightColumnInPlace then
            bw:_swapHeroRightColumnInPlace(previewRegions())
        end
    end

    local function commitText()
        local text = dialog and dialog:getInputText() or draft.template
        draft.template = text or ""
    end

    local function buildButtons()
        local rows = {}
        -- Action row (Style/Bar rows added in later tasks)
        rows[#rows + 1] = {
            {
                text     = _("Cancel"),
                id       = "close",
                callback = function()
                    -- Safety net: even though we never wrote during the
                    -- session, restore the snapshot in case something else
                    -- did. Then repaint with the now-stored values.
                    Regions.restore(region_key, snapshot)
                    if bw and bw._swapHeroRightColumnInPlace then
                        bw:_swapHeroRightColumnInPlace(Regions.read())
                    end
                    UIManager:close(dialog)
                end,
            },
            {
                text     = _("Tokens\xE2\x80\xA6"),
                callback = function()
                    if settings_module and settings_module._pickToken then
                        settings_module:_pickToken(dialog)
                    end
                end,
            },
            {
                text     = _("Default"),
                callback = function()
                    local d = Regions.DEFAULTS[region_key]
                    draft.template  = d.template
                    draft.font_face = d.font_face
                    draft.font_size = d.font_size
                    draft.bold      = d.bold
                    draft.uppercase = d.uppercase
                    draft.alignment = d.alignment
                    draft.bar_height= d.bar_height
                    draft.bar_style = d.bar_style
                    if dialog and dialog.setInputText then
                        dialog:setInputText(d.template)
                    end
                    applyLivePreview()
                end,
            },
            {
                text             = _("Save"),
                is_enter_default = true,
                callback         = function()
                    commitText()
                    Regions.write(region_key, draft)
                    UIManager:close(dialog)
                end,
            },
        }
        return rows
    end

    dialog = InputDialog:new{
        title           = _(Regions.LABELS[region_key] or region_key),
        input           = draft.template,
        allow_newline   = true,
        edited_callback = function()
            local live = dialog:getInputText()
            if live ~= nil then
                draft.template = live
                applyLivePreview()
            end
        end,
        buttons = buildButtons(),
    }
    UIManager:show(dialog)
end

return LineEditor
