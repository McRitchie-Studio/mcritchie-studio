# Tywin — Playbook

How Tywin plays Cyvasse: the style, the questions he asks of every position,
and the five setups he favours. His character is in [`soul.md`](soul.md).

Every rule quoted here is the engine's (`cyvasse/app/javascript/cyvasse/`)
as it stood on cyvasse `main` of 2026-09-30 (commit `7ac5bb5`), after Alex's
second round of rule changes: new strengths, trumps that work on attack only,
and new cavalry jumps. Every claim about a setup was checked against that
engine; the method is at the end. The rules are still moving, so re-run the
checks after any rule change before trusting a number here.

## The rules that shape his game

- **The king is the game.** Take theirs and you win.
- **The enemy dragon is the first danger.** It flies any distance in a
  straight line, over mountains, its own pieces and enemy foot soldiers, and
  takes what it lands on. A shooter (crossbow, catapult, trebuchet) or a dragon
  in its path makes it stop there. A king whose two forward diagonals each meet
  one of those four pieces first cannot be struck on the first turn.
- **Horses raid.** A light horse moves 4 and then 1 more; a heavy horse 3 and
  then 1. A horse can take a front piece with its first jump and the king with
  its second, so a king safe from the dragon is not yet safe.
- **The side whose king stands nearer the middle row moves first.** Initiative
  costs king safety.
- **Mountains stop every shot and every walking piece,** but not a dragon.
- **The lowest pieces kill lords.** Every unit but the trebuchet can take a
  king, the rabble included: the rabble trumps the king.
- **Trumps work on attack only.** The rabble takes a king; a trebuchet, a
  catapult or a king takes a dragon. There are no other trumps, and a trump
  protects nothing: a dragon can still take a trebuchet.
- **Shooters are fragile.** All three defend at 1, so any unit can take one.

## His style

Each principle is a page of his life turned into a way of playing.

1. **The house before the field.** His king starts sealed: both forward
   diagonals closed by a shooter or the dragon, stone at its shoulder. He never
   opens with the king forward, and gives up the first move gladly. No enemy
   piece can take the king in any of his five setups on the first turn: not a
   dragon, and not a horse raiding with both jumps.
2. **Win before the battle.** Most games are decided in the setup. He chooses
   his lanes with mountains and his killing grounds with shooters, then lets
   the opponent walk into them. (The Red Wedding was won by letter.)
3. **Patience at Harrenhal.** He does not send the dragon out early. It
   answers an enemy dragon, or it ends the game. A dragon spent on a rabble in
   the opening is a dragon he no longer has.
4. **Castamere.** A piece that enters his camp dies, whatever it costs. He
   takes that trade even at a slight loss, because the next piece hesitates.
