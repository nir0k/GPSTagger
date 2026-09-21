-- Persistent settings (time offset, overwrite). GPX path is not stored.
local LrPrefs = import "LrPrefs"

local Settings = {}

Settings.defaults = {
    timeOffset = "+00:00:00", -- camera time minus UTC
    overwrite = false,
}

function Settings.load()
    local prefs = LrPrefs.prefsForPlugin()
    local s = {}
    for k, default in pairs(Settings.defaults) do
        local v = prefs[k]
        if v == nil then v = default end
        s[k] = v
    end
    return s
end

function Settings.save(s)
    local prefs = LrPrefs.prefsForPlugin()
    for k in pairs(Settings.defaults) do
        prefs[k] = s[k]
    end
end

return Settings
