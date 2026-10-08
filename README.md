# OW Editor — app

Flutter app to upload a match recording, follow the analysis and watch the
rendered videos. **Mobile-first**, but it runs on the web: on wide screens the
content stops stretching and stays centred instead of becoming one giant line.

> All commands below assume you are **inside `frontend/`**.

---

## Running

```bash
flutter pub get
flutter run -d chrome        # or: flutter run -d <your-android>
```

It needs the backend up. Start it with `cd ../backend && python tools/dev.py`.

## Building for production

```bash
flutter build web --dart-define=API_BASE=
```

With an **empty** `API_BASE`, the app calls the API on a relative path — then the
gateway itself serves the app at `/`, on the same origin, with no CORS involved
and no need to rebuild for each environment. The root `docker-compose.yml`
mounts `build/web` into the gateway automatically.

To point at a backend on another host:

```bash
flutter build web --dart-define=API_BASE=https://my-server.example
```

## Testing

```bash
flutter analyze
flutter test
```

### In a real browser (`e2e/`)

Widget tests simulate gestures; these drive the web build in Chromium with a
real mouse, keyboard and touch: a moment dragged onto the ruler, a cut moved,
trimmed and taken to another layer, Ctrl+Z, Alt+arrows, the phone layout.
The server is not needed: `e2e/tests/mock_api.js` answers the API inside the
browser with one finished match and keeps what the editor saves.

```bash
flutter build web --no-web-resources-cdn --dart-define=API_BASE=
cd e2e
npm install
npx playwright install chromium   # once, if Playwright has no browser yet
npx playwright test
```

