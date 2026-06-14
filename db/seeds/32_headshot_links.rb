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

puts "\n--- NFL coach headshot identity links ---"

require "rake"
Rails.application.load_tasks unless Rake::Task.task_defined?("nfl:link_coach_headshots")

Rake::Task["nfl:link_coach_headshots"].invoke
Rake::Task["nfl:link_coach_headshots_from_team_sites"].invoke
