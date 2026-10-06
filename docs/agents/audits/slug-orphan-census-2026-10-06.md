# Slug orphan census — production, 2026-10-06

**Task:** https://mcritchie.studio/tasks/slug-orphan-census-report · **Epic:** platform-audit-refactors, piece 5a (feeds 5b, the slug freeze)

`bin/rails db:slug_census` (`lib/tasks/db_slug_census.rake`, `app/services/slug_census.rb`)
lists every `*_slug` column in the database, the table it points at, and how many
of its rows name a slug no target row holds (NULL slugs are not orphans). The
target comes from the owning model's `belongs_to` when one names the column,
else from the column's name (`home_team_slug` tries `home_teams`, then `teams`),
else the column is `unresolved`.

The run is read-only by construction: SELECTs only, no transaction, all inside
`ActiveRecord::Base.while_preventing_writes`, and the production session also
set `default_transaction_read_only = on`. `test/services/slug_census_test.rb`
measures a full run over `sql.active_record`. Sample values whose target holds
people (`people`, `users`, `contacts`) are withheld; none of those columns has
orphans today.

## Reading for 5b

**Constrain today: 68 columns.** Every resolved column with zero orphans can take
its foreign key now (`ON UPDATE CASCADE`, added `NOT VALID` then validated); 41 of them hold no filled rows yet, and
`credential_records.credential_vault_slug` already has its key. Eight of them resolve by name only, with no `belongs_to` on the model: `contents.game_slug`, `desk_records.task_slug`,
`news.primary_person_slug`, `news.primary_team_slug`, `news.secondary_person_slug`,
`news.secondary_team_slug`, `task_review_claims.task_slug` and
`triage_findings.promoted_task_slug`. 5b declares the association before it adds
the key.

**Clean up first: 11 columns, 2,350 orphan rows.**

| Column | Orphans | What the orphans are | Cleanup |
|---|---:|---|---|
| `athletes.team_slug` | 2,051 | every filled row: no athlete's team slug matches a `teams` row | reseed or re-import `teams` before the key; 5b decides whether this column is constrained at all |
| `activities.agent_slug` | 89 | soul, tool and mascot handles with no `agents` row (`claude`, `codex`, `abra`) | add the missing agents, or nullify |
| `agent_activities.task_slug` | 61 | task slugs with no `tasks` row (a renamed or deleted task) | nullify, and the key takes `ON DELETE SET NULL` |
| `desk_records.app_slug` | 59 | one value, `studio-engine.sibling`, which is not an app | map to `studio-engine` or nullify |
| `agent_actions.task_slug` | 53 | task slugs with no `tasks` row | nullify |
| `tasks.agent_slug` | 30 | handles with no `agents` row, including a capitalised `Codex` | normalise case, add or nullify |
| `appearances.team_slug` | 3 | NFL team slugs with no `teams` row | same cause as `athletes.team_slug` |
| `activities.task_slug` | 1 | a task slug with no `tasks` row | nullify |
| `app_requests.task_slug` | 1 | a task slug with no `tasks` row | nullify |
| `contents.team_slug` | 1 | an NFL team slug with no `teams` row | same cause as `athletes.team_slug` |
| `release_conductor_claims.release_slug` | 1 | the sentinel `__forming__`, a claim on a release not yet named | not an orphan to clean: the sentinel needs its own column or a NULL before a key fits |

**Not foreign keys: 11 unresolved columns.** They hold vocabularies or handles, not
row pointers, and 5b leaves them unconstrained: `agent_actions.event_slug`,
`agent_actions.result_slug`, `agent_activities.outcome_slug`,
`agent_activities.reason_slug` (event vocabularies), `gate_runs.subject_slug`
(polymorphic with `subject_type`), `tasks.epic_slug` (epic plans live in files),
`session_mascots.mascot_slug` (the mascot roster is config), `desk_records.desk_slug`,
`studio_survey_responses.survey_slug` (engine survey config), and
`contents.qb_player_slug`, `contents.skill_player_slug` (no `belongs_to` and no
`players` table; 5b decides whether they point at `athletes`).

## Production output

Run on a one-off `standard-1x` dyno of `mcritchie-studio` against the shipped
schema; the census code was passed to `bin/rails runner`, since it is not yet deployed.

