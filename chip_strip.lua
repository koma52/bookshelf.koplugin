-- chip_strip.lua
-- Two render modes:
--
--   1. Default (chips list): segmented control of N chips (Recent / Latest /
--      Series / ★ etc). Active chip inverts (black fill, paper text); tap
--      dispatches on_change(key).
--
--   2. Breadcrumb (drill-down): when `breadcrumb_path` is a non-empty array
--      of { label } records, the strip renders as a chip-shaped "pill" for
--      the current chip type followed by ">"-separated crumbs:
--
--         [Series] > Foundation > Asimov, Isaac
--
--      Tap dispatch:
--         * the chip pill         → on_breadcrumb(0)  (pop to top level)
--         * a crumb at index i    → on_breadcrumb(i)  (pop to that depth)
--
--      Truncation: when the assembled width would exceed self.width, older
--      crumbs are replaced from the left with a single "…" entry until it
--      fits, keeping the chip pill + (optionally) ellipsis + the deepest
--      crumb visible. Tapping the ellipsis is a no-op (resolves to the
--      first non-truncated crumb's depth in practice — but the deepest
--      crumb stays a clear target).
--
-- Border-butting approach (chips mode): chips are joined by giving each
-- chip (after the first) a padding_left = -Size.border.thin. If KOReader's
-- FrameContainer clamps negative padding to zero, the visual gap is a 1px
-- double-border rather than a seamless join — still readable.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local HorizontalGroup= require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextWidget     = require("ui/widget/textwidget")
local CenterContainer= require("ui/widget/container/centercontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")

local ChipStrip = InputContainer:extend{
    chips             = nil,   -- list of { key, label } (chips mode)
    active            = nil,   -- key of the currently-selected chip
    breadcrumb_path   = nil,   -- list of { label } — when non-empty, breadcrumb mode
    chip_pill_label   = nil,   -- label for the chip pill in breadcrumb mode (e.g. "Series")
    width             = nil,
    height            = nil,
    on_change         = nil,   -- function(key) — chips mode tap
    on_breadcrumb     = nil,   -- function(depth) — breadcrumb mode tap
}

-- Breadcrumb pill rendered as a black-outlined tag (white interior) with
-- an arrow tip on the right. The arrow doubles as the leading chevron —
-- no separate "›" needed after it. Sized to the label's text width plus a
-- small horizontal pad so a long chip name like "FAVOURITES" fits and a
-- short one like "RECENT" doesn't waste space. Outline (rather than
-- filled black) keeps the pill reading as clickable rather than as a
-- selected/active chip.
--
-- When `chained` is true the LEFT border is omitted so the pill connects
-- seamlessly with a preceding pill's arrow tip (no double black line at
-- the join). Returns (widget, total_w, tip_w) so the caller can lay out
-- adjacent pills and record the tap zone.
local function arrowPillFrame(label, h, chained)
    local label_text = (label or ""):upper()
    local face       = Font:getFace("infofont", 16)
    local tw = TextWidget:new{
        text    = label_text,
        face    = face,
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
    }
    local h_pad   = Size.padding.large
    local body_w  = tw:getSize().w + h_pad * 2
    local tip_w   = math.floor(h * 0.4)
    local total_w = body_w + tip_w
    local b       = Size.border.thin

    -- Custom shape painter: paint the outer (black) shape filled, then
    -- knock out an inner (white) shape inset by `b` pixels — leaves a
    -- uniform black outline. Body inner inset is on top, bottom and
    -- left only (right side is the body/tip junction, no border); the
    -- inner tip starts at the same junction so the body and tip
    -- interiors flow continuously and only the outer perimeter draws.
    local ArrowBg = Widget:extend{}
    function ArrowBg:init()
        self.dimen = Geom:new{ w = total_w, h = h }
    end
    function ArrowBg:paintTo(bb, x, y)
        local hh = (h - 1) / 2
        local BLACK = Blitbuffer.COLOR_BLACK
        local WHITE = Blitbuffer.COLOR_WHITE
        -- Outer filled black: body rect + tapered tip strips.
        bb:paintRect(x, y, body_w, h, BLACK)
        for dy = 0, h - 1 do
            local from_center = math.abs(dy - hh)
            local row_w = math.max(0, math.floor(tip_w * (1 - from_center / hh)))
            if row_w > 0 then
                bb:paintRect(x + body_w, y + dy, row_w, 1, BLACK)
            end
        end
        -- Inner filled white (inset by `b`): body shrunk on top/bottom
        -- and (unless chained) left; tip shrunk by ~2*b in width so the
        -- slope's outline reads roughly uniform thickness. When chained,
        -- the left edge has no border — the previous pill's arrow tip
        -- meets pure white interior here.
        local inner_h = h - 2 * b
        if inner_h <= 0 then return end
        local inner_hh    = (inner_h - 1) / 2
        local left_inset  = chained and 0 or b
        local inner_body_w = body_w - left_inset
        if inner_body_w > 0 then
            bb:paintRect(x + left_inset, y + b, inner_body_w, inner_h, WHITE)
        end
        local inner_tip_w = tip_w - 2 * b
        if inner_tip_w > 0 then
            for dy = 0, inner_h - 1 do
                local from_center = math.abs(dy - inner_hh)
                local row_w = math.max(0, math.floor(inner_tip_w * (1 - from_center / inner_hh)))
                if row_w > 0 then
                    bb:paintRect(x + body_w, y + b + dy, row_w, 1, WHITE)
                end
            end
        end
    end

    local pill = OverlapGroup:new{
        dimen = Geom:new{ w = total_w, h = h },
        ArrowBg:new{},
        CenterContainer:new{
            dimen = Geom:new{ w = body_w, h = h },
            tw,
        },
    }
    return pill, total_w, tip_w
