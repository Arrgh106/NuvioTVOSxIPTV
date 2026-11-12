# Roadmap

Where the fork stands and what comes next. Updated with every merged pull request.

Legend: ✅ done · 🚧 in progress · ⏭ next · 💡 noted for later

## In progress

- Nothing right now: step 10 is done, the next step is being chosen.

## Next: Live TV guide, step by step

Design concept and plan: [LIVE_TV_DESIGN.md](./LIVE_TV_DESIGN.md) (based on Nuvio + IPTV for Android TV, adapted to tvOS).

0. ✅ **Foundation**: design tokens, glass panel, activity pill for background work. Channels load one request after another (no more HTTP 404 right after sign-in).
1. ✅ **Guide grid**: groups · channels · timeline with now line (TiviMate style). Two-hour window in half-hour steps, Right/Left move through the programmes; Left on now goes to the channel, then to the groups (fast presses and swipes stop on the way); back from the player on the channel watched last; programmes come from the stored guide for visible rows only, short EPG for channels the guide doesn't cover. Timeline logic has Linux tests in CI.
2. ✅ **Info panel**: glass panel above the guide with the channel line (LIVE / CATCH-UP tags), the programme under the cursor, times with time left, progress and description; follows focus after a short rest, so scrolling stays smooth.
3. ✅ **Preview window**: OK plays a channel small in the info panel, OK again makes the same picture full screen (one player, one stream: fine for accounts with a single connection). Up/Down switch channels in full screen, Menu goes back to the guide on the channel playing. Leaving Live TV stops playback.
4. ✅ **Player info bar & overlay**
   - ✅ 4a: info bar in full screen (channel line, what's on with time left and progress, clock, up next) and the channel row of recently watched channels. Full screen is an app-level screen like the film player: no sidebar, no tab bar, one picture layer shared with the preview. Remote: Up/Down switch channels, Right shows the bar, OK opens the channel row, Left/Menu go back to the guide on the channel playing. Entering the guide from the groups or the header lands on the channel.
   - ✅ 4b: Left in full screen opens the guide over the picture (TiviMate's overlay mode): the group's channels with what's on, the highlighted channel's shows and the details; Left again the groups. OK plays a channel (its group becomes the one zapped through), Menu closes, it closes itself after 15 s. Swipes scroll by how far and fast the finger moves; only the rows on screen are drawn. Right opens the highlighted channel's schedule, Right again its dates (step 6).
5. ✅ **Quick menu & Settings → Live TV**: the gear in the header opens the guide's quick menu over the guide; Settings → Live TV in the app's settings style. Per profile, every change shows at once. Guide: info panel, description, preview window (off: OK goes straight to full screen), smaller top, channel counts, hide separator rows (off by default), clock (system, 24-hour, 12-hour). Playback: open on last group, info bar when switching, reverse channel up/down. Account and groups stay in Live TV's header for now; Integration comes with the Home row (step 7).
6. ✅ **Catch-up / restart** for channels with archive: in the guide OK on a past show plays it from the archive (↺ marks the shows that can), long press OK on the show on now offers *Watch from the beginning*. In the full-screen overlay Right opens the channel's schedule (days with headings, lands on the show on now), Right again the dates; OK on a past show plays it, on the show on now goes live. In a replay ◀/▶ jump 10 s back / 30 s ahead, Up/Down go back to live channels. Play/Pause pauses live and replays; pressed again in a replay it asks: *Continue watching* or *Back to live*. Catch-up links follow the Android app (several URL forms tried in turn).
7. ✅ **Reminders & Home row**
   - ✅ 7a: reminders as on Android. OK (or long press) on a show to come in the guide or the overlay schedule: *Remind me* / *Cancel reminder*; a bell marks it. A minute before the start a prompt comes up over any screen (also over a film) with *Watch* (Live TV full screen on the channel) and *Dismiss*; gone after two minutes. Per profile; listed in Settings → Live TV → Reminders, select one to remove it.
   - ✅ 7b: Live TV row on Home, below Continue Watching: favorite channels (recently watched while there are none, or by choice) with what's on, progress and time left. A card in focus shows the channel, the show with times, what's next and the description above the rows, on a dark background. OK plays full screen, Up/Down go through the row's channels. Settings → Live TV → Integration: on / off and the channels.
   - Profiles: Live TV (row, reminders, options, guide) and the Jellyfin / SMB libraries reload when switching profiles; new profiles no longer get a copy of the Jellyfin servers.
8. ✅ **Guide matching**
   - ✅ 8a: channels without a working guide id are matched by name, as on Android ("DE: Sky Cinema HD" = "Sky Cinema": prefixes, HD / FHD / 4K and brackets don't count). Chosen by hand first, then the guide id, then the name; only guide channels with programmes. The guide is read again once after the update.
   - ✅ 8b: *Assign EPG* (long press on a channel in the guide): suggestions with the closest names, search over all guide channels, *Automatic* or *No guide*. Per profile; the guide is read again after a change.

9. ✅ **Extra XMLTV guides** (as Android's EPG sources): Settings → Live TV → Guide Sources. Add a guide by link (`.xml` or `.xml.gz`, unpacked on the device in steps, the link kept in the Keychain), turn it on or off, move its listings by −12 to +12 hours in half hours. The provider's own guide can be turned off. All guides are read into one guide; each channel takes, as on Android, a choice by hand first, then real listings over placeholders ("No information" …), an id match over a name, the one going furthest ahead, the added guide before the provider's. Each guide shows how many programmes and channels it brought, or why it failed; one guide failing doesn't stop the others. *Assign EPG* lists the channels of all guides. Per profile. After saving a guide, *Update the guide now?* (also without Live TV open). The downloaded files are kept: a choice in *Assign EPG* is written at once when its programmes are stored already (or *No guide*), otherwise the kept files are read again without downloading.
10. ✅ **Channel list editing** (as Android's "Edit channel" and "Hide & arrange"), in three parts:
   - ✅ 10a: *Rename Channel* and *Rename Group* (long press in the guide or the groups); empty goes back to the automatic name. Settings → Live TV → Channel List: *Name Cleanup* takes words off the start or end of channel names, as on Android ("USA: ESPN HD" → "ESPN", never in the middle, never the whole name; a word with only a space after it counts when 5+ channels start with it), *Add Common Prefixes & Suffixes*, *Also Clean Group Names*, resets. Guide matching and Assign EPG keep the provider's names; search finds the new ones. The guide relabels in place, focus stays. Per profile. The settings sheet for a guide source now looks like the other settings sheets (Jellyfin, SMB).
   - ✅ 10b: *Reorder Channels* (long press a channel; every group but Search and Recently watched, Favorites included) and *Reorder Groups* (long press a group; Search, Favorites, Recent and All stay on top). OK picks one up (framed), move freely to the new place (fast through long lists, unlike Android's step by step), OK puts it there; Back saves. As on Android, a channel or group the provider adds later goes right behind the one above it, not to the end. Resets in Settings → Live TV → Channel List. Going back to the provider's name no longer counts as a rename.
   - ✅ 10c: your own groups, as Android's custom groups. Long press a channel → *Add to Group…*: one of yours, or a new one made with it. Channels go in by reference (they stay in their own group, also ones from hidden groups) and get their guide. Your groups sit above the provider's and *Reorder Groups* arranges them together. In one of your groups: *Remove from This Group* and *Reorder Channels*. Long press a group: *Rename Group*, *Delete Group* (asks first), *New Group*. Settings → Live TV → Channel List → *Delete My Groups*. Per profile. A channel taken out of a list (your group, Favorites) leaves animated, focus moves on to the next one.

## Noted for later

- 💡 **German translations** for all texts (Live TV, account sync, calendar, Usenet, player, ...). Prepared, not applied: English first so the app works for everyone.
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