The page is one canvas, so the tests find things through Flutter's semantics
tree — the same labels a screen reader hears ("Kill, layer 1, from 00:00 to
00:01, 1.2 seconds"). Renaming one of those labels means updating the test
that looks for it.

---

## Screens

| File | Screen |
|---|---|
| `screens/jobs_screen.dart` | list of matches, with live status while a job is running |
| `screens/new_job_screen.dart` | **stage 1**: pick the recording and tune the analysis parameters. No music here |
| `screens/job_detail_screen.dart` | analysis progress, a timeline with the detected moments and the history of requests with the videos of each |
| `screens/timeline_screen.dart` | **stage 2, the editor**: put music and moments on the ruler, each wherever you want and as long as you want |
| `screens/player_screen.dart` | clip player |

The app follows the backend's two-stage split. First the match is analysed:
the detectors mark the moments (kills, Ana's sleep dart, Sigma's stun,
ultimates, low health…) and the job stops at `ready`. The system **does not
build videos on its own**: from there, whoever edits opens the editor, builds
and requests a render, as many times as they want. Each request shows up in the
history with its clips, and using a moment in one montage does not use it up for
the others.

A montage without music becomes a video with the original match audio, and the
interface says so instead of leaving the user to guess.

### Text the system writes

`labels.dart` is what sets this editor apart, and it is not in ffmpeg: it is in
the editor **knowing what happened in the video**. For anyone else, the video is
a rectangle of pixels with no story.

- a **kill counter** that goes up on its own, each number lasting until the
  next kill cut;
- **streak labels** with the game's names — `TRIPLE KILL`, not "3 kills".

Both come out as plain text clips: the generator is a shortcut, not a new
entity. Text goes into a new layer when only one exists, because text almost
always goes over the picture.

### Effects

The selected block has a collapsed effects panel: **speed**, **fade** in and
out, and **colour** (brightness, contrast, saturation). It is collapsed because
most montages are hard cuts, and an always-open panel would push the ruler off
the screen.

Speed does not shrink the block: it changes how much of the recording goes into
it. Two seconds at 2× eat four seconds of match, and still take two seconds of
the video.

Fades longer than the clip are shrunk here, keeping the in/out proportion — the
server would refuse them, and finding that out only at render time would be
worse.

**Zoom in** is the *punch* on the beat, in three buttons: the lens closes fast
and loosens until the end of the block. The animation points are fractions of
the clip, so stretching the block does not undo the effect.

**Freeze** and **reverse** exclude each other — turning one on turns the other
off, which is what turning on the second one meant.

The **mix** belongs to the whole montage: with the game at zero the music plays
alone; above that the gunfire comes through under it.

### Transitions

The **Transitions** tab in the sidebar sets how the selected clip enters over
the previous one on the same layer: dissolve, dip to black or white, or a slide
from any side. The transition belongs to the clip that **enters**, so moving the
clip takes it along, and it is never longer than the clip.

### Output

The **Output** panel edits nothing. Switching 16:9 for 9:16 does not move a
clip — it changes the window onto the same work, so you can go back and forth
freely (and undo it, like any other choice).

Five formats and three qualities, and nothing more: a list with every resolution
H.264 accepts helps nobody decide. The summary on top says what will really come
out — size, duration and a guess at the weight. It really is a guess, and it
answers "will this be 8 MB or 800?", which is the question you ask before
exporting.

**Fill** or **contain** only shows up when the requested proportion differs
from the recorded one: until then there is nothing to decide. And **selection
only** exports from the first to the last selected block — to check a
two-second seam without waiting for five minutes of video.

The **watermark** comes from the library: any image there, in one of the four
corners.

### Montages, versions and presets

The screen title is the **montage picker**: in a match with three, knowing which
one is open matters more than reading "Build video" for the tenth time. Through
it you switch montages and start another; the menu brings duplicate, rename,
delete, the history and the presets.

Switching montages **clears the undo history**. It is the memory of a work
session *on one* montage — undoing into another would erase what was just
opened.

The first montage is only created when there is something to save: opening the
editor and closing it untouched leaves no junk in the list.

`recipe.dart` applies presets, and goes the other way too. Applying a recipe
produces a regular montage — after that each block moves and trims like any
other. Reading a recipe from the montage on screen uses the **median** of the
cuts, not the mean: a block stretched to the end of the song would pull the mean
far from what all the others are. And if the cuts take a round number of beats,
the length is stored in beats — so the preset survives a song with another
tempo.

### Media library

The sidebar has tabs for **Moments**, which the system found, and **Library**,
what the user brought from outside — video, image or music. They sit side by
side because they answer the same question: "what do I put in now?".

A library item becomes a clip like any other. An image has no duration of its
own — how long it stays on screen is the montage's choice —, and from a long
video you use a piece, not all of it.

**Music comes in through here, and only through here.** There used to be a panel
just for it, and having two doors for the same thing is what made it look like
there were two kinds of sound — with different rules. `Track` and audio `Media`
were always the same database row (`Media.asMusic` bridges them); now they are
also the same path on screen.

Removing from the library an item that is in the montage is refused: the clip
would be orphaned and the server would reject the request.

### Layers

The timeline has stacked **layers**: the first in the list is the background,
the last is on top — the same order the server draws them in. They are called
layers, not tracks, because `Track` in this system is already the uploaded song.

On the ruler they show up **inverted**, on purpose: the top row is the top
layer, like in any editor (`MusicTimeline.rowLayer` does the maths). Without
that, dragging a layer to the top sent it behind all the others — which only
started to hurt once reordering became a gesture.

The order is changed by dragging the header: there is a **handle** (immediate
drag, for the pointer) and a long press on the whole header, for the finger.
Reordering is an edit like any other — it changes what shows, and goes into
undo.

Each layer's header stays **outside the scroll** — it is the reference, and has
to stay visible when the ruler moves. On it: hide, mute and lock. Hide and mute
change the video; lock is just the screen refusing edits.

Collision is **per layer**. Two clips at the same instant on different layers is
precisely what layers are for.

Dragging a clip up or down moves it to another layer, keeping the instant — and
refuses if the place is taken there, because pushing it to another instant would
change two things when one was asked. **The refusal speaks**: a sound layer does
not take pictures, a locked layer takes nothing, and a taken instant is a taken
instant. Refusing silently is the worst of both worlds — the block goes back and
whoever dragged it cannot tell whether the gesture missed or the operation was
impossible.

A layer is **picture** or **sound** (`kind`), never both: the sound one draws
nothing, and what goes in it is music from the library — see *Music on the
ruler*. Its header shows a music note and no hide button, since there would be
nothing to hide.

The monitor does not composite: it shows one frame. So where two layers overlap,
it shows the top one (`visibleClips`), which is what the server draws last.

### The montage screen

The other path: instead of accepting the system's guess, the user builds. The
song goes up through the library — without hearing it there is no way to decide
where a cut lands — and comes back from the server with duration, BPM, beats and
an already reduced waveform, which is what each music block draws inside itself
in `widgets/music_timeline.dart`. The match moments show up as cards; tapping
one places the block at the playhead, dragging it places it where it was
dropped.

After that it is editing, with the three gestures of any editor: dragging the
body of the block **moves** it, the right edge **stretches** and the left one
**trims**. The magnet (at the top of the screen) snaps the edges to the nearest
beat. Space left between two blocks becomes **black screen**, with the music
playing if there is a sound block there — the screen says how much, because it
counts in the video duration.

> **The drag that did not drag.** The first version applied `delta.dx` frame by
> frame on top of the current value. With the magnet on the block was already
> *on* a beat, so each 3px step became 0.05 s and was snapped back to the same
> beat: the block only moved with a flick strong enough to beat the tolerance in
> a single frame. Now each gesture remembers where it started and accumulates
> the whole offset, and the magnet decides on the intent of the drag, not on a
> pixel. The tests that lock this down drag in 3px steps on purpose —
> `tester.drag` delivers the movement in two big jumps, and with big jumps even
> the broken code passed.

The screen has an editor layout from 900px wide: the moment shelf on the left
(each one with the match frame at that instant), a resizable monitor on top and
the ruler below. Below that width it becomes a single column, with the shelf
after the ruler — the app still works on a phone.

Inside each block there is a **mark** at the point where the play happens
(`momentMark`). A block is a span, the moment is an instant inside it; what
lines up with the percussion is the play, and the edge of the cut may be half a
second before it. Trimming the block from the left moves the mark — it is drawn
from the cut, never deduced.

The **beat grid** is adjustable: offset, density (½ / 1× / 2×) and snapping to
the bar. The rhythm detector fails in two predictable ways — it picks the
off-beat, or counts double/half the beats —, and neither is fixed by dragging
block by block: what is wrong is the ruler. The adjustments live in the draft
and are undone like any edit.

The ruler is the time of the **output video**: instant zero is its first frame.
The music lives inside that scale, in blocks.

### Music on the ruler

Music lives on a **sound layer** — an `audio` layer, which draws nothing and does
not take part in the visual stacking. Its blocks are regular clips with a
`mediaId` pointing at a library item, and being regular clips they already know
how to cut, move, trim and duplicate: there was no new object to invent, just
music to stop being special.

`putMusic` places a block at the playhead (or where the finger dropped it);
where there is already music, the new block goes **after** what is there,
instead of pushing what was already fitted to the beat. Without a sound layer,
one is created — asking for music and getting a request for a layer would be red
tape.

There used to be a **continuous track** that played under everything and could
not be cut. `montageFromDraft` still reads it: `trackId` + `musicStartS` become a
block that starts where it came in and covers the whole video, and `toJson`
never writes the two fields again — sending them back would create a second
song under the one that already became a block.

`visibleClips` skips sound layers — taking them into account would erase the
video underneath — and `moveToLayer` refuses moves between sound and picture
layers, which the server would refuse anyway.

The **beat grid** is that of the song playing under the playhead, brought to
video time by discounting the part of the track left out. A video with two
tracks has two tempos, and snapping to the other one's beat would be worse than
not snapping at all.

The selected block's panel changes subject when the block came from the
library: it says the file name, and for music, which point of it the piece came
from; it calls the offset "song span" and hides the effects — zoom, freeze and
colour have nothing to act on in a block that draws nothing.

### The play inside the block

`momentInVideo` says where the play lands in the video:
`atS + (sourceT - startS)`. Three things work off it.

`alignMoment` puts that play at a requested instant, and has **two paths**:
moving the block (keeps the run-up, changes when the scene shows up) or sliding
the span inside it (keeps the position on the ruler, changes which piece of the
recording shows). The second is what is left when the neighbours do not let the
block through — the common case in a montage of back-to-back blocks —, and the
result says which of the two happened, so the screen can tell.

The magnet in `move` weighs three candidates: start, end and play. Only those
that snapped to some beat count, and the one closest to where the finger dropped
wins.

And the mark drawn inside the block lights up when the play is under the
playhead — half a frame of tolerance, because aligning is a montage decision,
not an infinitely precise measurement.

### Text on the monitor

Text existed on the ruler and in the rendered video, and nowhere in between: to
know where the phrase would land you had to render the video. The monitor now
draws the active text clips with the **same maths as the server** — size as a
fraction of the frame height, position in half-frames from the centre, outline
included — and dragging them there writes `transform.x/y` (`positionOnFrame`).

What a text says is typed **on the monitor itself**: tapping the selected text
(or the panel's "Type on the video" button) opens a field over the frame, and
the whole typing session is a single undo step.

Two details that cost debugging:

- the monitor notices (black screen, loading) sit in `IgnorePointer`. They live
  in the middle of the frame, which is exactly where text usually is, and a
  `CustomPaint` answers `true` to hit testing by default — the spinner stole the
  phrase drag;
- the gesture uses `DragStartBehavior.down` and adds up `d.delta`. With the
  default (`start`) the offset spent beating the slop is discarded, and a drag
  delivered all at once — a fast finger, or a test — produces no update at all.

### Dragging from the shelf to the ruler

Clicking a moment or a library item places the block at the playhead — handy
for building in order. Dragging places it **where the finger dropped it**, on
the row it was dropped on.

Both sides are `Draggable<RulerDrop>` with `affinity: Axis.horizontal` (the
shelf keeps scrolling vertically) and `pointerDragAnchorStrategy`: the ghost
hangs from the finger, not from the point of the card where it was grabbed,
because `DragTargetDetails.offset` is the ghost's corner — without that the
block lands half a card to the left of where it was dropped.

The ruler is a `DragTarget` that turns the global position into (instant,
layer) and draws a block-sized rectangle before dropping. Dropping music on a
picture row is not an error: it means "at this instant", and it goes to the
sound layer. Dropping a moment on a sound layer is.

### The keyboard

Shortcuts are single keys where that makes the editor fly: **S** splits at the
cursor, **space/K** plays, **J/L** move, **[** and **]** trim the ends,
**Delete** deletes the selected block. Ctrl/Cmd cover undo, copy, paste,
duplicate and select all — both registered, so there is no "why does it not work
here".

While someone is typing in a field, **no shortcut is registered** — the
`bindings` map is empty. The difference between that and "a shortcut that does
nothing" is the whole point: `CallbackShortcuts` marks the key as handled as
soon as some shortcut accepts it, whatever it does, and in the browser a handled
key becomes `preventDefault`. The first attempt at a fix silenced the action and
kept the registration; the result was the worst of both worlds — "s" stopped
splitting the cut and still was not typed.

Two pieces complete it:

- **who has focus** comes from `findAncestorStateOfType<EditableTextState>()`
  from the primary focus. Looking for the `EditableText` *widget* worked in
  tests and failed in the browser release build, where type names are minified
  — and failing there is failing where the user is;
- **how focus comes back**: `onTapOutside` on the fields gives focus back to
  the montage. Nothing takes the focus away from a `TextField` on its own, so
  without it one tap on the field left "S" and Delete dead for the rest of the
  session.

### The clock

The clock is the **video**, not the music. While the track was continuous its
player could own the time — there was sound from the first to the last frame.
With blocks that come and go there is no player playing the whole video, so the
playhead has its own `Timer.periodic` and the music follows it: `_syncMusic`
loads the block under it and seeks the matching point.

While a block plays, **it** is the clock: the player position becomes the
playhead position, because that is the sound the user is hearing and pulling it
back on every drift would cause an audible hiccup. If the player gets lost for
good (more than half a second), the clock goes on without it.

The montage is saved on the server on its own a second and a half after the
last change, and the most recent one is restored when the screen opens — a
`Job` carries its `montages`. The indicator at the top says when the work is
saved, because without a sign nobody knows whether they can close the tab.

The monitor opens the match **proxy** — the reduced copy that comes from the
same decoding as the crops — and falls back to the original recording only for
matches analysed before it existed (`job.monitorUrl`). Seeking inside the
half-gigabyte file is what brought the player down.

Inside each block the **match audio waveform** is drawn: the job carries the
whole waveform and the block crops the piece it shows, so trimming or
stretching changes the drawing on its own. It is how you match the shot with
the beat.

`widgets/preview_player.dart` is the monitor: it opens the original recording
and seeks the instant the playhead asks for, instead of rendering. Where there
is no block, black screen, with a label saying that is really what will come out
— unexplained black looks like a bug. Seeks are limited to one every 60 ms while
dragging the cursor, because each one is a `Range` request on the match file.

The maths lives in `montage.dart`, away from any widget: where a block can land,
how long it can last, where the cut starts in the recording so the play lands at
70% of it. It is the part with a right answer, and it is the tested part —
`montage.dart` mirrors `owcore/timeline.py` on the server, and the two have to
agree.

> **The monitor that died.** The browser video element sometimes fails while
> serving a large recording over `Range` with many seeks in a row, and nothing
> in `video_player` says so beyond `value.hasError`. Without watching it, the
> monitor stayed black until the page was reloaded — and reloading cost the
> whole montage. Now it is reopened on its own at the same point, up to four
> times, and seeks are serialised with 120 ms of slack.
>
> The audio player uses `video_player` pointed at the song URL. If it does not
> initialise (the format depends on the browser), the screen **keeps working**:
> the waveform and the beats are already drawn, and they are what you fit the
> cut to. The screen warns instead of freezing. This failure path has no
> automated test — it depends on the browser codec.

### State and history

`montage_state.dart` keeps the whole montage in an **immutable** object, and
every operation takes a state and returns another. Undo becomes swapping a
reference.

> V1 kept a `List<TimelineCut>` and changed it in place, in thirty different
> spots. It worked for six operations and would not survive twenty: there was no
> way to undo anything, because there was no "before" — the previous state was
> overwritten the instant the new one was born.

A drag produces one state per frame, so the history groups by **gesture**:
`startGesture()` at the start of the drag, `endGesture()` on release, and while
it is open the top of the stack is replaced instead of growing. Without that,
undo would go one pixel at a time.

Each block has a local `id`, which **does not go to the server**. An index is not
an identity: deleting a block shifts the following ones, and a multiple
selection or an undo step would end up pointing at the neighbour.

Selection and title change through `replace()`, not `apply()` — undo has to go
back one *edit*, not a focus change.

`api.dart` holds the REST client and the models. Uploads are **streamed**
(`readAsByteStream`), never loading the whole file into memory — a match
recording would not fit in a phone's RAM.

`widgets/download.dart` holds the downloads, with the implementation chosen at
build time:

- **web** (`download_web.dart`): an `<a download>` clicked from code, via
  `package:web`. No plugin at all — the server answers with
  `Content-Disposition: attachment`, so the name comes from there and the page
  stays where it is;
- **phone/desktop** (`download_io.dart`): `url_launcher` opening the system
  browser, which is what knows how to save files.

> **Why the web does not use `url_launcher`.** This button broke twice because
> of it. First because the URL came relative (`/api/...`) and the launcher
> requires a scheme — solved with `absoluteUrl`, which resolves against
> `Uri.base`. Then with `MissingPluginException`, even with the plugin present
> in `web_plugin_registrant.dart` and after `flutter clean`. Downloading a
> same-origin file needs no plugin: the browser does it natively, and that is
> what the app does now.
>
> Worth knowing: widget tests run on the VM, that is, on the `download_io.dart`
> path. **The web path is not covered by automated tests** — it was checked in
> Chrome, by looking at the file on disk.

`widgets/highlight_style.dart` is where each highlight and event kind gets its
icon, colour and display name, so every screen speaks the same language.

---

## Backend contract

The app depends only on the gateway REST API, browsable at
<http://localhost:8000/docs>:

| Route | What for |
|---|---|
| `POST /api/jobs` | multipart with `video` and `params` (JSON) — just the recording |
| `GET /api/jobs` | list, for the home screen |
| `GET /api/jobs/{id}` | detail with events, detectors, media, montages and requests |
| `DELETE /api/jobs/{id}` | removes the match |
| `POST /api/jobs/{id}/media` | multipart with `file` — brings a video, image or song into the library |
| `GET /api/media/{id}` | the analysed item; for audio: duration, BPM, beats and waveform |
| `POST /api/jobs/{id}/tracks` | multipart with `audio` — has the system listen to a song |
| `GET /api/tracks/{id}` | the analysed song: duration, BPM, beats and waveform |
| `GET /api/tracks/{id}/audio` | the audio, with `Range`, for the player to play and seek |
| `POST /api/jobs/{id}/renders` | form field `timelines` (JSON) with the montages to render |
| `GET /api/renders/{id}` | progress and clips of a request |
| `DELETE /api/renders/{id}` | deletes the request |
| `GET /api/clips/{id}/video` | video, with `Range` support for the player to seek |
| `GET /api/clips/{id}/thumb` | thumbnail |
| `GET /api/clips/{id}/cuts.zip` | the cuts of that montage |
| `GET /api/jobs/{id}/cuts.zip` | the whole match package: final videos + every cut |