end

function ChipStrip:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    if self.breadcrumb_path and #self.breadcrumb_path > 0 then
        self:_initBreadcrumb()
    elseif self.chips and #self.chips > 0 then
        self:_initChips()
    else
        self[1] = require("ui/widget/widget"):new{ dimen = self.dimen }
    end
    self.ges_events = {
        TapStrip = { GestureRange:new{ ges = "tap", range = self.dimen } },
    }
end

-- ─── Default chips mode ─────────────────────────────────────────────────────

function ChipStrip:_initChips()
    local n = #self.chips
    local row = HorizontalGroup:new{}
    self._chip_dimens = {}

    local paper       = Blitbuffer.COLOR_WHITE
    local LineWidget  = require("ui/widget/linewidget")
    local separator_w = Size.border.thin
    local sep_total   = separator_w * (n - 1)
    local cell_w      = (self.width - sep_total) / n

    for i, chip in ipairs(self.chips) do
        if i > 1 then
            row[#row + 1] = LineWidget:new{
                background = Blitbuffer.COLOR_BLACK,
                dimen = Geom:new{ w = separator_w, h = self.height },
            }
        end
        local is_active = (chip.key == self.active)
        local w = (i == n) and (self.width - sep_total - math.floor(cell_w) * (n - 1))
                 or math.floor(cell_w)
        row[#row + 1] = FrameContainer:new{
            bordersize = 0,
            margin     = 0,
            padding    = 0,
            background = is_active and Blitbuffer.COLOR_BLACK or paper,
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = self.height },
                TextWidget:new{
                    text      = (chip.label or ""):upper(),
                    face      = Font:getFace("infofont", 16),
                    bold      = true,
                    fgcolor   = is_active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                    -- Truncate with ellipsis at extreme DPI / font scale
                    -- rather than letting "FAVOURITES" overflow into the
                    -- adjacent chip's cell. Some inner padding (Size.
                    -- padding.small per side) keeps the text from
                    -- touching the chip border.
                    max_width = w - 2 * Size.padding.small,
                },
            },
        }
        local prev = self._chip_dimens[self.chips[i - 1] and self.chips[i - 1].key]
        local x = prev and (prev.x + prev.w + separator_w) or 0
        self._chip_dimens[chip.key] = { x = x, w = w }
    end
    self[1] = FrameContainer:new{
        bordersize = Size.border.thin,
        margin     = 0,
        padding    = 0,
        row,
    }
end

