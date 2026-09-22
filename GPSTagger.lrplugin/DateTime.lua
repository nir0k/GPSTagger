-- Pure-Lua date/time helpers (no Lightroom dependencies, Lua 5.1 compatible).
-- All "unix" values are seconds since 1970-01-01 00:00:00 UTC (may be fractional).

local DateTime = {}

-- Seconds between the Unix epoch (1970) and the Cocoa epoch (2001) used by Lightroom.
DateTime.COCOA_EPOCH_OFFSET = 978307200

-- Days since 1970-01-01 for a proleptic Gregorian civil date (Howard Hinnant's algorithm).
local function daysFromCivil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

local function civilFromDays(z)
    z = z + 719468
    local era = math.floor(z / 146097)
    local doe = z - era * 146097
    local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
    local y = yoe + era * 400
    local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
    local mp = math.floor((5 * doy + 2) / 153)
    local d = doy - math.floor((153 * mp + 2) / 5) + 1
    local m = mp < 10 and mp + 3 or mp - 9
    if m <= 2 then y = y + 1 end
    return y, m, d
end

local function daysInMonth(y, m)
    if m == 2 then
        local leap = y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)
        return leap and 29 or 28
    end
    if m == 4 or m == 6 or m == 9 or m == 11 then return 30 end
    return 31
end

-- Parses "+02:00", "-04:00", "+0530", "Z" into an offset in seconds. Returns nil if malformed.
function DateTime.parseOffset(str)
    if not str then return nil end
    str = str:match("^%s*(.-)%s*$")
    if str == "Z" or str == "z" then return 0 end
    local sign, h, m = str:match("^([+-])(%d%d?):?(%d%d)$")
    if not sign then
        sign, h = str:match("^([+-])(%d%d?)$")
        m = "0"
    end
    if not sign then return nil end
    h, m = tonumber(h), tonumber(m)
    if m > 59 or h > 14 or (h == 14 and m ~= 0) then return nil end
    local secs = h * 3600 + m * 60
    return sign == "-" and -secs or secs
end

-- Parses a clock correction "±HH:MM:SS" (also "±HH:MM" and "HH:MM:SS") into seconds.
function DateTime.parseCorrection(str)
    if not str then return nil end
    str = str:match("^%s*(.-)%s*$")
    local sign, rest = str:match("^([+-]?)(%d+:%d+:?%d*)$")
    if not sign then return nil end
    local h, m, s = rest:match("^(%d+):(%d+):?(%d*)$")
    h, m, s = tonumber(h), tonumber(m), tonumber(s) or 0
    if m > 59 or s > 59 then return nil end
    local secs = h * 3600 + m * 60 + s
    return sign == "-" and -secs or secs
end

function DateTime.formatCorrection(secs)
    local sign = secs < 0 and "-" or "+"
    secs = math.abs(math.floor(secs + 0.5))
    return string.format("%s%02d:%02d:%02d", sign, math.floor(secs / 3600),
        math.floor((secs % 3600) / 60), secs % 60)
end

-- Parses an xsd:dateTime ("2026-09-18T08:42:15Z", "...+02:00", "...15.123+02:00").
-- A value without a timezone designator is taken as UTC. Returns unix seconds or nil.
function DateTime.parseXsdDateTime(str)
    if not str then return nil end
    str = str:match("^%s*(.-)%s*$")
    local y, mo, d, h, mi, s, rest = str:match("^(-?%d%d%d%d+)-(%d%d)-(%d%d)[Tt](%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    y, mo, d, h, mi, s = tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)

    local frac = 0
    local fracStr, tz = rest:match("^%.(%d+)(.*)$")
    if fracStr then
        frac = tonumber("0." .. fracStr)
    else
        tz = rest
    end

    if mo < 1 or mo > 12 or d < 1 or d > daysInMonth(y, mo) or
        h > 24 or mi > 59 or s > 60 or (h == 24 and (mi ~= 0 or s ~= 0 or frac ~= 0)) then
        return nil
    end

    local offset = 0
    if tz ~= "" then
        offset = DateTime.parseOffset(tz)
        if not offset then return nil end
    end

    local days = daysFromCivil(y, mo, d)
    return days * 86400 + h * 3600 + mi * 60 + s + frac - offset
end

-- Lightroom stores capture time as Cocoa seconds whose wall-clock value is the camera's
-- local time (no timezone). Convert to "wall-clock seconds" on the unix scale.
function DateTime.cocoaToWallUnix(cocoa)
    return cocoa + DateTime.COCOA_EPOCH_OFFSET
end

-- "2026-09-18 08:42:15" for unix seconds (interpreted as UTC / wall clock).
function DateTime.formatDateTime(unix)
    unix = math.floor(unix + 0.5)
    local days = math.floor(unix / 86400)
    local rem = unix - days * 86400
    local y, m, d = civilFromDays(days)
    return string.format("%04d-%02d-%02d %02d:%02d:%02d", y, m, d,
        math.floor(rem / 3600), math.floor((rem % 3600) / 60), rem % 60)
end

function DateTime.formatTime(unix)
    return DateTime.formatDateTime(unix):sub(12)
end

-- "7h 16m" for a duration in seconds.
function DateTime.formatDuration(secs)
    secs = math.floor(secs + 0.5)
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    if m > 0 then return string.format("%dm %02ds", m, secs % 60) end
    return string.format("%ds", secs)
end

return DateTime
