# 24

**Four cards. Four operations. One number.**

24 is a fast arithmetic card game. You're dealt four cards and have to combine
all four, each exactly once, with `+`, `−`, `×` and `÷` (and as many
parentheses as you like) to make exactly **24**.

> Cards **8, 3, 8, 3** → `8 ÷ (3 − 8 ÷ 3)` = 24

Face cards count as numbers: **A = 1, J = 11, Q = 12, K = 13**. Every hand the
game deals has at least one solution.

This repo has two versions of the game:

| Folder | What it is |
|---|---|
| [`web/`](web/) | The original browser game: a single, self-contained `index.html` |
| [`roblox/`](roblox/) | The same game rebuilt as a Roblox experience |

## How to play

- **Build the equation:** tap a card to send it to the equation bar, then tap
  an operator, then the next card.
- **Group with parentheses:** drag a box around two or more cards on the bar to
  wrap them in parentheses. Groups can be nested.
- **Undo:** tap a card on the bar to pull it back, tap a parenthesis to ungroup,
  or hit **Clear**.
- **Submit** when the bar makes 24.
- The keyboard works too: `+ - * x /`, Backspace and Enter.

After each hand, the **Other solutions** panel lists every distinct way to make
24 with those cards. Answers that only shuffle the same terms around (like
`a − b + c` and `c + a − b`) count as one solution.

## Modes

### Solo

No clock and no pressure. Solve hands at your own pace, skip any you don't
like, and chase your best score.

### Multiplayer lobbies

- Create a lobby, pick a name, and share the lobby code with friends.
- The host sets the **points to win**; you need to **win by 2**.
- A **Ready / Set / Go** countdown starts the match, and then everyone gets the
  **same hand at the same moment**.
- The **first correct answer takes the round**. Everyone is told instantly and
  the next hand is dealt.
- If a hand stalls for 30 seconds, anyone can call a **vote to skip** it.
- Live standings show during the match, and a round-by-round log appears at the
  end, with a rematch button.

## Running it

**Web:** open [`web/index.html`](web/index.html) in a browser. Solo play works
offline. Multiplayer lobbies sync through Firebase Firestore, so they need an
internet connection.

**Roblox:** open `roblox/TwentyFour.rbxlx` in Roblox Studio and press Play. See
[`roblox/README.md`](roblox/README.md) for multiplayer testing, publishing and
how the Roblox version differs from the web one.

## Under the hood

- **Exact arithmetic:** expressions are evaluated with fractions rather than
  floating point, so answers like `8 ÷ (3 − 8 ÷ 3)` work exactly.
- **Solver:** builds every expression tree for the hand, then filters out
  solutions that are just rearrangements of each other.
- **Sound:** short synthesised cues for dealing, placing a card and submitting
  an answer. No audio files are needed.
- **Layout:** the board scales to fit any screen. On narrow screens the
  solutions panel becomes a pull-up bottom sheet.
