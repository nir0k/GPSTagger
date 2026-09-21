-- Main settings dialog: GPX file, camera time, matching options, live match counters.
local LrView = import "LrView"
local LrBinding = import "LrBinding"
local LrDialogs = import "LrDialogs"
local LrFileUtils = import "LrFileUtils"
local LrPathUtils = import "LrPathUtils"

local DateTime = require "DateTime"
local Parser = require "Parser"
local Matcher = require "Matcher"
local OffsetDetector = require "OffsetDetector"
local Logger = require "Logger"
local Settings = require "Settings"

local MainDialog = {}

local function thousands(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function describeTrack(path, track)
    local st = track.stats
    local lines = {
        "File: " .. LrPathUtils.leafName(path),
        string.format("Track points: %s", thousands(st.totalPoints)),
        "Start: " .. DateTime.formatDateTime(st.firstTime) .. " UTC",
        "End:   " .. DateTime.formatDateTime(st.lastTime) .. " UTC",
        "Duration: " .. DateTime.formatDuration(st.lastTime - st.firstTime),
        string.format("Segments: %d", #track.segments),
    }
    local ignored = st.untimedPoints + st.invalidPoints + st.outOfOrder
    if ignored > 0 then
        lines[#lines + 1] = string.format("Ignored points: %d (no time %d, invalid %d, bad time %d)",
            ignored, st.untimedPoints, st.invalidPoints, st.outOfOrder)
    end
    return table.concat(lines, "\n")
end

-- Converts dialog properties into matcher settings, or returns nil + message.
local function parseSettings(props)
    local offset = DateTime.parseCorrection(props.timeOffset)
    if not offset then return nil, "Time offset must look like +02:00:00 (or -01:30:00)." end
    return {
        offsetSeconds = offset,
        overwrite = props.overwrite and true or false,
    }
end

-- state: { props = {...saved settings...}, gpxPath =, track = } persisted across Back/Preview.
-- Returns nil if cancelled, otherwise { settings=, track=, items=, summary= }.
function MainDialog.show(context, photos, state)
    local f = LrView.osFactory()
    local bind = LrView.bind

    local props = LrBinding.makePropertyTable(context)
    for k, v in pairs(state.saved) do props[k] = v end
    props.gpxPath = state.gpxPath or ""
    props.gpxName = state.gpxPath and LrPathUtils.leafName(state.gpxPath) or "(none)"
    props.trackInfo = state.track and describeTrack(state.gpxPath, state.track) or "No GPX loaded."
    props.summaryText = ""
    props.canPreview = false

    local plan = {}

    local function recompute()
        plan = {}
        props.canPreview = false
        if not state.track then
            props.summaryText = "Select a GPX file."
            return
        end
        local settings, err = parseSettings(props)
        if not settings then
            props.summaryText = err
            return
        end
        local items, summary = Matcher.plan(state.track, photos, settings)
        plan = { settings = settings, items = items, summary = summary }
        props.summaryText = string.format("Matched: %d     Existing GPS: %d     No match: %d",
            summary.match, summary.hasGps, summary.outside + summary.noTimestamp)
        props.canPreview = true
    end

    local function loadTrack(path)
        local text, readErr = LrFileUtils.readFile(path)
        if not text then
            LrDialogs.message("Cannot read GPX", tostring(readErr or path), "critical")
            return
        end
        local ok, track, err = pcall(Parser.parse, text)
        if not ok then track, err = nil, tostring(track) end
        if not track then
            Logger.error("GPX load failed: " .. tostring(err))
            LrDialogs.message("Cannot use this GPX file",
                string.format("%s\n\n%s\n\nSupported: GPX files with recorded tracks (<trk>) and <time> on the points.",
                    LrPathUtils.leafName(path), tostring(err)), "critical")
            return
        end
        local st = track.stats
        Logger.info("GPX loaded: " .. LrPathUtils.leafName(path))
        Logger.info("Track points: " .. st.totalPoints)
        if st.untimedPoints > 0 then
            Logger.warn(string.format("%d of %d points have no time", st.untimedPoints, st.totalPoints))
        end
        state.track, state.gpxPath = track, path
        props.gpxPath = path
        props.gpxName = LrPathUtils.leafName(path)
        props.trackInfo = describeTrack(path, track)
        recompute()
    end

    local function detectOffset()
        if not state.track then
            LrDialogs.message("Select a GPX file first.", "The offset is detected by comparing the photos with the track.", "info")
            return
        end
        local r, err = OffsetDetector.detect(state.track, photos)
        if not r then
            LrDialogs.message("Cannot detect the time offset", err, "info")
            return
        end
        props.timeOffset = DateTime.formatCorrection(r.offsetSeconds)
        local lines
        if r.method == "gps" then
            lines = string.format("Time offset set to %s.\n\nConfirmed by the existing GPS of your photos " ..
                "(median distance to the track: %d m).", props.timeOffset, math.floor(r.medianMeters + 0.5))
        else
            lines = string.format("Time offset set to %s: %d of %d photos fall inside the track.",
                props.timeOffset, r.inside, r.total)
            if r.ambiguous then
                local alt = {}
                for _, a in ipairs(r.alternatives) do alt[#alt + 1] = DateTime.formatCorrection(a) end
                lines = lines .. "\n\nThese offsets fit equally well: " .. table.concat(alt, ", ") ..
                    ".\nCheck the result in Preview, or pick the right one by hand."
            end
        end
        LrDialogs.message("Time offset detected", lines .. "\n\nFine-tune the seconds by hand if the camera clock is off.", "info")
    end

    for _, key in ipairs({ "timeOffset", "overwrite" }) do
        props:addObserver(key, recompute)
    end
    recompute()

    local contents = f:column {
        bind_to_object = props,
        spacing = f:control_spacing(),
        fill_horizontal = 1,

        f:static_text { title = string.format("Selected photos: %d", #photos), font = "<system/bold>" },

        f:row {
            f:static_text { title = "GPX track:", width = 80 },
            f:static_text {
                title = bind "gpxName", width = 250, truncation = "middle",
                tooltip = bind "gpxPath",
            },
            f:push_button {
                title = "Browse...",
                action = function()
                    local r = LrDialogs.runOpenPanel {
                        title = "Select GPX file",
                        canChooseFiles = true,
                        canChooseDirectories = false,
                        allowsMultipleSelection = false,
                        fileTypes = { "gpx" },
                    }
                    if r and r[1] then loadTrack(r[1]) end
                end,
            },
        },

        f:group_box {
            title = "Track info",
            fill_horizontal = 1,
            f:static_text { title = bind "trackInfo", height_in_lines = 8, width = 400 },
        },

        f:row {
            f:static_text { title = "Time offset:", width = 80 },
            f:edit_field { value = bind "timeOffset", immediate = true, width_in_chars = 10 },
            f:push_button {
                title = "Detect", action = detectOffset,
                tooltip = "Find the offset that puts your photos on the track.",
            },
            f:static_text { title = "±HH:MM:SS, camera time minus UTC" },
        },

        f:checkbox {
            title = "Overwrite existing GPS", value = bind "overwrite",
            tooltip = "Off: photos that already have GPS are skipped.",
        },

        f:static_text { title = bind "summaryText", font = "<system/bold>", width = 400 },
    }
    local result = LrDialogs.presentModalDialog {
        title = "GPS Tagger",
        contents = contents,
        actionVerb = "Preview",
        actionBinding = { enabled = { bind_to_object = props, key = "canPreview" } },
    }

    -- Remember the choices whatever the outcome.
    for k in pairs(Settings.defaults) do
        if props[k] ~= nil then state.saved[k] = props[k] end
    end

    if result ~= "ok" or not plan.settings then return nil end
    return { settings = plan.settings, track = state.track, items = plan.items, summary = plan.summary }
end

return MainDialog