5. **A Lannister pays his debts.** He counts every trade by value (rabble,
   light horse, crossbow, spearman, heavy horse, elephant, trebuchet, catapult,
   dragon, king: the computer's own order, `KILL_PRIORITY` in `ai.js`). He takes a trade that pays. He
   refuses a free piece that opens a line to his king.
6. **The Blackwater.** When he attacks, it is with the force the opponent did
   not count, on the flank they are not watching, after they have committed.
7. **Respect the crossbow.** He died to one. He tracks every enemy crossbow and
   catapult within reach of his king's ring, every turn.

## Reading a position

Before each move he asks, in this order:

1. Can anything of theirs take my king next turn? A dragon line, a crossbow
   or catapult in range, a horse's double jump?
2. After the move I intend, is that still no?
3. What is the most valuable piece they can take next turn, and what does it
   cost them if they take it?
4. What is my best capture by value that leaves 1 and 2 true?
5. If there is none: which move closes a lane, builds a killing ground, or
   brings the reserve one step nearer the flank I mean to strike?

## His five setups

Drawn in the Openings panel's notation (`cyvasse/app/javascript/cyvasse/openings.js`):
your five rows, front (row 7, next to no man's land) to back (row 11), one
letter a hex. **K** king, **D** dragon, **E** elephant, **T** trebuchet,
**C** catapult, **X** crossbow, **H** heavy horse, **L** light horse,
**S** spearman, **R** rabble, **M** mountain, **.** empty. Each row sits
half a hex in from the one above, as on the board.

| Setup | Idea | King | Moves first vs the 18 computer armies | Won vs the computer |
|---|---|---|---|---|
| The Blackwater | The flank strike | Back corner, left | 0 | 64.1% |
| The Red Wedding | The dragon trap | Back row, centre | 0 | 57.6% |
| The Rains of Castamere | Bait and punish | Back corner, right | 0 | 51.7% |
| Casterly Rock | The fortress | Back corner, right | 0 | 24.3% |
| The Hand of the King | The standard | Back row, left of centre | 0 | 9.3% |

For comparison, the 25 existing openings win 20.4% on average by the same
measure, and the best, Tusk Line, wins 64.3%. The Blackwater, the Red Wedding
and Castamere rank second, third and fifth among all thirty. Casterly Rock and
the Hand of the King were built for the first round of rules and fell under the
second: the Hand now loses most games and needs rebuilding. See "How the
numbers were made" for what this measures and what it does not.

### Casterly Rock — the fortress

```text
            the enemy
row  7   L . S . E E . S . L
row  8    . H . . T . . H .
row  9     R . . R . . . R
row 10      . . D . M X C
row 11       . . . M X K
            your side
```

`["L.S.EE.S.L", ".H..T..H.", "R..R...R", "..D.MXC", "...MXK"]`

The king takes the back right corner with a crossbow and the catapult on its
forward diagonals, a second crossbow at its side and two mountains close by.
The dragon waits nearby. The trebuchet in the centre of the second row covers
nearly the whole front: whichever front-line piece an enemy dragon takes, the
trebuchet or the catapult can take the dragon back, except the light horse on
the far left. Slow, and almost impossible to crack.
It is his default against a player he does not know.

### The Blackwater — the flank strike

```text
            the enemy
row  7   . S . R . E H L H L
row  8    . . R . . T E D .
row  9     S . . . . R . .
row 10      C X M . . . .
row 11       K X M . . .
            your side
```

`[".S.R.EHLHL", "..R..TED.", "S....R..", "CXM....", "KXM..."]`

All four horses, both elephants and the dragon mass on the right wing; the left
is held thin, by spearmen and rabble. The king hides in the far left corner
behind the catapult and a crossbow, walled by two mountains, well away from
where the fighting will be. When the opponent commits against the thin left,
the right wing falls on their flank. The Tyrells came from the side Stannis
was not watching.

### The Red Wedding — the dragon trap

```text
            the enemy
row  7   L . S . . . . S . L
row  8    H . . . E . . . H
row  9     . X . . R . X .
row 10      M . R C T R M
row 11       . . E K D .
            your side
```

`["L.S....S.L", "H...E...H", ".X..R.X.", "M.RCTRM", "..EKD."]`

The centre is left open, with one elephant standing in it: an invitation.
An enemy dragon that takes it can be taken back by the catapult, the
trebuchet or his own dragon. Deeper in, any piece their dragon takes on the
back two rows is answered by the catapult and the trebuchet. The catapult and
trebuchet also seal the king's diagonals from the row in front of it.

Rebuilt on 2026-10-03: the king used to stand on the fourth row, which moved
first against some computer armies, but under the new cavalry jumps a light
horse from the enemy's front row could reach it on the first turn. The king
now sits on the back row, and no first-turn raid reaches it.

### The Hand of the King — the standard

```text
            the enemy
row  7   L . S E . . E S . L
row  8    . H . . T . . H .
row  9     R . . D R . . R
row 10      M . X C . . M
row 11       . X K . . .
            your side
```

`["L.SE..ES.L", ".H..T..H.", "R..DR..R", "M.XC..M", ".XK..."]`

Balanced and orderly, the setup he plays most. A symmetrical front of horses,
spearmen and elephants; the trebuchet behind the centre; the dragon in reserve
on the third row. The king sits on the back row just left of centre, a crossbow
at its side and a crossbow and the catapult on its diagonals, with mountains
on both wings to funnel the opponent into the middle. A Hand's setup: nothing
flashy, everything covered.

### The Rains of Castamere — bait and punish

```text
            the enemy
row  7   . R . . R . . R . .
row  8    L . S E . E S . L
row  9     H . . T . . H .
row 10      . . D . M X C
row 11       . . . M X K
            your side
```

`[".R..R..R..", "L.SE.ES.L", "H..T..H.", "..D.MXC", "...MXK"]`

Casterly Rock's back rows with its front pushed out: three rabble alone on the
front row, and the army a row behind them. The rabble are bait. Nearly
anything that takes one is itself taken: an enemy dragon on any rabble's hex by
the trebuchet, a horse by his own horses or an elephant, and an elephant by one
of his elephants on any rabble's hex but the leftmost.
It costs rabble and wins pieces. It is what the Rock does to those who come
out to fight it. Against a player who takes every free piece, it is his
favourite.

## Which setup, when

| Opponent | Setup |
|---|---|
| Unknown, or strong | The Blackwater |
| Greedy: takes every free piece | The Rains of Castamere |
| Dragon-happy: flies the dragon early | The Red Wedding |
| Turtles: sits back and waits | The Blackwater |

Casterly Rock and the Hand of the King stay in his book by name but out of
this table until they are rebuilt for the current rules.

## How the numbers were made

A throwaway harness loaded each setup through the engine's own
`Game#loadLineup` (via `openingLineup` in `openings.js`) and checked five
things:

1. **A whole army**: all 19 pieces, on the player's rows at their true widths,
   and `readyToStart` true.
2. **No first-turn dragon strike**: with an enemy dragon on each of the 40
   enemy hexes in turn, `legalActions` never lists the king as a capture. This
   is the same check `test/javascript/openings_test.js` runs on the existing
   openings.
3. **No first-turn raid**: the same, for one enemy dragon, light or heavy
   horse (both jumps), elephant, rabble, spearman, crossbow or catapult on each
   enemy hex. The King's Gambit, checked as a control, is raidable from 84
   placements. This is the stronger check: `raids` in Tyrion's
   `test/javascript/tyrion_brain_test.js` in the `cyvasse` repo is the
   committed version of it.
4. **Moves first**: `Game#start` against each of the 18 computer lineups in
   `setups.js`.
5. **Retakes**: for each bait described above, an enemy piece put on that hex,
   and `legalActions` listing which of his pieces can take it.

None is a duplicate of an existing opening.

**Won vs the computer** is a crude measure. Each setup played 30 seeded games
against each of the 18 computer lineups (540 games), both sides moving by the
computer's own policy in `ai.js`: the best capture by value if there is one,
otherwise a random move. So it measures how well a setup survives careless
play on both sides, which rewards a sealed king. It does not measure how the
setup fares against a thoughtful player. No game was drawn.

The harness was not committed: it imports the Cyvasse engine, so it belongs in
the `cyvasse` repo, with these five setups, if Alex wants them in the app
(parked: see [`role.md`](role.md#decisions)).
