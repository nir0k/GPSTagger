-- Entry point: Library > Plug-in Extras > Apply GPS from GPX...
local LrApplication = import "LrApplication"
local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"

local Logger = require "Logger"
local Settings = require "Settings"
local Photos = require "Photos"
local MetadataWriter = require "MetadataWriter"
local MainDialog = require "MainDialog"
local PreviewDialog = require "PreviewDialog"
local Matcher = require "Matcher"
local DateTime = require "DateTime"

local function report(summary, result)
    local lines = {
        string.format("Photos selected:       %d", summary.total),
        string.format("GPS applied:           %d", result.applied),
        string.format("Skipped existing GPS:  %d", summary.hasGps),
        string.format("No matching track:     %d", summary.outside + summary.noTimestamp),
        string.format("Errors:                %d", result.errors),
    }
    if result.cancelled then lines[#lines + 1] = "\nCancelled: remaining photos were not processed." end
    for i, fail in ipairs(result.failed) do
        if i > 10 then lines[#lines + 1] = "..."; break end
        lines[#lines + 1] = string.format("%s: %s", fail.name, fail.message)
    end
    LrDialogs.message("GPS Tagging Complete", table.concat(lines, "\n"), "info")
end

local function logPlan(items, summary)
    Logger.info("Selected photos: " .. summary.total)
    Logger.info("Matched photos: " .. summary.match)
    for _, item in ipairs(items) do
        if item.status == Matcher.OUTSIDE or item.status == Matcher.NO_TIMESTAMP then
            Logger.warn(string.format("%s: %s (corrected UTC %s)", item.photo.name, item.detail or item.status,
                item.correctedTime and DateTime.formatDateTime(item.correctedTime) or "-"))
        end
    end
end

local function run(context)
    local catalog = LrApplication.activeCatalog()

    local selected = Photos.getSelected(catalog)
    if #selected == 0 then
        LrDialogs.message("No photos selected.", "Select one or more photos in Lightroom and try again.", "info")
        return
    end

    local photos = Photos.read(catalog, selected)
    local state = { saved = Settings.load(), gpxPath = nil, track = nil }

    while true do
        local plan = MainDialog.show(context, photos, state)
        Settings.save(state.saved)
        if not plan then return end

        local choice = PreviewDialog.show(plan.items, plan.summary)
        if choice == "ok" then
            logPlan(plan.items, plan.summary)
            report(plan.summary, MetadataWriter.apply(catalog, plan.items, context))
            return
        elseif choice ~= "other" then
            return -- Cancel: nothing was changed
        end
        -- "other" = Back: reopen the main dialog with the same state
    end
end

LrFunctionContext.postAsyncTaskWithContext("GPSTagger", function(context)
    local ok, err = LrTasks.pcall(run, context)
    if not ok then
        Logger.error("Unexpected error: " .. tostring(err))
        LrDialogs.message("GPS Tagger: unexpected error",
            tostring(err) .. "\n\nNo changes were made after this point. Details are in the log file " ..
            "GPSTagger.log (Documents/LrClassicLogs).", "critical")
    end
end)
