# Sleeper Auction Watch

## Status: Active

This is Turf Monster's `sleeper-auction-watch` SOP. It sits beside Mr. McRitchie
during a live Sleeper **auction** draft: it builds a dollar valuation for every
player under that league's exact scoring rules, then calls a max bid on each
player as he comes up for sale.

It is Turf Monster's because every judgment it asks for is a sports-domain
judgment. Whether a projection is a committee split or an injury, whether a
thinning position justifies paying over model, whether the last back on the
board is worth a scarcity premium — those are read against knowing the sport.
Its failure mode is a domain failure too: a roster that cannot fill a starting
slot does not read as an outage, it reads as a season that starts a man down.

**The watch holds no lane and writes nothing.** It reads Sleeper's public API
and reports; it never bids, never nominates, never touches the board. Mr.
McRitchie clicks every button. It takes no assembler and no deployer claim, so a
`qa-release` sweep or a `production-deploy` can run alongside it.

## The split — read this before running anything

**You decide nothing about what a player is worth.** Every dollar figure comes
out of a model built from the league's own scoring rules and Sleeper's own
projections. Your judgment is spent on pacing, scarcity, and roster feasibility.

| Deterministic — the model | Agentic — you |
|---|---|
| Scoring each projection under the league's rules | Reading which position is about to run dry |
| Replacement level and VORP per position | Deciding when scarcity justifies paying over model |
| Converting VORP to auction dollars | Catching a projection that contradicts itself |
| Tracking picks, budgets, and max bids | Judging whether the budget still closes |
| Naming the best available at each position | Saying **bid** or **pass** on the clock |

If you find yourself reasoning about **how many points a touchdown is worth**,
stop. The scoring settings already answer that. If you find yourself reasoning
about **whether nine teams chasing four running backs should move a price**,
that is yours.

## Scope

One auction draft, start to finish, in one session. Snake drafts are out of
scope — the model still works, but the bid-pacing half of this SOP is auction
mechanics and does not transfer.

## Preconditions

1. **The league is on Sleeper and the draft type is `auction`.** Confirm both in
   step 1; a snake draft ends this SOP.
2. **You have the league id.** Ask Mr. McRitchie, or read it out of the browser
   URL: `https://sleeper.com/leagues/<league_id>/...`.
3. **Node is available** — the scripts below are plain Node with `fetch`.
4. **A scratch directory**, namespaced to this act. Everything below writes to
   `$SCRATCH/ff/`. Never write to a bare filename in a shared scratchpad.

```bash
SCRATCH="${CLAUDE_SCRATCHPAD:-/tmp}"   # or the session scratchpad you were given
mkdir -p "$SCRATCH/ff" && cd "$SCRATCH/ff"
```

No auth is required. Sleeper's read API is public; the draft board, the picks,
and the projections all come back unauthenticated.

## Step 1 — Read the league and the draft

```bash
L=<league_id>
curl -s "https://api.sleeper.app/v1/league/$L" -o league.json
curl -s "https://api.sleeper.app/v1/league/$L/drafts" -o drafts.json
curl -s "https://api.sleeper.app/v1/league/$L/users"  -o users.json
curl -s "https://api.sleeper.app/v1/league/$L/rosters" -o rosters.json

node -e "
const l=require('./league.json'), d=require('./drafts.json')[0];
console.log('league:', l.name, '|', l.total_rosters, 'teams |', l.season);
console.log('roster:', JSON.stringify(l.roster_positions));
console.log('draft :', d.draft_id, '| type:', d.type, '| status:', d.status);
console.log('budget: \$'+d.settings.budget, '| rounds:', d.settings.rounds);
console.log('start :', d.start_time ? new Date(d.start_time).toLocaleString('en-US',{timeZone:'America/Denver'}) : 'n/a');
const s=l.scoring_settings; Object.keys(s).sort().forEach(k=>console.log('  '+k+' = '+s[k]));
"
```

**Stop and read the scoring dump.** It is the whole edge. On the 2026 Champions
League run it showed 6-point passing touchdowns, `pass_sack = -1`, half PPR, and
a full IDP block — a combination that made quarterbacks nearly worthless in
relative terms and defenders nearly free. **Say out loud which three settings are
unusual before you go on.**

Record the **draft id**, the **budget**, and the **roster positions**. You need
all three below.

## Step 2 — Pull projections

```bash
for P in QB RB WR TE K DEF DL LB DB; do
  curl -s "https://api.sleeper.com/projections/nfl/<season>?season_type=regular&position[]=$P&order_by=ppr" \
    -o "proj_$P.json" &
done; wait
wc -c proj_*.json
```

