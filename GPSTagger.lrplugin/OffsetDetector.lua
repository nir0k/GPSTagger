-- Suggests a Time offset (camera time minus UTC) for the selected photos. Pure Lua.
--
-- OffsetDetector.detect(track, photos) -> result | nil, message
-- result = { offsetSeconds=, inside=, total=, method= "gps"|"range", ambiguous=bool,
--            alternatives= { offsetSeconds, ... }, medianMeters= (gps method only) }
--
-- Offsets are tried in 15-minute steps from UTC-12:00 to UTC+14:00.
--   * "gps":   when at least MIN_GPS_PHOTOS photos already carry GPS, the offset whose
--              track positions land closest to those coordinates wins.
--   * "range": otherwise the offset that puts the most photos inside the track's time
--              range wins. Several offsets can fit equally well (a long track, photos
--              taken in a short window); then `ambiguous` is set and the one closest
--              to UTC is suggested.

local Matcher = require "Matcher"

local OffsetDetector = {}

local STEP = 900
local MIN_STEPS, MAX_STEPS = -48, 56
local MIN_GPS_PHOTOS = 3
local MAX_GPS_MEDIAN_METERS = 500

local function haversine(lat1, lon1, lat2, lon2)
    local rad = math.pi / 180
    local dLat, dLon = (lat2 - lat1) * rad, (lon2 - lon1) * rad
    local a = math.sin(dLat / 2) ^ 2 + math.cos(lat1 * rad) * math.cos(lat2 * rad) * math.sin(dLon / 2) ^ 2
    return 12742000 * math.asin(math.min(1, math.sqrt(a)))
end

local function median(list)
    table.sort(list)
    local n = #list
    if n == 0 then return nil end
    if n % 2 == 1 then return list[(n + 1) / 2] end
    return (list[n / 2] + list[n / 2 + 1]) / 2
end

function OffsetDetector.detect(track, photos)
    local index = Matcher.index(track)

    local timed, withGps = {}, {}
    for _, p in ipairs(photos) do
        if p.captureWall then
            timed[#timed + 1] = p
            if p.gps then withGps[#withGps + 1] = p end
        end
    end
    if #timed == 0 then return nil, "None of the selected photos has a capture time." end

    local stats = {}
    local bestInside = 0
    for k = MIN_STEPS, MAX_STEPS do
        local offset = k * STEP
        local inside = 0
        for _, p in ipairs(timed) do
            local T = p.captureWall - offset
            if T >= index.firstTime and T <= index.lastTime then inside = inside + 1 end
        end
        stats[#stats + 1] = { offset = offset, inside = inside }
        if inside > bestInside then bestInside = inside end
    end
    if bestInside == 0 then
        return nil, "No time offset puts any photo inside the track. Check that the GPX belongs to these photos."
    end

    -- Existing GPS coordinates pin the offset down exactly.
    if #withGps >= MIN_GPS_PHOTOS then
        local bestMedian, bestOffset
        for _, s in ipairs(stats) do
            if s.inside > 0 then
                local distances = {}
                for _, p in ipairs(withGps) do
                    local T = p.captureWall - s.offset
                    if T >= index.firstTime and T <= index.lastTime then
                        local r = Matcher.locate(index, T)
                        distances[#distances + 1] = haversine(p.gps.latitude, p.gps.longitude, r.latitude, r.longitude)
                    end
                end
                if #distances >= MIN_GPS_PHOTOS then
                    local m = median(distances)
                    if not bestMedian or m < bestMedian then bestMedian, bestOffset = m, s.offset end
                end
            end
        end
        if bestMedian and bestMedian <= MAX_GPS_MEDIAN_METERS then
            local inside
            for _, s in ipairs(stats) do if s.offset == bestOffset then inside = s.inside end end
            return { offsetSeconds = bestOffset, inside = inside, total = #timed, method = "gps",
                     ambiguous = false, alternatives = {}, medianMeters = bestMedian }
        end
    end

    local candidates = {}
    for _, s in ipairs(stats) do
        if s.inside == bestInside then candidates[#candidates + 1] = s.offset end
    end
    table.sort(candidates, function(a, b)
        if math.abs(a) ~= math.abs(b) then return math.abs(a) < math.abs(b) end
        return a > b
    end)

    local alternatives = {}
    for i = 2, #candidates do alternatives[#alternatives + 1] = candidates[i] end
    return { offsetSeconds = candidates[1], inside = bestInside, total = #timed, method = "range",
             ambiguous = #candidates > 1, alternatives = alternatives }
end

return OffsetDetector
