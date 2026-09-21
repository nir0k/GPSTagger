return {
    LrSdkVersion = 6.0,
    LrSdkMinimumVersion = 6.0,

    LrToolkitIdentifier = "net.mutted.lightroom.gpstagger",
    LrPluginName = "GPS Tagger",
    LrPluginInfoUrl = "https://github.com/nir0k/GPSTagger",

    LrLibraryMenuItems = {
        {
            title = "Apply GPS from GPX...",
            file = "Main.lua",
            enabledWhen = "photosSelected",
        },
    },

    VERSION = { major = 1, minor = 0, revision = 0 },
}
