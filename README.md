# paraplan

Load a **Paralives** save and export its buildings as real floor plans: walls drawn to thickness, doors with
swings, windows, arches, stairs (and the stair opening on the level above), furniture, room names with areas,
overall dimensions, a title block and a scale bar. All levels of a building go side by side on one sheet.

![paraplan](docs/screenshot.png)

- **SVG** at true paper size (1:50, 1:100 or 1:200): print at 100 % and measure with a ruler.
- **PNG** at 300 dpi of the same sheet (max 8000 px, 2x supersampled).

Built on [bmu](https://github.com/foelkdavid/bmu) (C3 + raylib, Wayland).

## Use

```sh
./install.sh                 # build, link ~/.local/bin/paraplan, icon + .desktop entry
paraplan                     # opens the last save (or the first one Steam has)
paraplan "path/to/Save File 1.saved"
paraplan some.lot            # a single lot file (e.g. the game's Main.mod/PremadeLots/*.lot)
paraplan --export DIR save   # batch: every building as SVG + PNG into DIR, then quit
```

Saves are found through Steam's library folders (Proton prefix of app 1118520,
`…/AppData/LocalLow/Paralives/Paralives/MySavedGames.mod/*.saved`). Drop a `.saved` folder or `.lot` file on
the window to open it. Click a room to rename it (names are kept in `~/.config/paraplan/rooms.ini`); otherwise
rooms are named from the furniture in them (Bathroom, Bedroom, Kitchen, …).

Lots the player never touched are proxies of the game's premade lots; their geometry is read from the game
install (`steamapps/common/Paralives/Main.mod/PremadeLots`). Item names (door / window / stairs / furniture)
come from the install's `Main.mod/Settings/Items.setting`; without the install a size-based guess is used.

Keys: wheel zoom, drag pan, F fit, Up/Down building, Ctrl+O open, Ctrl+E SVG, Ctrl+P PNG, Ctrl+K help.

## Limits

The save format is undocumented; this reads what the game writes today (JSON lots). Door swing side and the
stairs' up direction are not stored in a way paraplan understands yet, so they follow the item's orientation.
Level names (ground floor / basement) are guessed from wall heights.

Licenses: `licenses/` (embedded font OFL 1.1, raylib zlib).