Note the host: projections live on `api.sleeper.com`, while the league endpoints
are on `api.sleeper.app`. Drop the IDP positions if the league has no IDP slots.

## Step 3 — Build the model

**The trick that makes this cheap:** Sleeper's projection stat keys are the same
vocabulary as the league's `scoring_settings` keys — `pass_yd`, `rec`, `idp_sack`,
`fgmiss_40_49`, all of it. So a player's projected fantasy points is a dot
product of his stat line against the league's own scoring hash. Every oddity in
the rules — IDP, return yards, missed-kick penalties — is handled for free, with
no special-casing.

**The one trap:** the player id is at the ROW level, not inside `row.player`.
`row.player.player_id` is `undefined`, and keying a map on it collapses every
player onto one entry. Use `row.player_id`.

```bash
cat > model.js <<'EOF'
const fs = require('fs');
const league = require('./league.json');
const SC = league.scoring_settings;
const RP = league.roster_positions;
const TEAMS  = league.total_rosters;
const BUDGET = require('./drafts.json')[0].settings.budget;
const ROSTER = RP.length;

// starters per team, from roster_positions
const need = {};
RP.forEach(p => { if (p !== 'BN' && p !== 'FLEX') need[p] = (need[p]||0) + 1; });
const FLEX = RP.filter(p => p === 'FLEX').length;

const POS = Object.keys(need);
const byId = new Map();
for (const p of POS) {
  const file = `proj_${p}.json`;
  if (!fs.existsSync(file)) continue;
  for (const row of JSON.parse(fs.readFileSync(file))) {
    const pl = row.player; if (!pl) continue;
    const id = row.player_id;                       // ROW level. Not pl.player_id.
    const team = row.team || pl.team; if (!team) continue;   // no NFL team = undraftable
    let pts = 0;
    for (const k in row.stats) if (SC[k] !== undefined) pts += row.stats[k] * SC[k];
    if (!(pts > 0)) continue;
    const pos = pl.position === 'DEF' ? 'DEF' : (pl.fantasy_positions || [p])[0];
    const prev = byId.get(id);
    if (!prev || pts > prev.pts) byId.set(id, {
      id, pos, team, name: `${pl.first_name} ${pl.last_name}`,
      pts: +pts.toFixed(1),
      adp: row.stats.adp_idp < 999 ? row.stats.adp_idp : (row.stats.adp_half_ppr < 999 ? row.stats.adp_half_ppr : null),
    });
  }
}
const all = [...byId.values()];

// replacement level, flex-aware
const startersAt = {};
for (const k in need) startersAt[k] = need[k] * TEAMS;
const FLEXABLE = ['RB','WR','TE'].filter(k => startersAt[k]);
if (FLEX && FLEXABLE.length) {
  const pool = {}; FLEXABLE.forEach(k => pool[k] = all.filter(x=>x.pos===k).sort((a,b)=>b.pts-a.pts));
  const idx = {}; FLEXABLE.forEach(k => idx[k] = startersAt[k]);
  for (let i = 0; i < FLEX * TEAMS; i++) {
    let best = null;
    for (const k of FLEXABLE) { const c = pool[k][idx[k]]; if (c && (!best || c.pts > best.c.pts)) best = {k,c}; }
    if (!best) break;
    idx[best.k]++;
  }
  FLEXABLE.forEach(k => startersAt[k] = idx[k]);
}
const repl = {};
for (const k in startersAt) {
  const list = all.filter(x=>x.pos===k).sort((a,b)=>b.pts-a.pts);
  repl[k] = (list[startersAt[k]] || list[list.length-1] || {pts:0}).pts;
}

// VORP -> dollars. Every roster spot costs at least $1; the rest is split by VORP.
all.forEach(x => x.vorp = +(x.pts - (repl[x.pos] ?? 0)).toFixed(1));
const sumV = all.filter(x=>x.vorp>0).reduce((s,x)=>s+x.vorp, 0);
const discretionary = TEAMS*BUDGET - TEAMS*ROSTER;
all.forEach(x => x.val = x.vorp > 0 ? Math.max(1, Math.round(1 + (x.vorp/sumV)*discretionary)) : 1);

fs.writeFileSync('values.json', JSON.stringify({repl, startersAt, players: all.sort((a,b)=>b.val-a.val)}));
console.log('REPLACEMENT LEVEL');
POS.forEach(k => console.log(`  ${k.padEnd(4)} ${String(repl[k]??0).padStart(7)} pts   starters ${startersAt[k]}`));
console.log(`\nMoney: ${TEAMS}x\$${BUDGET} | spots ${TEAMS*ROSTER} | discretionary \$${discretionary}\n`);
console.log('  $    POS  PLAYER                  PTS     ADP');
all.slice(0,30).forEach(x => console.log(
  ('$'+x.val).padEnd(6)+x.pos.padEnd(5)+x.name.slice(0,23).padEnd(24)+String(x.pts).padStart(7)+'   '+(x.adp??'-')));
EOF
node model.js
```

