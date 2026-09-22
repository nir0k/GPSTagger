-- GPX 1.x track parser. Pure Lua (no Lightroom dependencies) so it can be unit-tested.
--
-- Parser.parse(text) -> track | nil, errorMessage
-- track = {
--   segments = { { points = { {timestamp=, latitude=, longitude=, elevation=?}, ... } }, ... },
--   stats = { totalPoints, timedPoints, untimedPoints, invalidPoints, firstTime, lastTime },
-- }
-- Points without a usable <time> are counted but excluded from segments.

local DateTime = require "DateTime"

local Parser = {}

-- Removes comments and unwraps CDATA without allowing either construct inside a tag.
-- This is deliberately a small scanner rather than a blind gsub, which could turn
-- malformed input such as <trk<!--...-->pt> into a valid-looking tag.
local function stripXmlNonMarkup(text)
    local out = {}
    local scan, copyFrom = 1, 1
    local inTag, quote = false, nil

    while true do
        local pos = text:find("[<>'\"]", scan)
        if not pos then break end
        local ch = text:sub(pos, pos)

        if quote then
            if ch == quote then quote = nil end
            scan = pos + 1
        elseif inTag then
            if ch == "'" or ch == '"' then
                quote = ch
            elseif ch == ">" then
                inTag = false
            elseif ch == "<" then
                return nil, "The GPX file is malformed XML (markup inside a tag)."
            end
            scan = pos + 1
        elseif ch == "<" then
            if text:sub(pos, pos + 3) == "<!--" then
                local close = text:find("-->", pos + 4, true)
                if not close then return nil, "The GPX file is malformed XML (unclosed comment)." end
                out[#out + 1] = text:sub(copyFrom, pos - 1)
                out[#out + 1] = " "
                scan, copyFrom = close + 3, close + 3
            elseif text:sub(pos, pos + 8) == "<![CDATA[" then
                local close = text:find("]]>", pos + 9, true)
                if not close then return nil, "The GPX file is malformed XML (unclosed CDATA)." end
                local value = text:sub(pos + 9, close - 1)
                value = value:gsub("<", "&lt;"):gsub(">", "&gt;")
                out[#out + 1] = text:sub(copyFrom, pos - 1)
                out[#out + 1] = " " .. value .. " "
                scan, copyFrom = close + 3, close + 3
            else
                inTag = true
                scan = pos + 1
            end
        else
            scan = pos + 1
        end
    end

    if inTag or quote then return nil, "The GPX file is malformed XML (unclosed tag)." end
    out[#out + 1] = text:sub(copyFrom)
    return table.concat(out)
end

local function attr(attrs, name)
    -- name="..." or name='...' as a whole attribute name (attrs starts with whitespace)
    return attrs:match("%s" .. name .. "%s*=%s*\"([^\"]*)\"")
        or attrs:match("%s" .. name .. "%s*=%s*'([^']*)'")
end

-- Parses all <trkpt> in `body` (a string slice), appending timed points to `points`.
local function parsePoints(body, points, stats)
    local pos = 1
    while true do
        local s, e, attrs, selfClose = body:find("<trkpt(%s[^>]-)(/?)>", pos)
        if not s then break end
        local inner = ""
        if selfClose ~= "/" then
            local cs, ce = body:find("</trkpt>", e + 1, true)
            if not cs then
                return nil, "The GPX file is malformed XML (unclosed <trkpt>)."
            end
            inner = body:sub(e + 1, cs - 1)
            if inner:find("<trkpt[%s>]") then
                return nil, "The GPX file is malformed XML (nested or unclosed <trkpt>)."
            end
            pos = ce + 1
        else
            pos = e + 1
        end

        stats.totalPoints = stats.totalPoints + 1
        local lat = tonumber(attr(attrs, "lat") or "")
        local lon = tonumber(attr(attrs, "lon") or "")
        if not lat or not lon or lat < -90 or lat > 90 or lon < -180 or lon > 180 then
            stats.invalidPoints = stats.invalidPoints + 1
        else
            local timeStr = inner:match("<time>%s*(.-)%s*</time>")
            local ts = timeStr and DateTime.parseXsdDateTime(timeStr)
            if not ts then
                stats.untimedPoints = stats.untimedPoints + 1
            else
                stats.timedPoints = stats.timedPoints + 1
                local ele = tonumber(inner:match("<ele>%s*(.-)%s*</ele>") or "")
                points[#points + 1] = { timestamp = ts, latitude = lat, longitude = lon, elevation = ele }
            end
        end
    end
    return true
end

-- Some devices write glitch timestamps (e.g. a point dated days later between two normal
-- ones). Drops points that run backwards in time, or jump ahead of a consistent next point,
-- so the remaining points are ordered. Updates the track time range.
local function cleanSegment(points, stats)
    local kept = {}
    local prev
    for i, p in ipairs(points) do
        local ts = p.timestamp
        local nextP = points[i + 1]
        local glitch = false
        if prev and ts < prev then
            glitch = true
        elseif nextP and ts > nextP.timestamp and (not prev or nextP.timestamp >= prev) then
            glitch = true
        end
        if glitch then
            stats.outOfOrder = stats.outOfOrder + 1
        else
            kept[#kept + 1] = p
            prev = ts
            if not stats.firstTime or ts < stats.firstTime then stats.firstTime = ts end
            if not stats.lastTime or ts > stats.lastTime then stats.lastTime = ts end
        end
    end
    return kept
end

function Parser.parse(text)
    if type(text) ~= "string" or text == "" then
        return nil, "The GPX file is empty."
    end
    local cleaned, cleanErr = stripXmlNonMarkup(text)
    if not cleaned then return nil, cleanErr end
    text = cleaned
    if not text:find("<gpx[%s>]") then
        return nil, "The file is not a valid GPX (no <gpx> element)."
    end
    if not text:find("</gpx>", 1, true) then
        return nil, "The GPX file is malformed XML (missing </gpx>)."
    end

    local stats = { totalPoints = 0, timedPoints = 0, untimedPoints = 0, invalidPoints = 0, outOfOrder = 0 }
    local track = { segments = {}, stats = stats }

    local pos = 1
    local sawSegment = false
    while true do
        local s, e, selfClose = text:find("<trkseg[%s]*(/?)>", pos)
        if not s then break end
        sawSegment = true
        if selfClose == "/" then
            pos = e + 1
        else
            local cs, ce = text:find("</trkseg>", e + 1, true)
            if not cs then
                return nil, "The GPX file is malformed XML (unclosed <trkseg>)."
            end
            local points = {}
            local ok, err = parsePoints(text:sub(e + 1, cs - 1), points, stats)
            if not ok then return nil, err end
            points = cleanSegment(points, stats)
            if #points > 0 then
                track.segments[#track.segments + 1] = { points = points }
            end
            pos = ce + 1
        end
    end

    if not sawSegment then
        -- Tolerate <trkpt> outside of <trkseg> as one implicit segment.
        local points = {}
        local ok, err = parsePoints(text, points, stats)
        if not ok then return nil, err end
        points = cleanSegment(points, stats)
        if #points > 0 then
            track.segments[1] = { points = points }
        end
    end

    if stats.totalPoints == 0 then
        return nil, "This GPX file does not contain any track points (<trkpt>).\nRoutes (<rte>) and waypoints (<wpt>) are not supported."
    end
    if stats.timedPoints == 0 then
        return nil, "This GPX track does not contain timestamps.\nGPS matching is not possible."
    end

    table.sort(track.segments, function(a, b) return a.points[1].timestamp < b.points[1].timestamp end)
    return track
end

return Parser
