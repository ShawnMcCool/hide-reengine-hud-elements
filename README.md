# HUD Element Hider

A REFramework mod that lets you switch off any on-screen GUI element you don't
want to look at — a prompt that keeps appearing over enemies, a banner that
outstays its welcome, a meter you never read.

Finding the element is half the job, so the mod does that part too.

Built for and tested on **Onimusha: Way of the Sword**.

## Requirements

- **An RE Engine game.** Developed and tested against *Onimusha: Way of the
  Sword*. See [Other games](#other-games).
- **[REFramework](https://github.com/praydog/REFramework)**, installed and
  working. Get the build for your game from the
  [nightly releases](https://github.com/praydog/REFramework/releases) — builds
  are per-game, and the wrong one will not load. Developed against nightly
  01417 (`b6baf6b`).
- Nothing else. No other mods, no Lua runtime to install, no dependencies.
  REFramework embeds Lua 5.4 and runs this itself.

To check REFramework is working before installing this: launch the game and
press **Insert**. If a window appears, you are ready. If it does not, fix that
first — this mod cannot load without it.

## Installing

Download the latest release and extract it into the game's install directory,
keeping the folder structure. You should end up with:

```
<game directory>/
  dinput8.dll                                  <- REFramework, already there
  reframework/
    autorun/
      hud_element_hider.lua
      hud_element_hider/
        pure.lua
        diagnostics.lua
```

Both parts matter. `hud_element_hider.lua` must sit **directly** in `autorun/`,
which is what REFramework executes. The two modules must sit in the
`hud_element_hider/` subdirectory, because REFramework runs everything directly
in `autorun/` and a module run on its own does nothing.

Finding your game directory: in Steam, right-click the game → Manage → Browse
local files.

### Linux and Steam Deck

Works under Proton. REFramework needs its DLL override set, which means adding
this to the game's Steam launch options:

```
WINEDLLOVERRIDES="dinput8=n,b" %command%
```

That is a REFramework requirement, not this mod's. If REFramework already opens
with Insert, it is already set.

## Opening it

**Insert** opens the REFramework window. Expand **ScriptRunner**, then
**HUD Element Hider**.

If the panel is not there, check `re2_framework_log.txt` in the game directory —
it is rewritten every launch and will say whether the script loaded. Lines from
this mod are tagged `[HUD Element Hider]`.

## Using it

### The problem

RE Engine games do not name their GUI elements. In *Onimusha: Way of the Sword*,
the "Press X to break Issen" prompt over an exhausted enemy and the "LT to
absorb rift" prompt are called:

```
GUI020102
GUI020016
```

That is everything the game tells you. There is no list, no description, and a
combat scene draws a few dozen of them at once. You cannot search for the thing
you want gone, because you do not know what it is called — and if you did, the
name would not help you recognise it.

### Working backwards from what you can see

So the mod starts from the screen rather than from the names.

**Pause with the thing you dislike visible**, open the panel, and the **on
screen** view lists only the elements drawing *right now*. In a combat scene
that is a handful of rows instead of the forty-odd seen all session.

**Flash** blinks one of them on and off. That is how you tell which row is
which — you watch the screen and see what winks at you.

Still too many? Press **Reset**, unpause, make the thing happen again, and the
**new** view shows only what appeared since. Two presses usually gets you to one
row.

### Hiding it

Press **Hide** on the row. The element stops drawing, and stays gone across
launches.

Then **write what it is in the label box** — "Press X to break Issen", say.
`GUI020102` means nothing to you a week later, and nothing at all to anyone
else. The label is the only record of what you found.

The tickbox beside each entry turns it off without deleting it, so you can put
an element back without losing the identification work. An entry left switched
off is a note to yourself: recorded, labelled, still drawing.

### Watch what else disappears

Some elements are containers holding more than one thing, so hiding one can take
more with it than you wanted. Flash shows you exactly what an entry covers
before you commit, and the tickbox undoes it if you were wrong.

## Sharing lists

A hide list is a small json file. Export yours, send it to someone, and they
drop it in `reframework/data/` and load it.

Because entries carry labels, a list arrives readable:

```json
[
  { "name": "GUI020102", "label": "Press X to break Issen", "on": true },
  { "name": "GUI020016", "label": "LT to absorb rift", "on": true }
]
```

Without those labels a shared list is a column of ids the recipient has to
identify from scratch — which is the entire job you already did. With them,
one person finds an element once and everyone they send it to gets it.

Imported entries arrive **switched off**. Someone else's list never changes your
HUD until you tick the entries you want, and a merge never overwrites a label
you wrote yourself.

Lists are per-game. `GUI020102` is the Issen prompt in *Onimusha: Way of the
Sword* and something else entirely, or nothing, in another title.

## Files

All in the game's `reframework/data/`:

| File | What |
|---|---|
| `hud_element_hider.json` | Settings |
| `hud_element_hider_list.json` | Your hide list. This is the one to share. |
| `hud_element_hider_diagnostics.json` | What the mod detected about the game |

The hide list is deliberately separate from the settings so you can send it to
someone without sending your overlay preferences too. It is plain json: a bare
name works as shorthand for an entry with no label, and an unusable line is
dropped rather than taking the rest of the list with it.

Editing it by hand while the game is running needs one extra step. The mod holds
the list in memory and writes all of it back on the next panel action, which
would discard your edit — so press **Reload from file** in the panel afterwards,
and the file becomes the authority again. Editing with the game closed needs
nothing special.

## Other games
<a name="other-games"></a>

Nothing here is specific to one game. The mod works on GUI element names and
`via.gui` types, which every RE Engine game has, and it carries no game checks
and no hardcoded names.

It has only been tested on **Onimusha: Way of the Sword**. Other REFramework
titles will probably work. Element names differ per game, so hide lists do not
transfer between them.

## If something goes wrong

The mod **fails open**: any element it cannot identify is drawn. A HUD that
silently loses a piece with no obvious cause is worse than a mod that doesn't
work, so every uncertain path ends with the element on screen.

If an element you hid took something else with it, untick the entry rather than
deleting it — some elements are containers holding more than one thing, and
`Flash` will show you what a given entry covers before you commit.

If the on-screen overlay is too small at high resolutions, switch the overlay
style to `imgui` under **DISPLAY**; it uses REFramework's own font size, which
you can raise in `re2_fw_config.txt`. The `draw` style ignores that setting.

The **Diagnostics** section reports what the mod detected. If you're filing an
issue, that's the useful part to include.
## Uninstalling

Delete `hud_element_hider.lua` and the `hud_element_hider/` folder from
`reframework/autorun/`. Everything the mod hid comes back on the next launch.

Your hide list is left in `reframework/data/` and is picked up again if you
reinstall. Delete those files too if you want it gone.

