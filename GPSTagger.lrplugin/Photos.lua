-- Reads the selected photos from the Lightroom catalog into plain tables for the Matcher.
local LrPathUtils = import "LrPathUtils"

local DateTime = require "DateTime"

local Photos = {}

-- Returns the selected photos, or an empty table when nothing is selected
-- (catalog:getTargetPhotos() alone falls back to the whole filmstrip, which we do not want).
function Photos.getSelected(catalog)
    if not catalog:getTargetPhoto() then return {} end
    return catalog:getTargetPhotos() or {}
end

-- Returns an array of { ref=LrPhoto, name=, captureWall=, gps=, gpsAltitude=,
-- gpsImgDirection= }, sorted by capture time.
function Photos.read(catalog, lrPhotos)
    local meta = catalog:batchGetRawMetadata(lrPhotos,
        { "path", "dateTime", "dateTimeOriginal", "gps", "gpsAltitude", "gpsImgDirection" })

    local list = {}
    for _, p in ipairs(lrPhotos) do
        local m = meta[p] or {}
        -- dateTime is the effective capture time (reflects edits made in Lightroom).
        local cocoa = m.dateTime or m.dateTimeOriginal
        list[#list + 1] = {
            ref = p,
            name = m.path and LrPathUtils.leafName(m.path) or "?",
            captureWall = cocoa and DateTime.cocoaToWallUnix(cocoa) or nil,
            gps = m.gps,
            gpsAltitude = m.gpsAltitude,
            gpsImgDirection = m.gpsImgDirection,
        }
    end

    table.sort(list, function(a, b)
        if a.captureWall and b.captureWall then
            if a.captureWall ~= b.captureWall then return a.captureWall < b.captureWall end
            return a.name < b.name
        end
        if a.captureWall then return true end
        if b.captureWall then return false end
        return a.name < b.name
    end)
    return list
end

return Photos
