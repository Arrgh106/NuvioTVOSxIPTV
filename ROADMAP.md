# Roadmap

Where the fork stands and what comes next. Updated with every merged pull request.

Legend: ✅ done · 🚧 in progress · ⏭ next · 💡 noted for later

## In progress

- 🚧 **Full EPG** from the provider (`xmltv.php`): programme data 24 h back to 3 days ahead, stored on the device ([branch](https://github.com/Arrgh106/NuvioTVOSxIPTV/tree/feature/livetv-full-epg)).

## Next: Live TV guide, step by step

Design concept and plan: [LIVE_TV_DESIGN.md](./LIVE_TV_DESIGN.md) (based on Nuvio + IPTV for Android TV, adapted to tvOS).

0. ⏭ **Foundation**: design tokens, glass panel, activity pill for background work.
1. ⏭ **Guide grid**: groups · channels · timeline with now line (TiviMate style).
2. ⏭ **Info panel**: focused programme with times, progress, description.
3. ⏭ **Preview window**: small live picture of the highlighted channel.
4. ⏭ **Player info bar & overlay**: now/next, channel row, guide over the video.
5. ⏭ **Quick menu & Settings → Live TV** (incl. separator rows option, 24-hour clock).
6. ⏭ **Catch-up / restart** for channels with archive.
7. ⏭ **Reminders & Home row**.

## Noted for later

- 💡 **German translations** for all texts (Live TV, account sync, calendar, Usenet, player, ...). Prepared, not applied: English first so the app works for everyone.
- 💡 Guide matching by channel name for channels without a guide id (Android does this), and choosing a guide by hand per channel ("Assign EPG"); extra XMLTV sources.
- 💡 Separator rows such as `##### AT&T #####`: make hiding them a setting (currently always hidden).
- 💡 Channel list: reorder and rename channels, custom groups, name cleaner.
- 💡 Parental controls (PIN for groups).
- 💡 On Demand (provider movies and series), M3U playlists.
- 💡 Trakt: set `AppRepository.traktBuiltInAppIsRestricted = false` once Trakt grants production access (requested by email); until then only the owner and invited users can use the built-in Trakt app.
- 💡 Simkl: built-in client ID (`AppRepository.simklClientID`) if a Simkl app gets registered.

## Done

| What | PR |
| --- | --- |
| Live TV: hide groups, favorites, recently watched, channel search, separator rows hidden, smooth group manager, right logo when switching channels; README and roadmap | [#6](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/6) |
| Live TV: channel up/down in the player, now/next EPG in list and player, scrobbling on by default, Jellyfin series indexing fix | [#5](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/5) |
| README logo (light and dark) | [#4](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/4) |
| nuvio.tv sync (API keys, Jellyfin servers, Trakt and trailer options), one-tap Trakt login, Jellyfin live lookup, fast Live TV lists (50k+ channels), IPA without App Group | [#3](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/3) |
| Standalone app "Nuvio IPTV" (own bundle ID), Node 24 workflows | [#2](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/2) |
| Live TV tab: Xtream login, groups, channel list, live playback | [#1](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/1) |

## How to follow progress

- This file: what's done, in progress and next.
- [Pull requests](https://github.com/Arrgh106/NuvioTVOSxIPTV/pulls): one per feature or fix, each with a test build.
- [Issues](https://github.com/Arrgh106/NuvioTVOSxIPTV/issues): bug reports and requests.