| Column | Target | Via | Rows | Filled | Orphans | Sample orphans |
|---|---|---|---:|---:|---:|---|
| `action_grades.source_activity_slug` | activities.slug | belongs_to | 601 | 575 | 0 |  |
| `activities.agent_slug` | agents.slug | belongs_to | 12362 | 11149 | 89 | `abra`, `avi-scout`, `charmander`, `claude`, `codex` |
| `activities.task_slug` | tasks.slug | belongs_to | 12362 | 12336 | 1 | `model-model-pipeline-swim-lanes` |
| `agent_actions.event_slug` | unresolved | unresolved | 308445 | 935 | - |  |
| `agent_actions.result_slug` | unresolved | unresolved | 308445 | 935 | - |  |
| `agent_actions.task_slug` | tasks.slug | belongs_to | 308445 | 292135 | 53 | `preview-engine-style`, `turn-on-devnet-nightly` |
| `agent_activities.outcome_slug` | unresolved | unresolved | 26188 | 17854 | - |  |
| `agent_activities.reason_slug` | unresolved | unresolved | 26188 | 26188 | - |  |
| `agent_activities.task_slug` | tasks.slug | belongs_to | 26188 | 24569 | 61 | `codex-stop-hook-cleanup`, `codex-stop-hook-json`, `fix-red-400-ratio-citation`, `island-illustration-workflow-audit`, `live-score-watch` |
| `app_requests.task_slug` | tasks.slug | convention | 7 | 7 | 1 | `build-launch-app-chess-game` |
| `appearance_reference_photos.appearance_slug` | appearances.slug | belongs_to | 177 | 177 | 0 |  |
| `appearances.music_video_slug` | music_videos.slug | belongs_to | 7 | 0 | 0 |  |
| `appearances.person_slug` | people.slug | belongs_to | 7 | 7 | 0 |  |
| `appearances.team_slug` | teams.slug | belongs_to | 7 | 3 | 3 | `denver-broncos`, `los-angeles-chargers`, `seattle-seahawks` |
| `artifact_subjects.appearance_slug` | appearances.slug | belongs_to | 5 | 5 | 0 |  |
| `artifact_subjects.artifact_slug` | artifacts.slug | belongs_to | 5 | 5 | 0 |  |
| `artifact_subjects.person_slug` | people.slug | belongs_to | 5 | 5 | 0 |  |
| `artist_aliases.artist_slug` | artists.slug | belongs_to | 20743 | 20743 | 0 |  |
| `artist_memberships.group_artist_slug` | artists.slug | belongs_to | 11308 | 11308 | 0 |  |
| `artist_memberships.member_artist_slug` | artists.slug | belongs_to | 11308 | 11308 | 0 |  |
| `artists.person_slug` | people.slug | belongs_to | 22616 | 0 | 0 |  |
| `athlete_grades.athlete_slug` | athletes.slug | belongs_to | 0 | 0 | 0 |  |
| `athlete_grades.season_slug` | seasons.slug | belongs_to | 0 | 0 | 0 |  |
| `athletes.person_slug` | people.slug | belongs_to | 2051 | 2051 | 0 |  |
| `athletes.team_slug` | teams.slug | belongs_to | 2051 | 2051 | 2051 | `arizona-cardinals`, `atlanta-falcons`, `baltimore-ravens`, `buffalo-bills`, `carolina-panthers` |
| `coach_rankings.coach_slug` | coaches.slug | belongs_to | 0 | 0 | 0 |  |
| `coach_rankings.season_slug` | seasons.slug | belongs_to | 0 | 0 | 0 |  |
| `coaches.person_slug` | people.slug | belongs_to | 0 | 0 | 0 |  |
| `coaches.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `contents.game_slug` | games.slug | convention | 1 | 0 | 0 |  |
| `contents.qb_player_slug` | unresolved | unresolved | 1 | 1 | - |  |
| `contents.rival_team_slug` | teams.slug | belongs_to | 1 | 0 | 0 |  |
| `contents.skill_player_slug` | unresolved | unresolved | 1 | 1 | - |  |
| `contents.source_news_slug` | news.slug | belongs_to | 1 | 0 | 0 |  |
| `contents.team_slug` | teams.slug | belongs_to | 1 | 1 | 1 | `seattle-seahawks` |
| `contracts.person_slug` | people.slug | belongs_to | 0 | 0 | 0 |  |
| `contracts.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `credential_records.credential_vault_slug` | credential_vaults.slug | belongs_to | 50 | 50 | 0 |  |
| `depth_chart_entries.depth_chart_slug` | depth_charts.slug | belongs_to | 0 | 0 | 0 |  |
| `depth_chart_entries.person_slug` | people.slug | belongs_to | 0 | 0 | 0 |  |
| `depth_charts.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `desk_records.app_slug` | apps.slug | convention | 1503 | 1420 | 59 | `studio-engine.sibling` |
| `desk_records.desk_slug` | unresolved | unresolved | 1503 | 1420 | - |  |
| `desk_records.task_slug` | tasks.slug | convention | 1503 | 1015 | 0 |  |
| `games.away_team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `games.home_team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `games.slate_slug` | slates.slug | belongs_to | 0 | 0 | 0 |  |
| `gate_runs.subject_slug` | unresolved | unresolved | 11849 | 11849 | - |  |
| `music_video_artists.artist_slug` | artists.slug | belongs_to | 1 | 1 | 0 |  |
| `music_video_artists.music_video_slug` | music_videos.slug | belongs_to | 1 | 1 | 0 |  |
| `news.primary_person_slug` | people.slug | convention | 0 | 0 | 0 |  |
| `news.primary_team_slug` | teams.slug | convention | 0 | 0 | 0 |  |
| `news.secondary_person_slug` | people.slug | convention | 0 | 0 | 0 |  |
| `news.secondary_team_slug` | teams.slug | convention | 0 | 0 | 0 |  |
| `people.default_appearance_slug` | appearances.slug | belongs_to | 2088 | 6 | 0 |  |
| `pff_stats.athlete_slug` | athletes.slug | belongs_to | 0 | 0 | 0 |  |
| `pff_stats.season_slug` | seasons.slug | belongs_to | 0 | 0 | 0 |  |
| `pff_stats.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `pff_team_stats.season_slug` | seasons.slug | belongs_to | 0 | 0 | 0 |  |
| `pff_team_stats.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `release_conductor_claims.release_slug` | releases.slug | convention | 619 | 619 | 1 | `__forming__` |
| `release_events.release_slug` | releases.slug | belongs_to | 6853 | 6853 | 0 |  |
| `review_pending_actions.task_slug` | tasks.slug | belongs_to | 128 | 128 | 0 |  |
| `roster_spots.person_slug` | people.slug | belongs_to | 0 | 0 | 0 |  |
| `rosters.slate_slug` | slates.slug | belongs_to | 0 | 0 | 0 |  |
| `rosters.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `session_mascots.mascot_slug` | unresolved | unresolved | 872 | 872 | - |  |
| `skill_assignments.agent_slug` | agents.slug | belongs_to | 0 | 0 | 0 |  |
| `skill_assignments.skill_slug` | skills.slug | belongs_to | 0 | 0 | 0 |  |
| `slates.season_slug` | seasons.slug | belongs_to | 0 | 0 | 0 |  |
| `studio_survey_responses.survey_slug` | unresolved | unresolved | 0 | 0 | - |  |
| `task_events.task_slug` | tasks.slug | belongs_to | 35165 | 35165 | 0 |  |
| `task_grades.note_activity_slug` | activities.slug | belongs_to | 446 | 145 | 0 |  |
| `task_grades.task_slug` | tasks.slug | belongs_to | 446 | 446 | 0 |  |
| `task_review_claims.task_slug` | tasks.slug | convention | 1681 | 1681 | 0 |  |
| `tasks.agent_slug` | agents.slug | belongs_to | 2767 | 530 | 30 | `claude`, `codex`, `Codex`, `ditto`, `exeggutor` |
| `tasks.epic_slug` | unresolved | unresolved | 2767 | 43 | - |  |
| `tasks.release_slug` | releases.slug | belongs_to | 2767 | 2349 | 0 |  |
| `team_rankings.season_slug` | seasons.slug | belongs_to | 0 | 0 | 0 |  |
| `team_rankings.team_slug` | teams.slug | belongs_to | 0 | 0 | 0 |  |
| `teams.home_arena_slug` | arenas.slug | belongs_to | 0 | 0 | 0 |  |
| `triage_findings.promoted_task_slug` | tasks.slug | convention | 132 | 0 | 0 |  |
| `usages.agent_slug` | agents.slug | belongs_to | 0 | 0 | 0 |  |
| `video_chunk_takes.music_video_slug` | music_videos.slug | belongs_to | 0 | 0 | 0 |  |
| `video_clips.music_video_slug` | music_videos.slug | belongs_to | 7 | 7 | 0 |  |
| `video_performers.artist_slug` | artists.slug | belongs_to | 5 | 1 | 0 |  |
| `video_performers.music_video_slug` | music_videos.slug | belongs_to | 5 | 5 | 0 |  |
| `video_performers.recast_appearance_slug` | appearances.slug | belongs_to | 5 | 1 | 0 |  |
| `video_performers.recast_person_slug` | people.slug | belongs_to | 5 | 1 | 0 |  |
| `video_stitches.music_video_slug` | music_videos.slug | belongs_to | 0 | 0 | 0 |  |

columns: 90 · resolved: 79 · unresolved: 11 · clean: 68 · with orphans: 11 · orphan rows: 2350