### Sanity-check before you trust a single number

Three checks, every time. Each has caught a real bug:

1. **Row count.** If fewer than ~40 players score above $1, the id key or the
   team filter is wrong. One player in the list means the id collapsed.
2. **Replacement levels are non-zero** for every position with a starting slot.
   A zero means that position's file did not load.
3. **The top of the board passes the eye test** against Sleeper's own `$PROJ`
   column in the draft room. They will differ — that difference is your edge —
   but they should not disagree wildly on who belongs in the top ten.

## Step 4 — Watch the draft

Poll picks and print the delta. Run this each time you check.

```bash
cat > live.js <<'EOF'
const V = require('./values.json'), fs = require('fs');
const DRAFT = process.env.DRAFT_ID, ME = +process.env.MY_ROSTER || null;
const league = require('./league.json');
const TEAMS = league.total_rosters, ROSTER = league.roster_positions.length;
const BUDGET = require('./drafts.json')[0].settings.budget;
const val = new Map(V.players.map(p => [p.id, p]));
(async () => {
  const picks = await (await fetch(`https://api.sleeper.app/v1/draft/${DRAFT}/picks`)).json();
  const nm = {}; require('./users.json').forEach(u => nm[u.user_id] = u.display_name);
  const rn = {}; require('./rosters.json').forEach(r => rn[r.roster_id] = nm[r.owner_id] || ('roster '+r.roster_id));
  const gone = new Set(), spent = {}, count = {}, log = [];
  for (const p of picks) {
    gone.add(p.player_id);
    const amt = +(p.metadata?.amount || 0), v = val.get(p.player_id);
    spent[p.roster_id] = (spent[p.roster_id]||0) + amt;
    count[p.roster_id] = (count[p.roster_id]||0) + 1;
    log.push({rid:p.roster_id, amt, val:v?.val ?? 1,
      name:v?.name ?? `${p.metadata?.first_name} ${p.metadata?.last_name}`, pos:v?.pos ?? p.metadata?.position});
  }
  let seen = 0; try { seen = JSON.parse(fs.readFileSync('seen.json')).n; } catch {}
  fs.writeFileSync('seen.json', JSON.stringify({n: log.length}));
  console.log(`PICKS ${picks.length}  (new since last check: ${log.length - seen})`);
  log.slice(seen).forEach(x => { const d = x.val - x.amt;
    console.log(`  $${String(x.amt).padStart(3)} (model $${String(x.val).padStart(3)}, ${d>0?'+':''}${d})  ` +
      `${(x.pos||'').padEnd(4)}${x.name.slice(0,22).padEnd(23)}-> ${rn[x.rid]}` +
      (d <= -10 ? '  << BARGAIN GONE' : d >= 10 ? '  << OVERPAY' : '')); });
  console.log('\nBUDGETS');
  for (let i = 1; i <= TEAMS; i++) {
    const left = BUDGET - (spent[i]||0), slots = ROSTER - (count[i]||0);
    console.log(`  ${String(rn[i]).slice(0,16).padEnd(17)}$${String(left).padStart(3)} left  ${String(slots).padStart(2)} slots  MAX $${Math.max(0,left-(slots-1))}${ME===i?'   <== YOU':''}`);
  }
  const avail = V.players.filter(p => !gone.has(p.id) && p.val > 1);
  console.log('\nBEST AVAILABLE');
  [...new Set(V.players.map(p=>p.pos))].forEach(pos => {
    const t = avail.filter(p=>p.pos===pos).slice(0,5);
    if (t.length) console.log(`  ${pos.padEnd(4)} ` + t.map(p=>`${p.name.split(' ').slice(-1)[0]} $${p.val}`).join(' · '));
  });
})();
EOF
DRAFT_ID=<draft_id> MY_ROSTER=<n> node live.js
```

**The API trails the room by a few seconds and occasionally by a pick.** For a
live bid call that is too slow. If Mr. McRitchie wants calls on the clock, also
watch the board itself — see **Watching the room** below.

## Watching the room

The API is the record; the screen is the live feed. To read the screen, launch
Chrome with a debug port on a **throwaway profile** and attach over CDP.

```bash
nohup "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --remote-debugging-port=9222 --user-data-dir="$SCRATCH/draft-chrome-profile" \
  --no-first-run --no-default-browser-check --window-size=1440,900 \
  > "$SCRATCH/draft-chrome.log" 2>&1 &
