-- Preview dialog: status summary + per-photo table.
-- Returns "ok" (Apply), "other" (Back) or "cancel".
--   * resizable window, opened at roughly the size of the Lightroom window;
--   * column widths fit their content;
--   * "Show" filter (all / without coordinates) and "Export CSV..." for the shown rows.
local LrView = import "LrView"
local LrDialogs = import "LrDialogs"
local LrColor = import "LrColor"

local DateTime = require "DateTime"
local Matcher = require "Matcher"
local CsvExport = require "CsvExport"

local PreviewDialog = {}

local MAX_ROWS = 400
local COLUMNS = { "Photo", "Capture", "Corrected (UTC)", "GPS", "Status" }
local CHAR_PX, PAD_PX, MIN_PX, MAX_PX = 7, 16, 70, 420

-- Size of the table area: about the Lightroom window, when the SDK can tell us.
local function viewSize()
    local w, h = 900, 380
    local ok, size = pcall(function()
        return import("LrSystemInfo").appWindowSize()
    end)
    if ok and type(size) == "table" and size.width and size.height then
        w = math.max(700, size.width - 140)
        h = math.max(300, size.height - 300)
    end
    return w, h
end

local function statusText(item)
    return item.status
end

local function summaryLines(s)
    local rows = {
        { "Matched:", s.match },
        { "Already has GPS:", s.hasGps },
        { "Outside track:", s.outside },
    }
    if s.noTimestamp > 0 then rows[#rows + 1] = { "No timestamp:", s.noTimestamp } end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = string.format("%-22s %d", r[1], r[2]) end
    out[#out + 1] = string.rep("-", 30)
    out[#out + 1] = string.format("%-22s %d", "Will update:", s.match)
    return table.concat(out, "\n")
end

local function exportCsv(items)
    local dirs = LrDialogs.runOpenPanel {
        title = "Choose a folder for the CSV file",
        canChooseFiles = false,
        canChooseDirectories = true,
        canCreateDirectories = true,
        allowsMultipleSelection = false,
    }
    if not (dirs and dirs[1]) then return end

    local sep = dirs[1]:find("\\", 1, true) and "\\" or "/"
    local path = dirs[1]:gsub("[/\\]$", "") .. sep .. os.date("GPSTagger-preview-%Y%m%d-%H%M%S.csv")
    local file, err = io.open(path, "wb")
    if not file then
        LrDialogs.message("Cannot write the CSV file", tostring(err), "critical")
        return
    end
    file:write(CsvExport.build(items))
    file:close()
    LrDialogs.message("CSV exported", string.format("%d rows written to:\n%s", #items, path), "info")
end

-- Table cells as text, for the visible rows.
local function buildCells(items)
    local cells = {}
    for n, item in ipairs(items) do
        if n > MAX_ROWS then break end
        cells[n] = {
            item.photo.name,
            item.photo.captureWall and DateTime.formatDateTime(item.photo.captureWall) or "—",
            item.correctedTime and DateTime.formatDateTime(item.correctedTime) or "—",
            item.latitude and string.format("%.5f, %.5f", item.latitude, item.longitude) or "—",
            statusText(item),
        }
    end
    return cells
end

-- Each column fits its longest text; the total is then stretched or squeezed to `available`.
local function columnWidths(cells, available)
    local widths, total = {}, 0
    for c, name in ipairs(COLUMNS) do
        local longest = #name
        for _, row in ipairs(cells) do
            local len = #row[c]
            if len > longest then longest = len end
        end
        widths[c] = math.min(MAX_PX, math.max(MIN_PX, longest * CHAR_PX + PAD_PX))
        total = total + widths[c]
    end
    local scale = available / total
    for c = 1, #COLUMNS do widths[c] = math.max(50, math.floor(widths[c] * scale)) end
    return widths
end

local FILTER_ALL, FILTER_NO_COORDS = "all", "nocoords"

local function filterItems(items, filter)
    if filter == FILTER_ALL then return items end
    local out = {}
    for _, item in ipairs(items) do
        if not item.latitude then out[#out + 1] = item end
    end
    return out
end

-- One pass of the dialog. Returns the dialog result, or "relayout" when the filter changed.
local function present(items, summary, state)
    local f = LrView.osFactory()
    local problem = LrColor(0.75, 0.25, 0.2)
    local good = LrColor(0.1, 0.6, 0.2)

    local shown = filterItems(items, state.filter)
    local cells = buildCells(shown)
    local viewW, viewH = viewSize()
    local widths = columnWidths(cells, viewW - 40)

    local function cell(text, col, color)
        return f:static_text { title = text, width = widths[col], text_color = color, truncation = "tail" }
    end

    -- The header row lives outside the scrolled view, so it stays visible while scrolling.
    local header = { spacing = 0 }
    for c, name in ipairs(COLUMNS) do
        header[c] = f:static_text { title = name, width = widths[c], font = "<system/bold>" }
    end

    local rows = { spacing = 2 }
    for n, row in ipairs(cells) do
        local color = (shown[n].status ~= Matcher.MATCH) and problem or nil
        local r = {}
        for c = 1, #COLUMNS do
            local cellColor = color
            if c == #COLUMNS and shown[n].status == Matcher.MATCH then cellColor = good end
            r[c] = cell(row[c], c, cellColor)
        end
        rows[#rows + 1] = f:row(r)
    end
    if #shown > MAX_ROWS then
        rows[#rows + 1] = f:static_text {
            title = string.format("... and %d more rows (all are processed on Apply; Export CSV includes all)",
                #shown - MAX_ROWS) }
    end
    if #shown == 0 then
        rows[#rows + 1] = f:static_text { title = "No rows." }
    end

    local contents
    local function setFilter(button, filter)
        state.filter = filter
        LrDialogs.stopModalWithResult(button, "relayout")
    end

    local noCoords = #filterItems(items, FILTER_NO_COORDS)
    contents = f:column {
        spacing = f:control_spacing(),
        fill = 1,
        f:row {
            f:static_text { title = string.format("%d selected photos", summary.total), font = "<system/bold>" },
            f:spacer { fill_horizontal = 1 },
            f:push_button { title = "Export CSV...", action = function() exportCsv(shown) end },
        },
        f:static_text { title = summaryLines(summary), height_in_lines = 5, font = "<system/small>" },
        f:row {
            f:static_text { title = "Show:" },
            f:push_button {
                title = string.format("All (%d)", #items),
                enabled = state.filter ~= FILTER_ALL,
                action = function(b) setFilter(b, FILTER_ALL) end,
            },
            f:push_button {
                title = string.format("Without coordinates (%d)", noCoords),
                enabled = state.filter ~= FILTER_NO_COORDS,
                action = function(b) setFilter(b, FILTER_NO_COORDS) end,
            },
        },
        f:row(header),
        f:scrolled_view {
            width = viewW, height = viewH,
            fill = 1,
            horizontal_scroller = false,
            f:column(rows),
        },
    }

    return LrDialogs.presentModalDialog {
        title = "GPS Tagger — Preview",
        contents = contents,
        actionVerb = "Apply GPS",
        cancelVerb = "Cancel",
        otherVerb = "Back",
        resizable = true,
    }
end

function PreviewDialog.show(items, summary)
    local state = { filter = FILTER_ALL }
    local result
    repeat
        result = present(items, summary, state)
    until result ~= "relayout"
    return result
end

return PreviewDialog