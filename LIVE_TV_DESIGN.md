# Live TV: design concept and build plan

How the Live TV side of the app should look and behave, based on
[Nuvio + IPTV](https://github.com/homelessbrian/NuvioPlusIPTV) for Android TV
(46 screenshots of the running app were reviewed), adapted to tvOS and improved
where tvOS allows it. The plan builds function and design together, one piece at
a time, each piece shippable and testable on its own.

## 1. What Android does (reference)

**Navigation.** The sidebar lists Live TV, Sports, On Demand (and OneTube,
Music) next to Home, Search and Library. Settings has one category per area
(Live TV, On Demand, Sports, …).

**Live TV opens straight into the guide** (TiviMate style), one screen with:

- **Info panel** (top): channel box with logo, the line `number · channel name ·
  playlist`, the programme title in large type, `start – end · time left`, a
  progress bar, the description, and buttons (record, guide settings). A soft
  glow in the theme color sits behind it.
- **Preview window** (top right): the highlighted or last channel plays small
  and live. OK on the previewed channel goes full screen.
- **Three columns** below: groups (Search pill on top, then Favorites,
  Recently watched, All channels, provider groups with counts), channels
  (number, logo, name; the playing channel outlined in the accent color), and
  the **timeline grid** (half-hour header, a "now" line, one cell per
  programme).
- **Guide settings quick menu** (gear): toggles for the info panel parts,
  poster, tags, preview, smaller top, 24-hour clock, background color, with a
  link to all Live TV settings.
- **Activity pill** (bottom right) for background work: "Reading guide …
  17 % · 0:54", "Importing movies … 64,500".

**Settings → Live TV** has four tabs: *Setup* (playlists and guides, channels,
groups, parental controls, sync, help), *Guide* (layout, what the info panel
shows, channel rows, size, now line, badges, clock, highlight style, background,
days ahead and back, time shift, reminders), *Playback* (open on last group,
start full screen, OK behavior, overlay mode, channel up/down scope and
direction, channel surfing, info bar, clock, captions, passthrough, frame rate,
pause and rewind, catch-up, buffer, reconnect, backup channel, recordings) and
*Integration* (Home row, search, On Demand in streams).

**Behavior details worth copying:** focus changes are debounced (moving through
groups only loads the group you stop on, ~400 ms), the guide keeps 24 h back and
3 days ahead, refreshes every 12 h, and Live TV reopens on the last group.

## 2. Concept for tvOS

One Live TV screen, the guide, built from a small set of shared parts. It keeps
Android's structure (users switching between both apps find their way) and uses
tvOS strengths: the focus engine, glass materials, parallax-free calm motion.

### Layout

```
┌──────────────────────────────────────────────────────────────┐
│ INFO PANEL                                        ┌─────────┐ │
│ [logo]  27838 · DE: SAT.1 HD · Strong8k            │ PREVIEW │ │
│ Die Tribute von Panem – The Ballad of …            │  live   │ │
│ 21:14 – 0:29 · 1 h 12 min left   ━━━━━━━━──────    └─────────┘ │
│ Description, two lines …                         ● Rec  ⚙      │
├───────────────┬──────────────┬───────────────────────────────┤
│ 🔍 Search      │ 27836 [logo] │ 21:00   21:30   22:00   22:30  │
│ ★ Favorites    │ 27837 [logo] │ |Mich gibt's nur zweimal |… │  │
│ ⟲ Recent       │ 27838 [logo] │ |Die Tribute von Panem ……|… │  │
│ All channels   │ …            │        ▲ now line             │
│ DE| GENERAL …  │              │                               │
└───────────────┴──────────────┴───────────────────────────────┘
                                         ( activity pill ⟳ … )
```

- **Groups column** collapses to icons when focus is in the grid, giving the
  timeline more room (Android shows it always; on a 1080p TV the grid benefits).
- **Channel column** and **timeline grid** scroll together vertically; the grid
  scrolls horizontally in time.
- **Info panel** follows the focused programme (or channel), debounced so fast
  scrolling doesn't redraw it every step.

### Design tokens (one place, used everywhere)

| Token | Use |
| --- | --- |
| Accent color | Follows the app theme (as Android's "Match Theme"); focus fill, playing-channel outline, now line, progress |
| Glass panels | Info panel, quick menu, activity pill, overlays: tvOS `.regularMaterial`-style blur with a subtle border |
| Type scale | Title 44, programme title 40, row 26, secondary 20–22, badges 16 |
| Row heights | Channel/guide row 88 (standard), 72 (compact size option) |
| Spacing | 8 between rows, 24/40/60 margins |
| Focus | White fill + black text for lists (as now); accent outline for grid cells; 1.02 scale; 0.12 s ease |

### Shared components

1. **GlassPanel**: blur, radius, border; used by every overlay.
2. **ActivityPill**: one queue of background tasks with label, progress and
   elapsed time, shown bottom right on every screen (guide import, channel
   refresh, Jellyfin sync, later On Demand import). Replaces ad-hoc status text.
3. **GuideGrid**: `UICollectionView` with a custom layout: rows = channels,
   x = time, a sticky time header and the now line as supplementary views.
   Only visible cells exist, so 50k channels or a week of listings cost the
   same.
4. **ChannelCell / ProgrammeCell / GroupCell**: the cells already built for the
   lists, extended (badges, progress, playing outline).
5. **InfoPanel**: SwiftUI view fed by the focused item.
6. **PreviewPlayer**: a second, small player surface for the preview window.

### Improvements over Android

- **Fewer settings, better defaults.** Android has 60+ Live TV toggles. We
  start with sensible defaults and expose the ones people actually change in
  the guide's quick menu; the full list lives under Settings → Live TV only.
- **One activity pill** instead of several status texts.
- **Performance budget:** nothing over ~16 ms on the main thread while
  scrolling; all guide reads, imports and image decoding off the main thread
  (already the rule for the lists and the guide import).
- **Preview window is a setting** with a sensible default per device (it runs
  a second decoder; on an Apple TV HD it may cost smoothness).

### Decisions

- **Accent color follows the app theme** ("Match Theme", as on Android).
- **Preview window on by default.** The Apple TV 4K handles a second small
  decoder easily (Android TV sticks with less power do); it stays a setting.

## 3. Build plan

Each step is one pull request with a test build and a short device test list.
Function and design land together; nothing is built "for later".

| # | Step | Function | Design | Test on device |
| --- | --- | --- | --- | --- |
| 0 | **Foundation** | Design tokens, GlassPanel, ActivityPill (wired to the guide import and channel refresh) | Live TV header and status move to the new parts | Status pill appears while the guide loads; lists still smooth |
| 1 | **Guide grid** | GuideGrid from the stored guide: rows = channels of the selected group, time header, now line, programme cells; focus moves left/right through time, up/down through channels; OK plays | Three-column layout (groups · channels · grid) replaces the channel list | Scroll a big group and "All channels" in time and down; no stutter |
| 2 | **Info panel** | Follows the focused programme (debounced), channel line, title, times, time left, progress, description, LIVE/catch-up tags | Glass panel with theme glow; collapsible groups column | Panel updates without lag while scrolling fast |
| 3 | **Preview window** | Highlighted/last channel plays small; OK on it goes full screen; setting on/off | Rounded window top right, accent outline when playing | Smooth on your Apple TV; switching preview channels is quick |
| 4 | **Player info bar & overlay** | OK while watching shows the info bar with now/next and a channel row (recent or favorites); Left shows the guide over the video | Info bar in the same glass style | Zapping, info bar and overlay work with the remote |
| 5 | **Quick menu & Settings → Live TV** | Gear in the info panel: the common guide options; Settings → Live TV with Setup / Guide / Playback / Integration; includes the separator-rows option, 24-hour clock, open on last group, start full screen | Settings follow the app's settings style | Each option changes the guide immediately |
| 6 | **Catch-up / restart** | For channels with archive: play past programmes from the grid, restart the current one | Catch-up tag, past cells selectable | A past show plays from the start |
| 7 | **Reminders & Home row** | Remind me for a programme; Live TV row on Home | Reminder toast in glass style | Reminder fires a minute before |

Later (from the roadmap): guide matching by channel name and "Assign EPG",
reorder/rename channels, parental controls, On Demand, M3U, Sports hub,
recordings (limited by tvOS), German translations.

### How each step is built and tested

1. Look at how Android does it (code and screenshots) before building.
2. Build the function with the final design parts, behind no flags.
3. CI builds the IPA; test on the Apple TV with the step's checklist,
   including fast scrolling for smoothness.
4. Fix, merge, update [ROADMAP.md](./ROADMAP.md).
