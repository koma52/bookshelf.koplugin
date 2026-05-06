-- folder_stack.lua
-- Renders a folder-as-magazine-file: the first book inside the folder peeks
-- out the top of a manilla cardboard "magazine file" shape; the folder name
-- sits centred on the cardboard's front face. Drop-shadowed to match the
-- depth of regular spine widgets.
--
-- Visual composition (back-to-front):
--   1. Magazine drop shadow — the magazine's polygon shape filled in
--      shadow-grey at SHADOW_OFFSET down+right of the card. Visible as an
--      L-shaped halo on the right and bottom edges of the magazine, and a
--      thinner band tracing the slope on its underside.
--   2. First-book cover (rendered via SpineWidget) inset slightly inside
--      the card so the cardboard's side walls visually wrap the book.
--   3. Magazine front: a filled cardboard polygon with a sloped top edge.
--      The slope rises on the LEFT (high y on right, low y on left → the
--      slope drops as the eye moves rightward, matching the reference
--      photo's open-mouth orientation). Below the slope: cardboard fill
--      to the bottom edge.
--   4. Folder name centred horizontally and vertically on the cardboard
--      (TextBoxWidget with bgcolor = CARDBOARD so its rendering matches
--      the surrounding fill rather than knocking out a white rectangle).
--
-- All shapes paint into an OverlapGroup at slot dimen so the whole stack
-- has the same getSize() / tap zone as a regular SpineWidget — drop-in
-- replacement at the ShelfRow slot level.

local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local CenterContainer= require("ui/widget/container/centercontainer")
local TopContainer   = require("ui/widget/container/topcontainer")
local TextWidget     = require("ui/widget/textwidget")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local Widget         = require("ui/widget/widget")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local Size           = require("ui/size")
local Font           = require("ui/font")
local Blitbuffer     = require("ffi/blitbuffer")
local Screen         = require("device").screen
local SpineWidget    = require("spine_widget")

-- The magazine front is a triangle sitting on a rectangle (one
-- composite quadrilateral): a gentle slope across the TOP carries the
-- triangle "opening" of the file, and a full-width rectangle below
-- holds the folder label. Slope falls left-to-right (back wall on
-- LEFT, slightly shorter front wall on RIGHT).
--   y at x=0 is SLOPE_LEFT_FRAC·card_h
--   y at x=w-1 is SLOPE_RIGHT_FRAC·card_h
-- Below max(SLOPE_LEFT_FRAC, SLOPE_RIGHT_FRAC) the cardboard is
-- full-width — that's the "rectangle" where the label lives.
-- Slope position. Earlier values (0.67/0.73) made the rectangle portion
-- too short for folder names like "Southern Reach" to wrap to two lines —
-- they fell back to single-line ellipsis. Lowered to 0.60/0.66 so the
-- rectangle now fits two lines of bold-16 with breathing room, while still
-- leaving substantial book peek above (book pokes up further than the
-- pre-1/3-shorter 0.50/0.60 baseline since the slope is slightly higher).
local SLOPE_LEFT_FRAC  = 0.60
local SLOPE_RIGHT_FRAC = 0.66

-- Cardboard colour. Dispatched on Screen:isColorEnabled at module-load time
-- so colour devices (Kaleido panels, SDL desktop) get a real manilla hue.
-- On B&W e-ink we set a grayscale value directly so dithering stays
-- predictable. Edge is COLOR_BLACK on both branches — matches the book
-- spine border weight + colour exactly so adjacent magazines and books on
-- the same shelf read as a unified shelf row, not two visual languages.
local CARDBOARD
if Screen.isColorEnabled and Screen:isColorEnabled() then
    CARDBOARD = Blitbuffer.colorFromString("#e7c9a9")
else
    CARDBOARD = Blitbuffer.gray(0.20)
end
local CARDBOARD_EDGE  = Blitbuffer.COLOR_BLACK

-- Drop-shadow geometry — must match SpineWidget so book and magazine spines
-- on the same shelf cast shadows the same depth. The previous folder render
-- skipped the shadow (the comment cited it making the shape look 1-D); user
-- now wants it back to align with the book-cover treatment.
local SHADOW_OFFSET   = Screen:scaleBySize(4)
local SHADOW_GRAY     = Blitbuffer.gray(0.5)

-- Border thickness — matches SpineWidget's CARD_BORDER (Screen:scaleBySize(1))
-- so book covers and magazine outlines on the same shelf have visually
-- equivalent stroke weight. Size.border.thin (the previous value) is a
-- non-scaled 1px and was visibly thinner than the books on hidpi displays.
local CARD_BORDER     = Screen:scaleBySize(1)

-- Bottom-corner rounding (matches SpineWidget's CARD_RADIUS so adjacent
-- magazine and book spines on the same shelf have consistent corner
-- treatment). The TOP corners are kept angular — they're slope/wall
-- junctions, sharp by design in a real magazine file.
local CARD_RADIUS = Screen:scaleBySize(4)

-- Book inset in absolute pixels. Just enough that a thin band of
-- cardboard wraps the book on each side and the top — the book "barely
-- fits inside" the file rather than shrinking visibly inside it.
local BOOK_INSET_X = Screen:scaleBySize(3)
local BOOK_INSET_Y = Screen:scaleBySize(2)

-- Painter for the magazine front: a quadrilateral with a sloped top
-- edge. The slope drops gently from (0, y_left) on the left to
-- (w-1, y_right) on the right (y_left < y_right ⇒ slope falls L→R).
-- Below max(y_left, y_right) the shape is full-width — the
-- "rectangle" portion that carries the folder label. Above the
-- slope, no fill (the book behind shows through). Bottom-left and
-- bottom-right corners are rounded at `radius`.
local MagazinePolygon = Widget:extend{
    width      = nil,
    height     = nil,
    y_left     = nil,    -- slope y at x=0
    y_right    = nil,    -- slope y at x=w-1
    fill_color = nil,
    edge_color = nil,
    radius     = 0,
}

function MagazinePolygon:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function MagazinePolygon:paintTo(bb, x, y)
    local w     = self.width
    local h     = self.height
    local yl    = self.y_left
    local yr    = self.y_right
    local fill  = self.fill_color
    local r     = self.radius or 0
    local r_sq  = r * r
    local y_min = math.min(yl, yr)
    local y_max = math.max(yl, yr)
    local fall_lr = (yl <= yr)

    -- Use paintRectRGB32 unconditionally for the fill. paintRect strips
    -- ColorRGB→Color8 via getColor8() before fill (blitbuffer.lua:1677),
    -- so a manilla ColorRGB32 lands on the framebuffer as the equivalent
    -- grayscale value — the body renders silver instead of tan.
    -- paintRectRGB32 calls color:getColorRGB32() first, which all Color
    -- types implement (Color8 returns the grayscale value as r=g=b), so
    -- this works equally for the cardboard fill (RGB hue preserved) and
    -- the shadow (Color8 grayscale, coerces cleanly).
    --
    -- Note: can't sniff `fill.r` to dispatch — Color8 is an FFI struct,
    -- and accessing a missing field on a C struct hard-errors instead of
    -- returning nil. Cheaper to just always go through the RGB path.
    local function fillRect(rx, ry, rw, rh)
        bb:paintRectRGB32(rx, ry, rw, rh, fill)
    end

    -- rowExtent(dy) → (left, right) for the rounded BOTTOM corners.
    -- The corner arc is centred at (r, h-r) with radius r; for row dy in
    -- the corner band, the leftmost in-shape x is r - sqrt(r² - i²) where
    -- i = dy - (h-r) is the y-distance from the corner centre. Squared
    -- distance i_sq = (i+1)² (we use i+1 to bias toward the inclusive
    -- pixel on the boundary). At i=0 (top of band, i_sq=1) cutoff ≈ 0;
    -- at i=r-1 (bottom row, i_sq=r²) cutoff ≈ r. Earlier code had this
    -- inverted, which painted nothing at the top of the corner band and
    -- everything at the bottom — the body's bottom edge looked detached
    -- from the cardboard, with a "shadow bar" gap between.
    local function rowExtent(dy)
        if r > 0 and dy >= h - r then
            local i     = dy - (h - r)
            local i_sq  = (i + 1) * (i + 1)
            local cutoff = 0
            while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                cutoff = cutoff + 1
            end
            return cutoff, w - cutoff
        end
        return 0, w
    end

    -- Rectangle portion above the corner-clip band: one bulk fillRect.
    local rect_top         = y_max
    local rect_full_bottom = h - 1 - (r > 0 and r or 0)
    if rect_full_bottom >= rect_top then
        fillRect(x, y + rect_top, w, rect_full_bottom - rect_top + 1)
    end
    -- Bottom rounded-corner band: row-by-row with extent clipping. Don't
    -- paint outside the rounded area (no PAGE_BG knockout) — preserves
    -- whatever's underneath (shadow fill or page bg) and lets the shape's
    -- silhouette emerge from the absence.
    if r > 0 then
        for dy = math.max(rect_top, h - r), h - 1 do
            local row_left, row_right = rowExtent(dy)
            if row_right > row_left then
                fillRect(x + row_left, y + dy, row_right - row_left, 1)
            end
        end
    end
    -- Slope band (between y_min and y_max): per-row triangular fill.
    -- The cardboard's left edge IS the visible slope — drawing a separate
    -- slope-edge line on a shallow slope (~6% of card_h) accumulates as a
    -- horizontal "lip" at the top-left, since each row holds the slope
    -- for many x-pixels before stepping. Letting the fill define the
    -- slope sidesteps that aliasing.
    for dy = y_min, y_max - 1 do
        local frac    = (dy - yl) / (yr - yl)
        local x_slope = math.floor((w - 1) * frac + 0.5)
        if x_slope < 0 then x_slope = 0 end
        if x_slope > w - 1 then x_slope = w - 1 end
        if fall_lr then
            if x_slope > 0 then
                fillRect(x, y + dy, x_slope, 1)
            end
        else
            if x_slope < w then
                fillRect(x + x_slope, y + dy, w - x_slope, 1)
            end
        end
    end

    if self.edge_color then
        local b    = CARD_BORDER
        local edge = self.edge_color
        -- Bottom edge (between the rounded corners — same x-extent as
        -- the rect's full-width fill).
        bb:paintRect(x + r, y + h - b, w - 2 * r, b, edge)
        -- Side walls from where the slope MEETS each side down to the
        -- rounded bottom corner.
        local right_h = h - yr - r
        if right_h > 0 then
            bb:paintRect(x + w - b, y + yr, b, right_h, edge)
        end
        local left_h = h - yl - r
        if left_h > 0 then
            bb:paintRect(x, y + yl, b, left_h, edge)
        end
        -- Slope edge: one pixel per x column, following the slope line.
        -- Single-pixel stepping (vs the previous bxb blocks) keeps the
        -- shallow ~6%-grad slope from accumulating a horizontal "lip" at
        -- the top-left, while still tracing the full diagonal from the
        -- left wall's top to the right wall's top.
        for dx = 0, w - 1 do
            local frac = dx / (w - 1)
            local py   = math.floor(yl + (yr - yl) * frac + 0.5)
            bb:paintRect(x + dx, y + py, 1, b, edge)
        end
        -- Rounded corner edge pixels — one edge dot per row at the
        -- cutoff boundary, traced via the same i_sq=(i+1)² formula as
        -- the rowExtent fill so the edge sits ON the silhouette.
        if r > 0 then
            for i = 0, r - 1 do
                local dy   = h - r + i
                local i_sq = (i + 1) * (i + 1)
                local cutoff = 0
                while cutoff < r and (r - cutoff) * (r - cutoff) + i_sq > r_sq do
                    cutoff = cutoff + 1
                end
                bb:paintRect(x + cutoff, y + dy, b, b, edge)
                bb:paintRect(x + w - cutoff - b, y + dy, b, b, edge)
            end
        end
    end
end

-- A small filled right triangle painted at the magazine's top-right corner
-- to bridge the drop shadow to the slope endpoint. Without it, the visible
-- shadow strip starts SHADOW_OFFSET pixels below the slope's right end and
-- reads as a "step" detached from the magazine; the triangle continues the
-- slope diagonal into the shadow region so the eye reads the whole shadow
-- as a single connected silhouette.
--
-- Positioned at (card_w, yr) in OverlapGroup coords; size = SHADOW_OFFSET.
-- Hypotenuse runs from the top-left corner (where the magazine's slope
-- ends) to the bottom-right corner (where the shadow's slope endpoint
-- offset lands). Fill is the BELOW-LEFT half of the box (right angle at
-- bottom-left), since that's the area the slope-extension cuts off from
-- the shadow's reach.
local SlopeShadowBridge = Widget:extend{
    size  = nil,
    color = nil,
}
function SlopeShadowBridge:init()
    self.dimen = Geom:new{ w = self.size, h = self.size }
end
function SlopeShadowBridge:paintTo(bb, x, y)
    for dy = 0, self.size - 1 do
        local row_w = dy + 1
        bb:paintRect(x, y + dy, row_w, 1, self.color)
    end
end

local FolderStack = InputContainer:extend{
    folder      = nil,    -- { path, label, first_book }
    width       = nil,
    height      = nil,
    on_tap      = nil,
    on_hold     = nil,
    is_selected = false,
}

function FolderStack:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    -- Reserve SHADOW_OFFSET pixels at right and bottom for the drop shadow
    -- (matches SpineWidget's allocation so books and magazines line up).
    local card_w = self.width  - SHADOW_OFFSET
    local card_h = self.height - SHADOW_OFFSET

    -- Slope endpoints in card-local coordinates.
    local y_left  = math.floor(card_h * SLOPE_LEFT_FRAC)
    local y_right = math.floor(card_h * SLOPE_RIGHT_FRAC)

    -- Book layer: SpineWidget for the first book, inset within the card
    -- by a few pixels on every side. The book's bottom extends to the
    -- card bottom and is hidden by the magazine's cardboard fill below
    -- the slope; only the top portion (above the slope) is visible.
    local book_w = card_w - BOOK_INSET_X * 2
    local book_h = card_h - BOOK_INSET_Y
    local book_widget
    if self.folder and self.folder.first_book then
        book_widget = SpineWidget:new{
            book        = self.folder.first_book,
            width       = book_w,
            height      = book_h,
            cover_fill  = true,
            is_selected = self.is_selected,
        }
    else
        -- Empty folder: SpineWidget's fallback path with the folder's
        -- label as the title so the "?" placeholder reads correctly.
        book_widget = SpineWidget:new{
            book        = { title = self.folder and self.folder.label or "" },
            width       = book_w,
            height      = book_h,
            is_selected = self.is_selected,
        }
    end
    local book_positioned = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = BOOK_INSET_Y,
        padding_left  = BOOK_INSET_X,
        book_widget,
    }

    -- Magazine front: cardboard quadrilateral with a sloped top.
    local magazine = MagazinePolygon:new{
        width      = card_w,
        height     = card_h,
        y_left     = y_left,
        y_right    = y_right,
        fill_color = CARDBOARD,
        edge_color = CARDBOARD_EDGE,
        radius     = CARD_RADIUS,
    }

    -- Folder label: in the rectangle area below max(y_left, y_right)
    -- where the cardboard is full width. Left-aligned text, top-aligned
    -- vertically (renders flush against the rectangle's top edge with
    -- a generous interior padding). Probe-then-build pattern still
    -- caps the widget height at the available rectangle height so a
    -- long folder name truncates with "…" instead of overflowing.
    local label_text = self.folder and self.folder.label or ""
    label_text = label_text:gsub("/$", "")
    local label_pad     = Size.padding.large
    local label_top     = math.max(y_left, y_right) + label_pad
    local label_h_avail = card_h - label_top - label_pad
    local label_w_avail = card_w - label_pad * 2
    local face          = Font:getFace("infofont", 16)
    local probe = TextBoxWidget:new{
        text  = label_text,
        face  = face,
        bold  = true,
        width = label_w_avail,
    }
    local content_h = probe:getSize().h
    probe:free()
    local fits      = content_h <= label_h_avail
    local label_h   = fits and content_h or label_h_avail
    local label_widget = TextBoxWidget:new{
        text                          = label_text,
        face                          = face,
        bold                          = true,
        fgcolor                       = Blitbuffer.COLOR_BLACK,
        bgcolor                       = CARDBOARD,
        width                         = label_w_avail,
        alignment                     = "left",
        height                        = label_h,
        height_overflow_show_ellipsis = not fits,
    }
    -- Top-aligned: the label widget paints starting at label_top with
    -- label_pad of inset on the left. No CenterContainer — the
    -- FrameContainer padding directly positions the label at the top
    -- of the rectangle region.
    local label_positioned = FrameContainer:new{
        bordersize    = 0,
        padding       = 0,
        padding_top   = label_top,
        padding_left  = label_pad,
        label_widget,
    }

    -- Drop shadow: a magazine-shaped silhouette painted at SHADOW_OFFSET
    -- down+right of the card. We render it as the same MagazinePolygon
    -- shape (not a plain rect) so the shadow follows the slope rather
    -- than peeking out as a rectangular halo above the cardboard's open
    -- mouth — the book's own SpineWidget shadow handles the upper region.
    local shadow_polygon = MagazinePolygon:new{
        width      = card_w,
        height     = card_h,
        y_left     = y_left,
        y_right    = y_right,
        fill_color = SHADOW_GRAY,
        radius     = CARD_RADIUS,
    }
    local shadow_positioned = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = SHADOW_OFFSET,
        padding_left = SHADOW_OFFSET,
        shadow_polygon,
    }

    -- Top-right shadow bridge: small triangle at (card_w, y_right) that
    -- continues the slope diagonal into the shadow region. Painted before
    -- the magazine/label so the magazine's right wall edge can cleanly
    -- overlap its left vertex without a colour conflict.
    local bridge = SlopeShadowBridge:new{
        size  = SHADOW_OFFSET,
        color = SHADOW_GRAY,
    }
    local bridge_positioned = FrameContainer:new{
        bordersize   = 0,
        padding      = 0,
        padding_top  = y_right,
        padding_left = card_w,
        bridge,
    }

    self[1] = OverlapGroup:new{
        dimen = self.dimen,
        shadow_positioned,     -- 0: drop shadow (back-most)
        bridge_positioned,     -- 1: shadow bridge at top-right slope end
        book_positioned,       -- 2: book cover, inset within card
        magazine,              -- 3: cardboard front (covers book bottom)
        label_positioned,      -- 4: folder name centred on cardboard
    }
    self.ges_events = {
        Tap  = { GestureRange:new{ ges = "tap",  range = self.dimen } },
        Hold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function FolderStack:onTap()
    if self.on_tap then self.on_tap(self.folder) end
    return true
end
function FolderStack:onHold()
    if self.on_hold then self.on_hold(self.folder) end
    return true
end

return FolderStack