-- ─── Breadcrumb mode ────────────────────────────────────────────────────────
--
-- Layout: [chip_pill] > crumb1 > crumb2 > … > crumbN
--
-- Pill has the same metrics as a normal chip cell (single-chip width).
-- Crumbs render with a chevron separator. We track each tappable region's
-- x-range in self._breadcrumb_zones (which the unified TapStrip handler
-- resolves) so the existing tap pipeline keeps working in both modes.

function ChipStrip:_initBreadcrumb()
    -- Layout: chip pill + (parent crumbs as CHAINED arrow pills, no
    -- gaps) + small gap + the deepest crumb as PLAIN TEXT (the
    -- current/active folder isn't a tap target — you're already
    -- there). Chip pill keeps its left border; subsequent pills are
    -- "chained" (no left border) so the previous tip meets pure white
    -- interior, joining the chain visually.
    local face_text = Font:getFace("infofont", 16)
    local n         = #self.breadcrumb_path

    -- Chip pill at depth 0 (e.g. "HOME") — full border (chained=false).
    local pill, pill_w, pill_tip_w = arrowPillFrame(self.chip_pill_label or "", self.height, false)

    -- Build chained pills for parent entries (1..n-1), skipping the
    -- deepest. Strip a trailing "/" defensively.
    local crumb_pills = {}
    for i = 1, n - 1 do
        local label = (self.breadcrumb_path[i].label or ""):gsub("/$", "")
        local cp_widget, cp_w, cp_tip_w = arrowPillFrame(label, self.height, true)
        crumb_pills[#crumb_pills + 1] = {
            widget = cp_widget,
            width  = cp_w,
            tip_w  = cp_tip_w,
            depth  = i,
        }
    end

    -- Plain-text widget for the deepest crumb (the current folder).
    local deepest_widget, deepest_w
    if n >= 1 then
        local deepest_label = (self.breadcrumb_path[n].label or ""):gsub("/$", "")
        deepest_widget = TextWidget:new{
            text    = deepest_label,
            face    = face_text,
            bold    = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
        deepest_w = deepest_widget:getSize().w
    end

    -- Layout: pills connect with no gap; small gap before plain text.
    local function build(visible_crumbs)
        local row    = HorizontalGroup:new{ pill }
        local zones  = { { x = 0, w = pill_w, depth = 0 } }
        local cursor = pill_w
        for _, cp in ipairs(visible_crumbs) do
            row[#row + 1] = cp.widget
            zones[#zones + 1] = { x = cursor, w = cp.width, depth = cp.depth }
            cursor = cursor + cp.width
        end
        if deepest_widget then
            local gap_w = pill_tip_w
            row[#row + 1] = HorizontalSpan:new{ width = gap_w }
            cursor = cursor + gap_w
            row[#row + 1] = deepest_widget
            cursor = cursor + deepest_w
            -- No tap zone for the current/active crumb — you're already there.
        end
        return row, zones, cursor
    end

    -- Truncate from the front (drop earliest parent pills) until the
    -- chain fits the strip's width. The chip pill + the deepest crumb
    -- always survive (chip = depth 0, deepest = current folder).
    local visible = crumb_pills
    local row, zones, total_w = build(visible)
    while total_w > self.width and #visible > 0 do
        table.remove(visible, 1)
        row, zones, total_w = build(visible)
    end

    self._breadcrumb_zones = zones
    self[1] = row
end

-- ─── Unified tap dispatch ───────────────────────────────────────────────────

function ChipStrip:onTapStrip(_, ges)
    local x = ges.pos.x - self.dimen.x
    if self._breadcrumb_zones then
        for _, zone in ipairs(self._breadcrumb_zones) do
            if x >= zone.x and x < zone.x + zone.w then
                if self.on_breadcrumb then self.on_breadcrumb(zone.depth) end
                return true
            end
        end
        return false
    end
    -- Chips mode
    if self._chip_dimens then
        for _, chip in ipairs(self.chips) do
            local d = self._chip_dimens[chip.key]
            if d and x >= d.x and x < d.x + d.w then
                if self.on_change and chip.key ~= self.active then
                    self.on_change(chip.key)
                end
                return true
            end
        end
    end
    return false
end

return ChipStrip
