# 24 — Roblox edition

The web game `24-nested-parens.html`, rebuilt as a Roblox experience. It has
the same card table, the same rules and the same motion: cards dealt from the
top, the equation bar with nested parentheses, drag-to-group, and the
ready / set / go race.

## Launch it

1. Double-click **`TwentyFour.rbxlx`**. It opens in Roblox Studio with everything already in place.
2. Press **Play** (F5) to try solo.
   To try the multiplayer race, go to **Test → Clients and Servers**, choose 2 players, and click **Start**.
3. **File → Publish to Roblox** when you're happy. That's it.

There's nothing to wire up: the scripts build the whole interface themselves.

### Optional

- **Saving solo bests while testing in Studio:** Game Settings → Security → *Enable Studio Access to API Services*.
  Published games save bests with no extra setup.
- **The exact sounds from the web version:** Studio → View → Asset Manager → Import the three files in `sounds/`.
  Then paste their ids into `ReplicatedStorage › TwentyFour › Config` (`SOUND_IDS`).
  Until you do, a built-in Roblox click stands in, pitched differently for each of the three cues.
- **Chat:** off by default, because the chat window covers the "24" logo and grabs the `/` (divide) key.
  To turn it on, set `ENABLE_CHAT = true` in Config.

## What's where

| In Studio | Source file | Role |
|---|---|---|
| ServerScriptService › TwentyFourServer | `src/server/TwentyFourServer.server.luau` | Runs lobbies, deals hands, checks every answer, referees the race and vote-to-skip, saves bests |
| ReplicatedStorage › TwentyFour › Solver | `src/shared/Solver.luau` | Exact-fraction evaluator, solution finder, duplicate-solution filter (a port of the web version) |
| ReplicatedStorage › TwentyFour › Config | `src/shared/Config.luau` | Sound ids, chat toggle, match timings |
| StarterPlayerScripts › TwentyFourClient | `src/client/TwentyFourClient/` | The table (`Play`), menus (`Menus`), drawing/fonts (`Ui`), easing (`Anim`), sounds (`Sfx`) |

## How it maps from the web version

| Web | Roblox |
|---|---|
| Firebase lobby documents plus polling | The Roblox server holds the lobby and pushes updates instantly. It also checks every answer, so answers can't be faked. |
| Share link `?room=CODE` | **Invite** button: a Roblox friend invite that carries the code. Codes also work from a different server, which moves the player to the lobby's server (published game only). |
| Copy to clipboard | Roblox can't write to the clipboard, so "Copy code" selects the code and you press Ctrl+C. |
| `localStorage` best score | Saved per player in a DataStore |
| Georgia / Space Grotesk | Merriweather / Builder Sans (Roblox's closest built-in fonts) |
| ♠ ♥ ♦ ♣, ✓, ✕, ▸ glyphs | Drawn as shapes, because Roblox fonts don't include them |
| Display names | Passed through Roblox's text filter (required by Roblox); a blank name uses your Roblox display name |
| Keyboard: Backspace, Enter, `+ - * x /` | Same |

## Rebuilding after edits

Edit the files in `src/`, then run:

```bash
powershell -ExecutionPolicy Bypass -File tools/build.ps1
```

If you use [Rojo](https://rojo.space), `default.project.json` maps the same tree (`rojo serve`).

`tools/gen-sounds.ps1` re-renders `sounds/*.wav` from the web version's Web Audio recipes.
