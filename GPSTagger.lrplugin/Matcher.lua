-- Matches photos to a parsed GPX track. Pure Lua (no Lightroom dependencies).
--
-- Every photo taken between the first and the last track point gets the coordinates
-- (and altitude, when the track has it) of the track point nearest in time.
--
-- Matcher.plan(track, photos, settings) -> items, summary
--
-- photo    = { name=, captureWall= (wall-clock unix seconds or nil), gps= {latitude=,longitude=}|nil,
--              ref= (opaque, passed through) }
-- settings = { offsetSeconds= (camera time minus UTC), overwrite= }
-- item     = { photo=, status=, correctedTime=, latitude=, longitude=, altitude=, delta=, detail= }

local Matcher = {}

Matcher.MATCH = "MATCH"
Matcher.HAS_GPS = "HAS GPS"
Matcher.OUTSIDE = "OUTSIDE TRACK"
Matcher.NO_TIMESTAMP = "NO TIMESTAMP"

-- Index of the last point with timestamp <= value, or 0.
local function lastAtOrBefore(points, value)
    local lo, hi, found = 1, #points, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if points[mid].timestamp <= value then
            found = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

-- All segments are merged into one time-ordered list of points.
function Matcher.index(track)
    local points = {}
    for _, seg in ipairs(track.segments) do
        for _, p in ipairs(seg.points) do points[#points + 1] = p end
    end
    table.sort(points, function(a, b) return a.timestamp < b.timestamp end)
    return { points = points, firstTime = points[1].timestamp, lastTime = points[#points].timestamp }
end

-- Returns { status = MATCH, latitude, longitude, altitude?, delta } or { status = OUTSIDE, detail }.
function Matcher.locate(index, T)
    if T < index.firstTime or T > index.lastTime then
        return { status = Matcher.OUTSIDE, detail = "Outside track time range" }
    end

    local pts = index.points
    local i = lastAtOrBefore(pts, T)
    local p = pts[i]
    local nextP = pts[i + 1]
    if nextP and (nextP.timestamp - T) < (T - p.timestamp) then p = nextP end

    return { status = Matcher.MATCH, latitude = p.latitude, longitude = p.longitude,
             altitude = p.elevation, delta = math.abs(p.timestamp - T) }
end

function Matcher.plan(track, photos, settings)
    local index = Matcher.index(track)
    local items = {}
    local summary = { total = #photos, match = 0, hasGps = 0, outside = 0, noTimestamp = 0 }

    for _, photo in ipairs(photos) do
        local item = { photo = photo }
        items[#items + 1] = item

        if not photo.captureWall then
            item.status = Matcher.NO_TIMESTAMP
            item.detail = "Photo has no capture time"
            summary.noTimestamp = summary.noTimestamp + 1
        else
            local T = photo.captureWall - settings.offsetSeconds
            item.correctedTime = T

            if photo.gps and not settings.overwrite then
                item.status = Matcher.HAS_GPS
                item.latitude, item.longitude = photo.gps.latitude, photo.gps.longitude
                item.detail = "Photo already has GPS"
                summary.hasGps = summary.hasGps + 1
            else
                local r = Matcher.locate(index, T)
                item.status = r.status
                item.detail = r.detail
                if r.status == Matcher.MATCH then
                    item.latitude, item.longitude = r.latitude, r.longitude
                    item.altitude, item.delta = r.altitude, r.delta
                    summary.match = summary.match + 1
                else
                    summary.outside = summary.outside + 1
                end
            end
        end
    end
    return items, summary
end

return Matcher
