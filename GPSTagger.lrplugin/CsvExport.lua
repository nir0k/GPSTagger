-- Builds a CSV of the Preview table (all photos, not only the visible rows). Pure Lua.
local DateTime = require "DateTime"

local CsvExport = {}

CsvExport.HEADER = { "File", "Capture (camera)", "Corrected (UTC)", "Latitude", "Longitude",
    "Altitude", "Status", "Delta (s)", "Note" }

local function quote(v)
    v = tostring(v)
    if v:find('[",\r\n]') then v = '"' .. v:gsub('"', '""') .. '"' end
    return v
end

local function row(fields)
    local out = {}
    for i, v in ipairs(fields) do out[i] = quote(v) end
    return table.concat(out, ",")
end

-- items as produced by Matcher.plan. Returns the CSV text (UTF-8 with BOM, CRLF lines).
function CsvExport.build(items)
    local lines = { row(CsvExport.HEADER) }
    for _, item in ipairs(items) do
        local p = item.photo
        lines[#lines + 1] = row({
            p.name,
            p.captureWall and DateTime.formatDateTime(p.captureWall) or "",
            item.correctedTime and DateTime.formatDateTime(item.correctedTime) or "",
            item.latitude and string.format("%.6f", item.latitude) or "",
            item.longitude and string.format("%.6f", item.longitude) or "",
            item.altitude and string.format("%.1f", item.altitude) or "",
            item.status or "",
            item.delta and string.format("%.1f", item.delta) or "",
            item.detail or "",
        })
    end
    return "\239\187\191" .. table.concat(lines, "\r\n") .. "\r\n"
end

return CsvExport
