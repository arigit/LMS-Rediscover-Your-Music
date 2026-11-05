# Rediscover Releases (LMS plugin)

A [Lyrion Music Server](https://lyrion.org) plugin that adds a **Rediscover Releases** row to the
[Material skin](https://github.com/CDrummond/lms-material) home screen: random releases from your library that
prefer albums you haven't played for a while.

Unlike Material's *Random Releases*, the list follows clear rules and stays the same between rebuilds:

- Releases **not played for the last N months** come first (N = 12 by default).
- **Unplayed releases** can be included (on by default).
- At least **P % of the list are already-played releases** (20 % by default), so it isn't all unplayed albums.
- Optionally only some **genres**.
- **Partially played releases** count as unplayed (default) or played.
- The list is rebuilt every **H hours** (24 by default), or on demand with **Regenerate List Now**.
- Releases that get **played in full** are removed from the list until the next rebuild.

It only supports the Material skin (the row is a Material "home extra").

## Install

1. In LMS: *Settings → Manage Plugins*, at the bottom under *Additional Repositories*, add

   ```
   https://arigit.github.io/LMS-Rediscover-Your-Music/repo.xml
   ```

   and apply.
2. Back in *Manage Plugins*, enable **Rediscover Releases** (under the third-party plugins) and restart LMS when
   asked.
3. In Material: *Settings → Interface*, under the home screen rows, enable **Rediscover Releases** and drag it to
   where you want it (for example below *Random Releases*). To make that the default for all Material clients and
   apps, use Material's *Save as default* in the same settings dialog.

The list is built about a minute after LMS starts. Its settings are under *Settings → Manage Plugins → Rediscover
Releases* (the gear icon), or in Material's server settings.

## How the list is built

Play data comes from LMS's own statistics (play count and last played time of every track).

- An album with **every track played** counts as played, and its "last played" date is the **oldest** last-played
  date among its tracks. So an album only counts as recently played when all of it has been heard recently.
- An album with **no track played** is unplayed.
- An album with **some tracks played** follows the *Partially played releases are assumed as* setting. As played,
  the date is the oldest last-played date among its played tracks.

Then, for a list of *count* releases:

1. At least *count × P %* releases are taken at random from the played releases not played within the period. If
   there aren't enough, the least recently played of the others make up the share.
2. The rest is drawn at random from the remaining not-recently-played releases and (if included) the unplayed ones.
3. If the library still doesn't have enough, the least recently played releases fill the list.
4. The list is shuffled.

With a genre selection, a release is included if any of its tracks has one of the genres.

**Played in full.** When a song of a listed release starts, the release is marked. A few minutes later (and
before the list is served to a client) the marked releases are checked: one whose tracks have all been played
since the list was built is removed. Material's home screen is told to refresh. This is a cleanup, not a rebuild:
removed releases aren't replaced until the next rebuild.

**Library rescans.** A full rescan gives albums new IDs. After a scan, releases that no longer exist are dropped;
if most of the list is gone, it is rebuilt.

## Settings

| Setting | Range | Default |
|---|---|---|
| Number of releases to include in the Rediscover list | 10–1000 | 250 |
| Prioritize inclusion of releases not played for the last … months | 1–99 | 12 |
| Include unplayed releases in the list | on/off | on |
| Ensure that at least … % of already-played releases are included | 0–100 | 20 |
| Include the selected genres | all, or any genres of the library | all |
| Partially played releases are assumed as | Unplayed / Played | Unplayed |
| Rebuild the Rediscover list every … hours | 1–999 | 24 |

Saving changed list settings rebuilds the list. **Regenerate List Now** rebuilds it at once.

## For other clients (CLI / JSON-RPC)

Other apps can show the same list. All queries work without a player.

- `rediscoverreleases albums <start> <count> [tags:<tags>] [library_id:<id>]`: the list in its order, with the
  fields LMS's own `albums` query returns for these tags (default `ajlsy`). Also returns `count` (list size),
  `version` (changes on every rebuild or cleanup) and `built` (epoch seconds). With `library_id`, only the listed
  albums that are in that virtual library.
- `rediscoverreleases status`: `plugin_version`, `count`, `version`, `built`, `next` (next scheduled rebuild).
- `rediscoverreleases regenerate`: rebuild now.

To check that the plugin is installed: `can rediscoverreleases albums ?` returns `_can: 1`.

Example:

```sh
curl -s http://<lms>:9000/jsonrpc.js \
  -d '{"id":1,"method":"slim.request","params":["",["rediscoverreleases","albums",0,10,"tags:ajly"]]}'
```

The Android Auto support of the
[lms-material-app (ar) fork](https://github.com/arigit/lms-material-app) uses this for its *Rediscover Albums* list.

## Development

- Plugin source: `RediscoverReleases/`.
- Tests of the list logic, run in the LMS Docker image against copies of a library database:
  `t/run.sh <library.db> <persist.db>` (the files are copied first; `cache/library.db` and `prefs/persist.db`
  from an LMS data folder).
- Releasing: bump `<version>` in `RediscoverReleases/install.xml`, commit, then `tools/release.sh`. It builds
  `releases/RediscoverReleases-<version>.zip`, updates `repo.xml` (version, URL, SHA-1), commits, tags `v<version>`,
  pushes and creates the GitHub release. GitHub Pages serves `repo.xml` and the zip from `main`.

## License

GPL-3.0, see [LICENSE](LICENSE).
