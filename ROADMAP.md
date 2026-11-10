# Roadmap

Where the fork stands and what comes next. Updated with every merged pull request.

Legend: ✅ done · 🚧 in progress · ⏭ next · 💡 noted for later

## In progress

- 🚧 **Live TV guide, step 4b: guide over the video** (see below). Step 4a is in its own pull request.

## Next: Live TV guide, step by step

Design concept and plan: [LIVE_TV_DESIGN.md](./LIVE_TV_DESIGN.md) (based on Nuvio + IPTV for Android TV, adapted to tvOS).

0. ✅ **Foundation**: design tokens, glass panel, activity pill for background work. Channels load one request after another (no more HTTP 404 right after sign-in).
1. ✅ **Guide grid**: groups · channels · timeline with now line (TiviMate style). Two-hour window in half-hour steps, Right/Left move through the programmes; Left on now goes to the channel, then to the groups (fast presses and swipes stop on the way); back from the player on the channel watched last; programmes come from the stored guide for visible rows only, short EPG for channels the guide doesn't cover. Timeline logic has Linux tests in CI.
2. ✅ **Info panel**: glass panel above the guide with the channel line (LIVE / CATCH-UP tags), the programme under the cursor, times with time left, progress and description; follows focus after a short rest, so scrolling stays smooth.
3. ✅ **Preview window**: OK plays a channel small in the info panel, OK again makes the same picture full screen (one player, one stream: fine for accounts with a single connection). Up/Down switch channels in full screen, Menu goes back to the guide on the channel playing. Leaving Live TV stops playback.
4. 🚧 **Player info bar & overlay**
   - ✅ 4a: info bar in full screen (channel line, what's on with time left and progress, clock, up next) and the channel row of recently watched channels. Full screen is an app-level screen like the film player: no sidebar, no tab bar, one picture layer shared with the preview. Remote: Up/Down switch channels, Right shows the bar, OK opens the channel row, Left/Menu go back to the guide on the channel playing. Entering the guide from the groups or the header lands on the channel.
   - ⏭ 4b: Left in full screen opens the guide over the video.
5. ⏭ **Quick menu & Settings → Live TV** (incl. separator rows option, 24-hour clock).
6. ⏭ **Catch-up / restart** for channels with archive.
7. ⏭ **Reminders & Home row**.

## Noted for later

- 💡 **German translations** for all texts (Live TV, account sync, calendar, Usenet, player, ...). Prepared, not applied: English first so the app works for everyone.
- 💡 Guide matching by channel name for channels without a guide id (Android does this), and choosing a guide by hand per channel ("Assign EPG"); extra XMLTV sources.
- 💡 Separator rows such as `##### AT&T #####`: make hiding them a setting (currently always hidden).
- 💡 Channel list: reorder and rename channels, custom groups, name cleaner.
- 💡 Parental controls (PIN for groups).
- 💡 Groups column that narrows while the guide has focus (planned for step 2, left out so the focus flow stays as tested); more rows by a slimmer Live TV header.
- 💡 Guide focus: fine-tune the pause before Left goes on to the groups / sidebar (0.45 s now), if it feels slow or fast in daily use.
- 💡 On Demand (provider movies and series), M3U playlists.
- 💡 Trakt: set `AppRepository.traktBuiltInAppIsRestricted = false` once Trakt grants production access (requested by email); until then only the owner and invited users can use the built-in Trakt app.
- 💡 Simkl: built-in client ID (`AppRepository.simklClientID`) if a Simkl app gets registered.

## Done

| What | PR |
| --- | --- |
| Live TV: full guide (`xmltv.php`) in SQLite, 233,000 programmes in 5–10 s; CI package cache and retries; design concept | [#7](https://github.com/Arrgh106/NuvioTVOSxIPTV/pull/7) |
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
