# Per-Chip Sort Menu — Design Spec

**Date:** 2026-05-07

## Overview

Replace the current "respect KOReader's sort by setting" path (full rebuild on
every `FileChooser:refreshPath`) with an in-bookshelf sort menu that opens from
a tap on the page-text button in the pagination footer. Each chip exposes only
the sort options that make sense for its content shape, and remembers its own
choice across sessions.

The "respect KOReader sort" auto-refresh hook is removed: bookshelf owns its
own sort, and KOReader's filemanager collate setting no longer drives the All
chip's order.

## Goals

- Fast: tap → menu → pick → re-render via `_swapShelvesInPlace` (no full rebuild).
- Context-aware: each chip shows only options that match its data shape.
- Discoverable: tap target is the existing page-text button (already a Button
  widget at the visual centre of the footer), and the menu rises from the
  tapped widget so the spatial cue matches the action.
- Persistent per chip: switching to Authors and choosing "By book count" doesn't
  affect the order of Series next time you visit it.

## Non-Goals

- No animated slide-up. KOReader's anchored `ButtonDialog` opens adjacent to
  the tap target, which reads as "rising from" without the e-ink waveform
  tradeoffs of a frame-by-frame animation.
- No global sort preference. Each chip is independent.
- No migration of existing KOReader collate state into per-chip settings —
  every chip starts at the default specified below on first launch.
- No alternative sort on the Recent chip. The menu still opens (so the gesture
  is consistent across chips and discoverable on Recent too) but shows a single
  checked row, "By recently read". Tapping it just dismisses the dialog.

## Files Changed

- `bookshelf_widget.lua` — open the menu from the page-text button callback;
  add `_openSortMenu(self)` builder that returns a `ButtonDialog` populated
  with chip-relevant rows and anchored to the page-text widget.
- `book_repository.lua` — read each chip's saved sort setting and apply it in
  the existing fetch/group functions; add `latest_read` group sort to
  `getAuthors`, `getGenres`, `getTags` (already present for series).
- `main.lua` — remove the `_installSortRefreshHook` call and the
  `bookshelf_auto_refresh_on_sort` settings-menu entry (the underlying patch
  function can be deleted with it).

No new files.

## Sort options per chip

| Chip       | Options                                              | Default       |
|------------|------------------------------------------------------|---------------|
| all        | By title · By date added · By path · *Reverse* · *Mixed folders* | By title (Reverse off, Mixed off) |
| recent     | By recently read                                     | (only option) |
| latest     | By mtime · By title                                  | By mtime      |
| favourites | By date added · By title · By recently read         | By date added |
| series     | By name · By latest read · By book count            | By latest read|
| authors    | By name · By latest read · By book count            | By latest read|
| genres     | By name · By latest read · By book count            | By latest read|
| tags       | By name · By latest read · By book count            | By latest read|

`Reverse` and `Mixed folders` are independent toggles on the All chip; all
other rows are radio choices (one selected at a time, indicated with a check
glyph in the dialog row).

## Persistence

Stored in `G_reader_settings`:

```
bookshelf_sort_all          : "title" | "date_added" | "path"
bookshelf_sort_all_reverse  : boolean
bookshelf_sort_all_mixed    : boolean
bookshelf_sort_latest       : "mtime" | "title"
bookshelf_sort_favorites    : "date_added" | "title" | "recently_read"
bookshelf_sort_series       : "name" | "latest_read" | "book_count"
bookshelf_sort_authors      : "name" | "latest_read" | "book_count"
bookshelf_sort_genres       : "name" | "latest_read" | "book_count"
bookshelf_sort_tags         : "name" | "latest_read" | "book_count"
```

A missing setting reads as the default for that chip.

## Tap target & menu construction

`_buildPaginationFooter` already constructs the page-text Button at line 1335
with `callback = function() end`. Replace that callback with a call to a new
`BookshelfWidget:_openSortMenu()` method, passing the page-text button as the
anchor.

