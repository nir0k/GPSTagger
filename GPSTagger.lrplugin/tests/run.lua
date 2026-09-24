-- Plain-Lua unit tests (no Lightroom needed). Run from the plugin folder:
--   lua tests/run.lua
package.path = "./?.lua;" .. package.path

local DateTime = require "DateTime"
local Parser = require "Parser"
local Matcher = require "Matcher"
local CsvExport = require "CsvExport"
local OffsetDetector = require "OffsetDetector"

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1 else failed = failed + 1; print("FAIL: " .. name .. "\n  " .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function near(a, b, msg)
    if a == nil or math.abs(a - b) > 1e-6 then error((msg or "") .. " expected ~" .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function T(value)
    return assert(DateTime.parseXsdDateTime(value))
end

local function gpx(body) return '<?xml version="1.0"?><gpx version="1.1" creator="t"><trk>' .. body .. '</trk></gpx>' end
local function pt(lat, lon, time, ele)
    return string.format('<trkpt lat="%s" lon="%s">%s%s</trkpt>', lat, lon,
        ele and ("<ele>" .. ele .. "</ele>") or "", time and ("<time>" .. time .. "</time>") or "")
end
local function seg(...) return "<trkseg>" .. table.concat({ ... }) .. "</trkseg>" end

-- ---- DateTime ----
test("xsd Z / offset / millis", function()
    local z = DateTime.parseXsdDateTime("2026-09-18T08:42:15Z")
    eq(DateTime.parseXsdDateTime("2026-09-18T10:42:15+02:00"), z)
    near(DateTime.parseXsdDateTime("2026-09-18T10:42:15.123+02:00"), z + 0.123)
    eq(DateTime.parseXsdDateTime("1970-01-01T00:00:00Z"), 0)
    eq(DateTime.parseXsdDateTime("garbage"), nil)
end)
test("invalid xsd dates and offsets are rejected", function()
    eq(DateTime.parseXsdDateTime("2026-02-31T08:00:00Z"), nil)
    eq(DateTime.parseXsdDateTime("2025-02-29T08:00:00Z"), nil)
    eq(DateTime.parseXsdDateTime("2026-01-01T24:59:59Z"), nil)
    eq(DateTime.parseXsdDateTime("2026-01-01T08:00:00+14:01"), nil)
    eq(DateTime.formatDateTime(assert(DateTime.parseXsdDateTime("2026-01-01T24:00:00Z"))),
        "2026-01-02 00:00:00")
end)
test("xsd leap second is accepted", function()
    eq(DateTime.parseXsdDateTime("2016-12-31T23:59:60Z"),
        DateTime.parseXsdDateTime("2017-01-01T00:00:00Z"))
end)
test("format round trip", function()
    eq(DateTime.formatDateTime(DateTime.parseXsdDateTime("2026-09-18T08:42:15Z")), "2026-09-18 08:42:15")
    eq(DateTime.formatDateTime(0), "1970-01-01 00:00:00")
end)
test("offset and correction", function()
    eq(DateTime.parseOffset("+05:30"), 19800)
    eq(DateTime.parseOffset("-04:00"), -14400)
    eq(DateTime.parseCorrection("+00:01:37"), 97)
    eq(DateTime.parseCorrection("-00:00:10"), -10)
    eq(DateTime.parseCorrection("abc"), nil)
    eq(DateTime.formatCorrection(97), "+00:01:37")
end)


-- ---- Parser ----
test("parse basic + segments + stats", function()
    local t = assert(Parser.parse(gpx(
        seg(pt(47.1, 9.4, "2026-09-18T08:42:10Z", 100), pt(47.2, 9.5, "2026-09-18T08:42:20Z", 110)) ..
        seg(pt(48, 10, "2026-09-18T09:00:00Z")))))
    eq(#t.segments, 2)
    eq(t.stats.totalPoints, 3)
    eq(t.segments[1].points[1].elevation, 100)
    eq(t.segments[2].points[1].elevation, nil)
end)
test("untimed points skipped, none timed -> error", function()
    local t = assert(Parser.parse(gpx(seg(pt(1, 2, nil), pt(1, 2, "2026-09-18T08:42:10Z")))))
    eq(t.stats.untimedPoints, 1)
    eq(t.stats.timedPoints, 1)
    local bad, err = Parser.parse(gpx(seg(pt(1, 2, nil))))
    eq(bad, nil)
    assert(err:find("timestamps"))
end)
test("malformed and non-gpx", function()
    eq((Parser.parse("<html></html>")), nil)
    eq((Parser.parse('<gpx><trk><trkseg><trkpt lat="1" lon="2">')), nil)
    eq((Parser.parse(gpx(seg(pt("abc", 2, "2026-09-18T08:42:10Z"))))), nil)
end)
test("unclosed and nested track points are rejected", function()
    local unclosed = '<gpx><trk><trkseg><trkpt lat="1" lon="2"><time>2026-09-18T08:42:10Z</time></trkseg></trk></gpx>'
    eq((Parser.parse(unclosed)), nil)

    local nested = '<gpx><trk><trkseg><trkpt lat="1" lon="2"><time>2026-09-18T08:42:10Z</time>' ..
        '<trkpt lat="3" lon="4"><time>2026-09-18T08:42:11Z</time></trkpt></trkseg></trk></gpx>'
    eq((Parser.parse(nested)), nil)
end)
test("track-point-like text in comments and CDATA is ignored", function()
    local body = '<!-- documentation mentioning <trkpt lat="x"> -->' ..
        '<trkpt lat="1" lon="2"><extensions><![CDATA[<trkpt lat="x">]]></extensions>' ..
        '<time><![CDATA[2026-09-18T08:42:10Z]]></time></trkpt>'
    local t = assert(Parser.parse(gpx(seg(body))))
    eq(t.stats.totalPoints, 1)
    eq(#t.segments[1].points, 1)
end)
test("comments and CDATA cannot splice XML tag names", function()
    local comment = '<gpx><trk><trkseg><trk<!--x-->pt lat="1" lon="2">' ..
        '<time>2026-09-18T08:42:10Z</time></trkpt></trkseg></trk></gpx>'
    eq((Parser.parse(comment)), nil)

    local cdata = '<gpx><trk><trkseg><trk<![CDATA[x]]>pt lat="1" lon="2">' ..
        '<time>2026-09-18T08:42:10Z</time></trkpt></trkseg></trk></gpx>'
    eq((Parser.parse(cdata)), nil)
end)
test("glitch timestamps are dropped", function()
    local t = assert(Parser.parse(gpx(seg(
        pt(47.1, 9.4, "2026-09-18T08:00:00Z"),
        pt(47.2, 9.4, "2026-09-21T02:58:00Z"),   -- spike up
        pt(47.3, 9.4, "2026-09-18T08:00:02Z"),
        pt(47.4, 9.4, "2026-09-18T04:45:00Z"),   -- spike down
        pt(47.5, 9.4, "2026-09-18T08:00:04Z")))))
    eq(#t.segments[1].points, 3)
    eq(t.stats.outOfOrder, 2)
    eq(t.stats.lastTime, T("2026-09-18T08:00:04Z"))
end)
-- ---- Matcher ----
local function settings(over)
    local s = { offsetSeconds = 0, overwrite = false }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end
local function one(track, wall, over, gps)
    local items = Matcher.plan(track, { { name = "x", captureWall = wall, gps = gps } }, settings(over))
    return items[1]
end

local track = assert(Parser.parse(gpx(
    seg(pt(47.1000, 9.4000, "2026-09-18T10:42:10Z", 100), pt(47.1010, 9.4020, "2026-09-18T10:42:20Z", 110),
        pt(47.2, 9.5, "2026-09-18T10:46:20Z")) ..
    seg(pt(-33.0, -70.0, "2026-09-18T11:00:00Z"), pt(-33.1, -70.1, "2026-09-18T11:00:10Z")))))

test("nearest point, with its altitude", function()
    local a = one(track, T("2026-09-18T10:42:12Z"))
    eq(a.status, Matcher.MATCH); near(a.latitude, 47.1); near(a.altitude, 100)
    local b = one(track, T("2026-09-18T10:42:18Z"))
    near(b.latitude, 47.1010); near(b.altitude, 110)
end)
test("exact hit", function()
    local it = one(track, T("2026-09-18T10:42:10Z"))
    eq(it.status, Matcher.MATCH); near(it.latitude, 47.1); eq(it.delta, 0)
end)
test("no altitude when the point has none", function()
    eq(one(track, T("2026-09-18T10:46:19Z")).altitude, nil)
end)
test("time offset (camera time minus UTC)", function()
    -- camera at UTC+2 shows 12:42:10 -> 10:42:10 UTC
    near(one(track, T("2026-09-18T12:42:10Z"), { offsetSeconds = 7200 }).latitude, 47.1)
    -- half-hour zone
    near(one(track, T("2026-09-18T16:12:10Z"), { offsetSeconds = 19800 }).latitude, 47.1)
    -- camera 2 s slow at UTC+2: offset +01:59:58
    near(one(track, T("2026-09-18T12:42:08Z"), { offsetSeconds = 7198 }).latitude, 47.1)
    -- negative offset
    near(one(track, T("2026-09-18T06:42:10Z"), { offsetSeconds = -14400 }).latitude, 47.1)
end)
test("outside track", function()
    eq(one(track, T("2026-09-18T10:00:00Z")).status, Matcher.OUTSIDE)
    eq(one(track, T("2026-09-18T12:00:00Z")).status, Matcher.OUTSIDE)
end)
test("inside the track always matches, even across pauses and segments", function()
    local mid = one(track, T("2026-09-18T10:44:00Z")) -- 4 min gap inside a segment
    eq(mid.status, Matcher.MATCH)
    local between = one(track, T("2026-09-18T10:50:00Z")) -- between the two segments
    eq(between.status, Matcher.MATCH)
    near(between.latitude, 47.2)
end)
test("southern hemisphere / negative longitude", function()
    local it = one(track, T("2026-09-18T11:00:09Z"))
    near(it.latitude, -33.1); near(it.longitude, -70.1)
end)
test("existing GPS skip vs overwrite", function()
    local gps = { latitude = 1, longitude = 2 }
    eq(one(track, T("2026-09-18T10:42:15Z"), nil, gps).status, Matcher.HAS_GPS)
    eq(one(track, T("2026-09-18T10:42:15Z"), { overwrite = true }, gps).status, Matcher.MATCH)
end)
test("existing GPS skip still reports corrected time", function()
    local gps = { latitude = 1, longitude = 2 }
    local it = one(track, T("2026-09-18T12:42:15Z"), { offsetSeconds = 7200 }, gps)
    eq(it.status, Matcher.HAS_GPS)
    eq(it.correctedTime, T("2026-09-18T10:42:15Z"))
end)
test("existing GPS without timestamp is still skipped and retained", function()
    local gps = { latitude = 1, longitude = 2 }
    local it = one(track, nil, nil, gps)
    eq(it.status, Matcher.HAS_GPS)
    near(it.latitude, 1); near(it.longitude, 2)
end)
test("no timestamp", function()
    eq(one(track, nil).status, Matcher.NO_TIMESTAMP)
end)
test("single point track", function()
    local t = assert(Parser.parse(gpx(seg(pt(1, 2, "2026-09-18T10:00:00Z")))))
    eq(one(t, T("2026-09-18T10:00:00Z")).status, Matcher.MATCH)
    eq(one(t, T("2026-09-18T10:00:01Z")).status, Matcher.OUTSIDE)
end)
test("performance: 20k points x 2k photos", function()
    local parts = {}
    for i = 0, 19999 do
        local ts = (DateTime.formatDateTime(1.79e9 + i):gsub(" ", "T")) .. "Z"
        parts[#parts + 1] = pt(47 + i * 1e-5, 9, ts)
    end
    local t = assert(Parser.parse(gpx("<trkseg>" .. table.concat(parts) .. "</trkseg>")))
    local photos = {}
    for i = 1, 2000 do photos[i] = { name = "p" .. i, captureWall = 1.79e9 + i * 9.5 } end
    local _, summary = Matcher.plan(t, photos, settings())
    eq(summary.match, 2000)
end)
test("csv export: header, quoting, all rows", function()
    local items = Matcher.plan(track, {
        { name = 'a,"b".CR3', captureWall = T("2026-09-18T10:42:12Z") },
        { name = "c.CR3", captureWall = nil },
    }, settings())
    local csv = CsvExport.build(items)
    assert(csv:sub(1, 3) == "\239\187\191", "BOM")
    local lines = {}
    for l in csv:gmatch("[^\r\n]+") do lines[#lines + 1] = l end
    eq(#lines, 3)
    assert(lines[2]:find('^"a,""b"".CR3",2026%-09%-18 10:42:12,'), lines[2])
    assert(lines[2]:find("MATCH", 1, true))
    assert(lines[3]:find("NO TIMESTAMP", 1, true))
end)

-- ---- MetadataWriter (with minimal Lightroom API stubs) ----
test("metadata writer clears stale altitude when a match has no elevation", function()
    local savedImport = _G.import
    local savedLogger = package.loaded.Logger
    local savedWriter = package.loaded.MetadataWriter

    local ok, err = pcall(function()
        _G.import = function(name)
            if name == "LrTasks" then return { yield = function() end } end
            if name == "LrProgressScope" then
                return function()
                    return {
                        setCancelable = function() end,
                        isCanceled = function() return false end,
                        setPortionComplete = function() end,
                        setCaption = function() end,
                        done = function() end,
                    }
                end
            end
            error("Unexpected import: " .. tostring(name))
        end
        package.loaded.Logger = { error = function() end }
        package.loaded.MetadataWriter = nil

        local writes = {}
        local metadata = {
            gps = { latitude = 10, longitude = 20 },
            gpsAltitude = 100,
            gpsImgDirection = 90,
        }
        local photoRef = {
            setRawMetadata = function(_, key, value)
                writes[#writes + 1] = { key = key, value = value }
                if key == "gps" and value == nil then
                    metadata.gps = nil
                    metadata.gpsAltitude = nil
                    metadata.gpsImgDirection = nil
                else
                    metadata[key] = value
                end
            end,
            getRawMetadata = function(_, key)
                return metadata[key]
            end,
        }
        local catalog = {
            withWriteAccessDo = function(_, _, fn)
                fn()
                return "executed"
            end,
        }
        local MetadataWriter = require "MetadataWriter"
        local result = MetadataWriter.apply(catalog, {
            { status = Matcher.MATCH, latitude = 1, longitude = 2,
              altitude = nil, photo = {
                  name = "x", ref = photoRef,
                  gps = { latitude = 10, longitude = 20 },
                  gpsAltitude = 100,
                  gpsImgDirection = 90,
              } },
        }, {})

        eq(result.applied, 1)
        eq(#writes, 3)
        eq(writes[1].key, "gps")
        eq(writes[1].value, nil)
        near(metadata.gps.latitude, 1)
        near(metadata.gps.longitude, 2)
        eq(metadata.gpsAltitude, nil)
        eq(metadata.gpsImgDirection, 90)

        writes = {}
        local elevated = MetadataWriter.apply(catalog, {
            { status = Matcher.MATCH, latitude = 3, longitude = 4,
              altitude = 0, photo = { name = "sea-level", ref = photoRef } },
        }, {})
        eq(elevated.applied, 1)
        eq(#writes, 2)
        eq(writes[2].key, "gpsAltitude")
        eq(writes[2].value, 0)
        eq(metadata.gpsAltitude, 0)

        -- If the SDK does not clear altitude along with gps, abort and restore the
        -- original coordinates instead of committing a mismatched partial update.
        metadata.gps = { latitude = 10, longitude = 20 }
        metadata.gpsAltitude = 100
        writes = {}
        local stubbornRef = {
            setRawMetadata = function(_, key, value)
                writes[#writes + 1] = { key = key, value = value }
                metadata[key] = value -- deliberately leaves gpsAltitude intact for gps=nil
            end,
            getRawMetadata = function(_, key) return metadata[key] end,
        }
        local notCleared = MetadataWriter.apply(catalog, {
            { status = Matcher.MATCH, latitude = 5, longitude = 6,
              altitude = nil, photo = {
                  name = "stubborn", ref = stubbornRef,
                  gps = { latitude = 10, longitude = 20 }, gpsAltitude = 100,
              } },
        }, {})
        eq(notCleared.applied, 0)
        eq(notCleared.errors, 1)
        near(metadata.gps.latitude, 10)
        near(metadata.gps.longitude, 20)
        eq(metadata.gpsAltitude, 100)

        -- A failure after clearing the old GPS must restore the original values.
        metadata.gps = { latitude = 10, longitude = 20 }
        metadata.gpsAltitude = 100
        writes = {}
        local failReplacement = true
        local failingRef = {
            setRawMetadata = function(_, key, value)
                writes[#writes + 1] = { key = key, value = value }
                if key == "gps" and value == nil then
                    metadata.gps = nil
                    metadata.gpsAltitude = nil
                elseif key == "gps" and failReplacement then
                    failReplacement = false
                    error("replacement failed")
                else
                    metadata[key] = value
                end
            end,
            getRawMetadata = function(_, key) return metadata[key] end,
        }
        local failedWrite = MetadataWriter.apply(catalog, {
            { status = Matcher.MATCH, latitude = 7, longitude = 8,
              altitude = nil, photo = {
                  name = "failing", ref = failingRef,
                  gps = { latitude = 10, longitude = 20 }, gpsAltitude = 100,
              } },
        }, {})
        eq(failedWrite.applied, 0)
        eq(failedWrite.errors, 1)
        near(metadata.gps.latitude, 10)
        near(metadata.gps.longitude, 20)
        eq(metadata.gpsAltitude, 100)

        -- A standalone old altitude (without coordinates) must also be cleared.
        metadata.gps = nil
        metadata.gpsAltitude = 50
        metadata.gpsImgDirection = nil
        writes = {}
        local standalone = MetadataWriter.apply(catalog, {
            { status = Matcher.MATCH, latitude = 9, longitude = 10,
              altitude = nil, photo = {
                  name = "standalone-altitude", ref = photoRef, gpsAltitude = 50,
              } },
        }, {})
        eq(standalone.applied, 1)
        near(metadata.gps.latitude, 9)
        near(metadata.gps.longitude, 10)
        eq(metadata.gpsAltitude, nil)
    end)

    _G.import = savedImport
    package.loaded.Logger = savedLogger
    package.loaded.MetadataWriter = savedWriter
    if not ok then error(err, 0) end
end)

-- ---- OffsetDetector ----
test("offset detection by time range", function()
    -- track 08:00-09:00 UTC (one point per minute); photos taken 08:10-08:40 UTC, camera at UTC+3
    local pts = {}
    for i = 0, 60 do
        pts[#pts + 1] = pt(47 + i * 1e-4, 9, DateTime.formatDateTime(T("2026-09-18T08:00:00Z") + i * 60):gsub(" ", "T") .. "Z")
    end
    local t = assert(Parser.parse(gpx(seg(table.concat(pts)))))
    local photos = {}
    for i = 1, 10 do photos[i] = { name = "p" .. i, captureWall = T("2026-09-18T11:10:00Z") + i * 180 } end
    local r = assert(OffsetDetector.detect(t, photos))
    eq(r.method, "range")
    -- many offsets keep a 30-minute photo window inside a 60-minute track: must be flagged ambiguous
    eq(r.ambiguous, true)
    local bad, msg = OffsetDetector.detect(t, { { name = "x", captureWall = T("2026-09-25T12:00:00Z") } })
    eq(bad, nil); assert(msg)
end)
test("offset detection pinned down by existing GPS", function()
    local pts = {}
    for i = 0, 60 do
        pts[#pts + 1] = pt(47 + i * 1e-3, 9, DateTime.formatDateTime(T("2026-09-18T08:00:00Z") + i * 60):gsub(" ", "T") .. "Z")
    end
    local t = assert(Parser.parse(gpx(seg(table.concat(pts)))))
    local photos = {}
    for i = 1, 6 do
        local utc = T("2026-09-18T08:10:00Z") + i * 300
        local minutes = (utc - T("2026-09-18T08:00:00Z")) / 60
        photos[i] = { name = "p" .. i, captureWall = utc + 7200,
                      gps = { latitude = 47 + minutes * 1e-3, longitude = 9 } }
    end
    local r = assert(OffsetDetector.detect(t, photos))
    eq(r.method, "gps"); eq(r.offsetSeconds, 7200); eq(r.ambiguous, false)
end)
print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
