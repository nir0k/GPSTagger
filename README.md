# GPS Tagger for Lightroom Classic

Adds GPS coordinates to the selected photos from a GPX track, using the photos' capture time.
You see the result in a preview before anything is written to the catalog.

- Reads GPX 1.x tracks (`<trk>` / `<trkpt>` with `<time>`), for example from COROS, Garmin or Strava exports.
- Every photo taken during the track gets the coordinates (and the elevation, if the track has it) of the **nearest track point in time**. Pauses in the recording and track segments make no difference.
- One **Time offset** field covers both the camera's time zone and a wrong camera clock. A **Detect** button suggests the offset for you.
- **Preview** shows every photo with its status, lets you filter to photos without coordinates and export the table to CSV.
- All changes of one run are a single write to the catalog (one Undo step, see [Known limitations](#known-limitations)).

Works with Lightroom Classic (SDK 6.0 and newer). Tested on Windows; macOS has not been tested yet.

## Install

1. Download `GPSTagger-<version>.zip` from the Releases page and unzip it. You get a `GPSTagger.lrplugin` folder.
2. Put the folder somewhere permanent (Lightroom loads the plugin from there).
3. In Lightroom Classic: **File → Plug-in Manager → Add**, choose the `GPSTagger.lrplugin` folder.

## Use

1. Select the photos in the Library module.
2. **Library → Plug-in Extras → Apply GPS from GPX...**
3. **Browse...** to the GPX file. The *Track info* panel shows its time range and the number of points.
4. Set the **Time offset** (or press **Detect**), see below.
5. Tick **Overwrite existing GPS** if photos that already have coordinates should be changed. Otherwise they are skipped.
6. **Preview** → check the table → **Apply GPS**.

The counters at the bottom of the main window (Matched / Existing GPS / No match) update as you change the settings.

### Time offset

GPX times are always UTC. Lightroom stores the capture time as a plain clock time without a time zone, so the plugin needs to know how the photo times relate to UTC:

```
UTC = capture time - Time offset
```

| Situation | Time offset |
| --- | --- |
| Lightroom shows UTC times | `+00:00:00` |
| Camera set to UTC+2 | `+02:00:00` |
| Camera set to UTC+2, clock 2 s slow | `+01:59:58` |
| Camera set to UTC-4 | `-04:00:00` |

**Detect** tries offsets in 15-minute steps and suggests the one that fits best:

- If at least three of the selected photos already have GPS, the offset that puts them closest to the track wins. This is reliable.
- Otherwise the offset that puts the most photos inside the track's time range wins. A long track and photos taken in a short window can fit several offsets equally well. The plugin then lists them and you choose.

Detect works in whole 15-minute steps. Add seconds by hand if the camera clock is off.

### Preview

| Status | Meaning |
| --- | --- |
| `MATCH` | The photo will get coordinates from the nearest track point. |
| `HAS GPS` | The photo already has GPS and *Overwrite* is off. |
| `OUTSIDE TRACK` | The corrected time is before the first or after the last track point. |
| `NO TIMESTAMP` | The photo has no capture time. |

Use **Without coordinates** to see only the photos that will stay untagged. **Export CSV...** writes the shown rows (with Δ seconds to the nearest point) to a file you can open in Excel.

## Good to know

- GPX points with impossible times (some devices write a point dated days later in the middle of a track) are ignored and counted in *Track info*.
- The plugin never changes capture times or writes into the image files, only the Lightroom catalog.
- Panoramas and HDR merges usually carry the time of the merge, not the shooting time. They will show `OUTSIDE TRACK`; copy the coordinates from the source photos.
- Log file: `Documents/LrClassicLogs/GPSTagger.log`.

## Known limitations

- Column widths in Preview cannot be dragged and the dialogs cannot follow the Windows dark theme: the Lightroom SDK does not offer either.
- Undo: the write is one catalog transaction, but check that **Edit → Undo** works as you expect on your Lightroom version.
- After applying, Lightroom's Metadata panel may keep showing the old GPS value until Lightroom restarts. The coordinates are written; this is a known Lightroom display quirk.
- Only GPX. No FIT/TCX, no map, no reverse geocoding.

## Development

The plugin is Lua for the Lightroom Classic SDK. All modules live in the plugin folder root, because Lightroom's `require` does not find modules in subfolders.

| File | Role |
| --- | --- |
| `Main.lua` | Entry point, flow, error handling |
| `MainDialog.lua`, `PreviewDialog.lua` | Dialogs |
| `Parser.lua` | GPX parsing |
| `Matcher.lua`, `OffsetDetector.lua` | Nearest-point matching, offset detection |
| `Photos.lua`, `MetadataWriter.lua` | Reading photos, writing GPS |
| `CsvExport.lua`, `DateTime.lua`, `Settings.lua`, `Logger.lua` | Helpers |

Everything except the dialogs and the Lightroom access runs on plain Lua, so it is unit-tested outside Lightroom:

```bash
cd GPSTagger.lrplugin
lua tests/run.lua
```

Build the release archive (`dist/GPSTagger-<version>.zip`; the version comes from `Info.lua`):

```powershell
./build.ps1          # build only
./build.ps1 -Test    # run the tests first
```

## License

MIT, see [LICENSE](LICENSE).
