# Coach headshot URL discovery (athlete URLs come from nfl:players_seed via
# nflverse master CSV, not this seed).
#
# - Coaches: HCs from ESPN's v2 coaches API + all 4 roles (HC + 3 coordinators)
#   scraped from each team's NFL.com /team/coaches[-roster]/ page via the
#   TEAM_NFL_SUBDOMAIN map in lib/tasks/nfl.rake.
#
# DB-only — no S3 traffic. Image upload + caching happens in
# bin/rails nfl:upload_coach_headshots (called during the full NFL rebuild).
#
# Idempotent — re-seeds only update rows whose source URL has changed.
#
# BOTH TASKS NOW ABORT ON A RUN THAT LINKED NOTHING, and this is the seed that
# carries that exit code out. `bin/ecosystem-build` runs `rails db:seed` with both
# streams sent to /dev/null and `exit 1`s the rebuild on a non-zero status, so the
# status is the ONLY signal it can read and every `puts` below is invisible there.

require "rake"
Rails.application.load_tasks unless Rake::Task.task_defined?("nfl:link_coach_headshots")

# THE DOCUMENTED ESCAPE HATCH, WHICH DID NOT EXIST.
# docs/agents/system/house-burn-down.md has told a firewalled operator to "skip
# with SKIP_NETWORK_SEEDS=1" for as long as that page has described this phase,
# and NOTHING read the variable — MEASURED 2026-09-28, a repo-wide grep found it
# in that one sentence of prose and in no code at all.
#
# IT WAS INERT AND HARMLESS UNTIL TODAY, and it is neither now. While these two
# tasks failed quietly, a firewalled `db:seed` linked no coach and still exited 0;
# now it aborts, and a rebuild behind a firewall takes bin/ecosystem-build's
# `exit 1` with it. Making the lane loud is what turns a fabricated remedy into a
# load-bearing one, so the hatch is real in the same change.
#
# IT ANNOUNCES ITSELF ON STDERR, because a skipped seed is not a seeded one: with
# no `espn_headshot_url` on any Coach, `nfl:upload_coach_headshots` caches nothing
# and every coach avatar falls back. Opt-in only — unset is the normal path, and
# `== "1"` is both the spelling that page documents and this repo's env idiom.
if ENV["SKIP_NETWORK_SEEDS"] == "1"
  puts "\n--- NFL coach headshot identity links: SKIPPED (SKIP_NETWORK_SEEDS=1) ---"
  warn "SKIP_NETWORK_SEEDS=1: skipped nfl:link_coach_headshots and " \
       "nfl:link_coach_headshots_from_team_sites. No Coach carries an espn_headshot_url, so " \
       "nfl:upload_coach_headshots will cache nothing and every coach avatar falls back. " \
       "Run those two tasks once you have network access."
else
  puts "\n--- NFL coach headshot identity links (network; SKIP_NETWORK_SEEDS=1 to skip) ---"

  Rake::Task["nfl:link_coach_headshots"].invoke
  Rake::Task["nfl:link_coach_headshots_from_team_sites"].invoke
end