until curl -s --max-time 1 http://127.0.0.1:9222/json/version >/dev/null; do sleep 1; done
```

Mr. McRitchie logs in himself. **Do not screenshot until he says he is on the
draft page** — a fresh profile means he is typing credentials, and there is no
reason to look at that. Then screenshot the active tab with Playwright over CDP
(`chromium.connectOverCDP('http://127.0.0.1:9222')`), reading the most recently
active page from `http://127.0.0.1:9222/json/list`.

The board shows, in one frame, the four things the API lags on: **who is on the
block, the current bid, the clock, and every team's remaining max.** Read those
off the screen and take exact prices from the API afterwards.

## Reporting — what a check prints

Lead with the decision. Mr. McRitchie is on a 10-to-30-second clock and reads
slowly; **the first line must be a verb**.

1. **The call** — `BID — <player> at $<current>, model $<val>. Max $<n>.` or
   `PASS — <player> is at $<current>, model $<val>.`
2. **New sales since the last check**, with price against model and an
   overpay/bargain flag.
3. **His budget, slots, and max bid**, and the same for anyone who can outbid him.
4. **What he still has to fill**, and whether the money still covers it.

## The decision rules

**Max bid is arithmetic, not taste.** Sleeper enforces
`max = budget − (slots − 1)`; every player still costs at least a dollar.

**Feasibility is the binding rule.** Before calling any bid, check that the rest
of the roster still closes:

> remaining premium buys ≤ budget − (slots − 1)

State it in his terms — "two backs, $46 combined, or the defense becomes a $1
player." A roster that cannot fill a required starter is a worse outcome than
any single overpay.

**Pay over model only for scarcity, and say the number.** When the position is
nearly dry and the replacement is a cliff rather than a step, a premium of
10-20% is right. When the next three players project within five points of each
other, it never is — say so and name them.

**Positions with a flat tier are not worth chasing.** On the 2026 run, four
backs projected 188.5, 188.7, 189.1 and 190.5. Paying $34 for the top one when
the fourth went for $20 bought a tenth of a point per week.

**Never bid over $1 on a kicker** unless the scoring makes kickers unusual, and
check: distance bonuses and per-range miss penalties can widen the spread.

## Anomalies — the part that needs judgment

**A projection that contradicts its own price.** Sleeper's `$PROJ` is a
preseason auction value and goes stale; the point projection is refreshed. When
they disagree, trust the points and say why. On the 2026 run, Josh Jacobs showed
`$PROJ $20` against 79 projected points over a full 18 games — a committee role,
not an injury. He sold for $9. **Print the stat line, not just the verdict.**

**A name that outruns its projection.** Star players whose role has changed will
be bid up on reputation. T.J. Watt at 71 points sat below the league's 82-point
linebacker replacement level. Saying "below replacement" is more useful than
saying "not worth it".

**A whole position the room is not pricing.** Find it early and say it once,
loudly. In 2026 it was IDP and team defenses: six of the ten best buys in the
draft were defenders or defenses bought for $1-6 against $11-16 model values.

**The board and the API disagree.** The board is ahead. Trust it for the live
call and reconcile on the next poll — never re-call a bid off a stale API read.

## Exit Seam — stopping

Stop when any is true, and say which:

- Mr. McRitchie's roster reads full (every required slot filled)
- the draft status flips off `drafting`
- Mr. McRitchie says stop

Then print the final roster with price against model, the total value acquired
against the budget, and where he ranked in surplus among the league. Name the
best and worst buys plainly. **If he finished behind the model, say so** — a
draft report that only lists the wins teaches nothing for next year.

If you armed a recurring check, cancel it. If you launched Chrome, tell him the
pid and leave it running unless he asks otherwise.

## What this SOP must never do

- **Never place a bid or a nomination.** This act advises. Every click is Mr.
  McRitchie's, and an auction purchase cannot be undone.
- **Never screenshot a login.** A throwaway Chrome profile means credentials get
  typed. Wait until he says he is on the draft page.
- **Never call a bid off a stale read.** If the API and the board disagree, the
  board is current; re-read before advising.
- **Never let a required slot go unfilled to chase value.** Once the budget is
  near the floor, filling DL, LB, DB, DEF and K at $1 beats any upgrade.
- **Never invent a projection.** If a player is missing from the model, say he is
  missing and price him at replacement, rather than reasoning a number into
  existence.

## Background — not needed to execute

The 2026 Champions League run that produced this SOP: 12 teams, $200 auction,
half PPR, 6-point passing touchdowns, full IDP. The model priced the first two
sales within $1 (Bijan Robinson $71 against $72; Saquon Barkley $43 against
$43). The room overpaid on eight of twelve quarterbacks and on four of the five
most expensive receivers, and left the entire defensive pool at a dollar.
