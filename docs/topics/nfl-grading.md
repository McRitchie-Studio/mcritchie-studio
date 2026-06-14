# NFL Grading & Starter Picker

> **When to read this:** Modifying PFF imports, proprietary pass/run grades, the 12-slot starter picker (offense/defense), the defensive formation map, slot labels, or the depth chart UI.

## PFF Grade Pipeline

`db/seeds/data/pff/*.csv` (committed) → `db/seeds/29_pff_grades.rb` → `Pff::ImportCsv` (`app/services/pff/import_csv.rb`). Detects stat_type from filename. Each stat_type has a `POSITION_FILTER` whitelist so only relevant positions get grades written. PFF-sourced columns on `AthleteGrade` are suffixed `_pff` (e.g., `overall_grade_pff`, `pass_grade_pff`, `pass_block_grade_pff`, etc. — all 15 of them). For blocking CSVs without `grades_offense`, derives `overall_grade_pff` as the avg of `pass_block_grade_pff` + `run_block_grade_pff`; for defensive sub-CSVs without `grades_defense`, derives from coverage/pass_rush/rush_defense. Position normalization uses `source: :pff`. After PFF runs, `30_athlete_grades.rb` writes a flat 50.0 placeholder for non-PFF active athletes so ranking pages have something to sort against. Drop new CSVs into the dir and re-seed; idempotent via `find_or_initialize_by`. Currently imported: 11 stat types.

## Proprietary Pass/Run Grade Pipeline

`Athletes::ComputeProprietaryGrades` (`app/services/athletes/compute_proprietary_grades.rb`, rake `nfl:assign_grades`, runs during the full NFL rebuild workflow). Buckets athletes by canonical position (qb / rb / wr_te / ol / dl / lb / db), then runs a **3-tier input cascade** per axis to populate `position_pass_rank/grade` and `position_run_rank/grade` on `AthleteGrade`:

1. Position-specific PFF input (e.g. `coverage_grade_pff` for LB pass, `pass_block_grade_pff` for OL pass, `pass_rush_grade_pff` for DL pass)
2. Side-of-ball overall (`offense_grade_pff` or `defense_grade_pff`)
3. No usable input → bottom of list with grade 0 (renders as D)

Notable per-bucket choices: QB uses `pass_grade_pff` for both axes (no separate run grade). RB pass uses `offense_grade_pff` directly — `pass_block_grade_pff` is too sparse for non-3rd-down backs. Grade is a 0–10 linear percentile (best rank = 10, worst = 0). View helpers in `GradeHelper`: `letter_grade(numeric)` → A (10–8) / B (7–5) / C (4–2) / D (1–0), `letter_grade_class(letter)` → badge bg class, `pff_grade_color(value)` → hex color for the 0–100 PFF numeric badge (used in both `_player_card.html.erb` and `player_impact.html.erb`). Rendered on `/nfl-team-grades/:team_slug` (Bills linked from NFL hub) and on every player card on `/games/:year/week/:week/:slug` — `_player_card.html.erb` accepts `mode:` and shows only the badge matching the row's scheme (`pass`/`stop_pass` → P; `run`/`stop_run` → R).

## 12-Slot Starter Layout

`Roster#offense_starting_12` and `Roster#defense_starting_12` return ordered Hashes with one PickedSpot per slot:

- **Offense**: `:qb, :rb, :wr1, :wr2, :wr3, :te, :flex, :lt, :lg, :c, :rg, :rt`. Flex = highest `offense_grade_pff` among (RB depth=2, WR depth=4, TE depth=2). RB pool sorted with `RB_PRIORITY = {RB: 0, HB: 1, FB: 2}` so true RBs always beat FBs at the same depth.
- **OL slots** (`pick_ol_slot`) prefer the lowest-depth entry matching the slot's specific position (LT/LG/C/RG/RT), then fall back to generic OT/OG. Critical: uses `min_by(&:depth)`, not `.detect` — first-by-depth, not first-by-insertion-order. Pre-fix, seed-31 entries (older ids) won over ESPN-set depth=1 entries (Saints LT showed Landon Young at LT2 instead of Kelvin Banks Jr. at LT1).
- **Defense**: `:edge1, :edge2, :dl1, :dl2, :dl_flex, :lb1, :lb2, :ss, :fs, :cb1, :cb2, :flex` (the 12th = nickel). Picker uses scheme-agnostic formation map + athlete.position disambiguation (see below).
- **Special teams**: `:k, :p, :ls, :returner` (Roster#special_teams_starting_4).

## Defensive Picker (Scheme-Agnostic)

`pick_defense_by_formation` uses `PositionConcern::FORMATION_GROUPS` (formation_slot → list of eligible display groups, e.g. `LDE => [:edge, :dl]`) plus `GROUP_ATHLETE_POSITIONS` (display group → matching athlete.position values) to bucket each entry into ONE display group. Per group: take the lowest-depth entry per formation_slot (the formation's "starter"), sort by the slot's grade criterion, assign top N. Solves the 3-4 vs 4-3 ambiguity without scheme detection: 3-4 LDE/RDE (interior) → DL pool because athlete.position=DT; 4-3 LDE/RDE (edge) → EDGE pool because athlete.position=EDGE. Same map handles both. Pool-based fallback used when no formation_slot data exists (plain `db:seed` without ESPN).

## Depth Chart Pipeline

`Roster#offense_starting_12` and `Roster#defense_starting_12` read `DepthChartEntry` rows at runtime. Two ways entries land:

- Live: `bin/rails espn:scrape_depth_charts` (preferred — current week's depth per ESPN, populates `formation_slot`).
- Fallback: `db/seeds/31_depth_charts.rb` ranks by `overall_grade_pff DESC, salary DESC` from active contracts; sets `position` only (no `formation_slot`). Used during plain `db:seed` when ESPN isn't run.
- UI edits via `/teams/:slug/depth-chart` (drag-reorder, lock toggle) flow immediately to `/nfl-rosters`. Locked entries are skipped by all refresh paths.

## Slot Label Rendering

`LineupLabelsHelper.offense_slot_label(slot, pick)` and `defense_slot_label(slot, pick)` produce display badges. Depth digits dropped (depth implied by left-to-right slot order: WR1/WR2/WR3 all show "WR", E1/E2 show "EG", etc.). Flex slots derive their label from `pick.position` so a TE2 in offense Flex shows "TE", a slot CB in defensive Flex shows "CB". Used by both `/nfl-rosters` and `/teams/:slug/depth-chart`.