`_openSortMenu` builds a `ButtonDialog` whose `buttons` table is constructed
per `self.chip`. Recent's table contains a single checked row that just closes
the dialog — no setting written, no re-render.

```lua
local dialog
local function pick(setting_key, value)
    return function()
        G_reader_settings:saveSetting(setting_key, value)
        G_reader_settings:flush()
        UIManager:close(dialog)
        self:_swapShelvesInPlace()
    end
end
```

Each radio row uses a check glyph (`\xe2\x9c\x93 ` prefix) in the label of the
currently-selected option, matching the pattern used in `_openBookMenu`'s
"Set as home screen" row. Toggle rows (Reverse, Mixed folders on All) prefix
the same glyph when ON.

`dialog = ButtonDialog:new{ anchor = page_text_button, buttons = buttons }`,
then `UIManager:show(dialog)`.

The page-text button must be reachable from `_openSortMenu` for the anchor.
Easiest path: stash it on `self._page_text_button` inside
`_buildPaginationFooter` before returning.

## Repo wiring

Each `Repo.get*` function reads its chip's setting and applies it. Every
function already has a sort step at the end; this is changing which key is
sorted on, not adding a new layer. Examples:

- `Repo.getAll(...)` — replace the existing `collate`-based ordering with a
  three-way switch on `bookshelf_sort_all`, then optional reverse, then
  optional mixed-folders interleave.
- `Repo.getSeriesGroups(...)` — already supports name / latest_read / book_count
  via the in-memory cache; just route the active setting to the right
  comparator.
- `Repo.getAuthors / getGenres / getTags` — currently sort by name only.
  Extend each to compute `latest = max(read_time[fp])` per group during the
  existing iteration (the read_time map is already built for series), then
  pick a comparator based on the active setting:
    - `name` → group `series_name` ascending
    - `latest_read` → group `latest` descending (most-recent first)
    - `book_count` → `#group.books` descending, ties broken by name

`book_count` ties resolve to alphabetical-by-name so the order is deterministic.

## Removal of the auto-refresh path

Delete in `main.lua`:
- the `_installSortRefreshHook` method body and its call site
- the `bookshelf_auto_refresh_on_sort` row in the settings menu
- the `_computeSortFingerprint` static method on `BookshelfWidget`
- the `self._sort_fingerprint = ...` assignments in `_rebuild`/`_swapShelves`

The `bookshelf_auto_refresh_on_sort` user setting becomes dead data; we leave
it in `G_reader_settings` rather than actively migrating (KOReader tolerates
unknown keys, and removing them would require a one-shot migration on first
launch that's not worth the code).

## Error handling

- Tapping the page-text button on an unknown chip: defensive default — show
  no menu and log at debug level. (No expected path to this; chips are a
  closed enum.)
- Setting value not in the allowed enum (manual edit of settings.reader.lua):
  fall back to the chip's default and ignore the bad value, no toast — this
  is a user-poking-at-internals scenario.
- `ButtonDialog`'s anchor handles missing `dimen` itself (falls back to
  centred); no extra guard needed.

## Testing

No automated tests — bookshelf has no test harness, and the existing specs
follow the same convention.

Manual verification on Kindle device:
1. Each chip in turn: tap page-text button, confirm menu appears anchored
   above the pagination row, confirm only chip-relevant options show.
2. Pick a non-default option on each chip, confirm the shelf re-renders in
   the new order, confirm the option is checked next time the menu opens.
3. Cycle chips after picking — Authors-by-count then switching to Series
   should NOT carry the count sort to Series.
4. Recent chip: tap page-text button, confirm nothing happens (no toast,
   no flicker).
5. Cold restart KOReader, confirm the per-chip choices persist.
6. KOReader filemanager: change collate from "By title" to "By date";
   bookshelf's All chip MUST NOT change order (auto-refresh removed).
7. Recent chip: tap page-text button, confirm a single-row menu appears with
   "By recently read" checked; tapping the row dismisses the dialog and the
   shelf does NOT re-render (no setting was changed).
