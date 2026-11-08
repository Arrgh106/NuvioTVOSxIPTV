# Roadmap

Where the fork stands and what comes next. Updated with every merged pull request.

Legend: ✅ done · 🚧 in progress · ⏭ next · 💡 noted for later

## In progress

- 🚧 **Live TV: groups, favorites, recently watched, search** ([#6](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/6))
  - Group manager with filter ("Only these"), favorites via long press, recently watched, channel search, separator rows hidden.
  - Tested on device: all of it, including the smooth group manager list and the right channel logo when switching channels. Ready to merge.

## Next (in this order)

1. ⏭ **German translations** for all new texts (Live TV, account sync, Trakt/Simkl hints, Jellyfin sync status).
2. ⏭ **Full EPG** from the provider (`xmltv.php`): programme data for many hours ahead, stored on the device.
3. ⏭ **TV guide grid** (TiviMate style): channels down, time across, info panel for a programme.
4. ⏭ **Catch-up / restart** for channels with archive (`tv_archive`).

## Noted for later

- 💡 Separator rows such as `##### AT&T #####`: make hiding them a setting (currently always hidden).
- 💡 Channel list: reorder and rename channels, custom groups, name cleaner.
- 💡 Parental controls (PIN for groups).
- 💡 On Demand (provider movies and series), M3U playlists.
- 💡 Trakt: set `AppRepository.traktBuiltInAppIsRestricted = false` once Trakt grants production access (requested by email); until then only the owner and invited users can use the built-in Trakt app.
- 💡 Simkl: built-in client ID (`AppRepository.simklClientID`) if a Simkl app gets registered.

## Done

| What | PR |
| --- | --- |
| Live TV: channel up/down in the player, now/next EPG in list and player, scrobbling on by default, Jellyfin series indexing fix | [#5](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/5) |
| README logo (light and dark) | [#4](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/4) |
| nuvio.tv sync (API keys, Jellyfin servers, Trakt and trailer options), one-tap Trakt login, Jellyfin live lookup, fast Live TV lists (50k+ channels), IPA without App Group | [#3](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/3) |
| Standalone app "Nuvio IPTV" (own bundle ID), Node 24 workflows | [#2](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/2) |
| Live TV tab: Xtream login, groups, channel list, live playback | [#1](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/1) |

## How to follow progress

- This file: what's done, in progress and next.
- [Pull requests](https://github.com/Arrgh106/NuvioTVOSxIPTV/pulls): one per feature or fix, each with a test build.
- [Issues](https://github.com/Arrgh106/NuvioTVOSxIPTV/issues): bug reports and requests.
