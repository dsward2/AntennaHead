# Sharing tuning data

**File > Export Tuning Data…** saves selected categories and favorites as a JSON
file; **File > Import Tuning Data…** merges such a file into your own data. The
typical use is swapping local frequency lists with other listeners in the same
area, so the export window has optional *Title*, *Region* and *Notes* fields
that travel with the file.

## Export

Pick categories (each brings its scan settings and all of its favorites) and/or
individual favorites. "Select All" gives you everything shareable.

Never exported: USB device strings (they name one specific dongle), custom
tasks (they define processes to run) and app settings. The bias-tee flag is
written for information only.

## Import

Importing never writes anything until you press **Import**, and the defaults
never overwrite your data. The review window compares every item with what you
already have:

| Item | Match rule | Default |
|---|---|---|
| Category | same name (case-insensitive) | new → **Add**; identical → **Merge**; different settings → **Merge into mine** (add their favorites, keep my scan settings) |
| Favorite | same tuning: mode + frequency + scan end + modulation | new → **Add**; identical → **Keep mine**; same tuning but different name/settings → **Keep both** |

Other choices for a conflict are *Use theirs* (overwrite that one favorite),
*Keep mine*, or for a category *Use their settings*, *Keep both* (a renamed
copy, "Name (imported)") or *Don't import*. Category membership is only ever
added, never removed.

Safety:

- A timestamped backup of the database is saved to
  `~/Library/Application Support/AntennaHead/Backups/` before anything changes
  (the newest ten are kept), and the whole import is one transaction.
- Imported items always get **bias-tee off** and a blank USB device string.
- Every field is range-checked. Names lose control characters; `options`
  tokens (passed to `rtl_fm -E`) and audio filters (sox effect chains) are
  limited to plain letters, digits and a few punctuation marks. Records that
  fail validation are listed in the review window and left out.
- Files over 5 MB, with more than 5000 favorites or 500 categories, or from a
  newer format version are refused.

## File format (version 1)

```json
{
  "format": "antennahead-share",
  "version": 1,
  "exported_at": "2026-09-20T22:00:00Z",
  "app_version": "1.0",
  "title": "Central Arkansas favorites",
  "region": "Little Rock, AR",
  "notes": "Verified with an RTL-SDR Blog V3",
  "categories": [
    { "name": "Aviation", "category_scanning_enabled": 0, "scan_tuner_gain": 49.5, "…": "…" }
  ],
  "favorites": [
    { "station_name": "KUAR 89.1", "frequency": 89100000, "modulation": "fm",
      "categories": ["FM Broadcast"], "…": "…" }
  ]
}
```

Field names match the database columns. Rows are identified by content (category
name, tuning), never by database ID. Unknown fields are ignored.
