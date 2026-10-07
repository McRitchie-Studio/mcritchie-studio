# Slug foreign keys, step 1 of 2: every slug column the census resolves takes a
# foreign key to its parent's `slug`, ON UPDATE CASCADE, so a slug change rewrites
# every child in the same statement and a dangling slug can no longer be written.
# ON DELETE is RESTRICT unless the parent's association nullifies or the column
# is a log pointer (SET NULL), or the rows belong to the parent outright (CASCADE).
#
# Each key is added NOT VALID: Postgres checks every new write at once but skips
# the existing rows, so the ALTER holds its locks for an instant. Step 2
# (ValidateSlugForeignKeys) cleans the existing orphans and validates.
#
# One statement per key, outside a transaction, with a short lock_timeout: a
# single transaction would hold locks on every parent and child until commit and
# could deadlock the app's writers. A key that cannot take its lock in time is
# retried; the migration is idempotent, so a re-run resumes where it stopped.
#
# The columns left unconstrained, with their reasons: SlugCensus::UNCONSTRAINED.
class AddSlugForeignKeys < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s".freeze
  ATTEMPTS = 3

  # [child table, column, parent table, on_delete]
  KEYS = [
    ["action_grades", "source_activity_slug", "activities", :nullify],
    ["activities", "agent_slug", "agents", :restrict],
    ["activities", "task_slug", "tasks", :nullify],
    ["agent_actions", "task_slug", "tasks", :nullify],
    ["agent_activities", "task_slug", "tasks", :nullify],
    ["agent_sessions", "task_slug", "tasks", :nullify],
    ["alt_video_clips", "alt_video_slug", "alt_videos", :restrict],
    ["alt_videos", "music_video_slug", "music_videos", :restrict],
    ["app_requests", "task_slug", "tasks", :nullify],
    ["appearance_reference_photos", "appearance_slug", "appearances", :restrict],
    ["appearances", "base_appearance_slug", "appearances", :nullify],
    ["appearances", "music_video_slug", "music_videos", :nullify],
    ["appearances", "person_slug", "people", :restrict],
    ["artifact_subjects", "appearance_slug", "appearances", :nullify],
    ["artifact_subjects", "artifact_slug", "artifacts", :restrict],
    ["artifact_subjects", "person_slug", "people", :restrict],
    ["artifacts", "brief_slug", "email_image_briefs", :nullify],
    ["artist_aliases", "artist_slug", "artists", :restrict],
    ["artist_memberships", "group_artist_slug", "artists", :restrict],
    ["artist_memberships", "member_artist_slug", "artists", :restrict],
    ["artists", "person_slug", "people", :nullify],
    ["athlete_grades", "athlete_slug", "athletes", :restrict],
    ["athlete_grades", "season_slug", "seasons", :restrict],
    ["athletes", "person_slug", "people", :restrict],
    ["coach_rankings", "coach_slug", "coaches", :restrict],
    ["coach_rankings", "season_slug", "seasons", :restrict],
    ["coaches", "person_slug", "people", :restrict],
    ["coaches", "team_slug", "teams", :restrict],
    ["contents", "source_news_slug", "news", :nullify],
    ["contracts", "person_slug", "people", :restrict],
    ["contracts", "team_slug", "teams", :restrict],
    ["credential_records", "credential_vault_slug", "credential_vaults", :restrict],
    ["depth_chart_entries", "depth_chart_slug", "depth_charts", :restrict],
    ["depth_chart_entries", "person_slug", "people", :restrict],
    ["depth_charts", "team_slug", "teams", :restrict],
    ["desk_records", "app_slug", "apps", :nullify],
    ["desk_records", "task_slug", "tasks", :nullify],
    ["email_image_briefs", "approved_artifact_slug", "artifacts", :nullify],
    ["games", "away_team_slug", "teams", :restrict],
    ["games", "home_team_slug", "teams", :restrict],
    ["games", "slate_slug", "slates", :restrict],
    ["music_video_artists", "artist_slug", "artists", :restrict],
    ["music_video_artists", "music_video_slug", "music_videos", :restrict],
    ["news", "primary_person_slug", "people", :nullify],
    ["news", "primary_team_slug", "teams", :nullify],
    ["news", "secondary_person_slug", "people", :nullify],
    ["news", "secondary_team_slug", "teams", :nullify],
    ["people", "default_appearance_slug", "appearances", :nullify],
    ["person_jewelries", "person_slug", "people", :restrict],
    ["pff_stats", "athlete_slug", "athletes", :restrict],
    ["pff_stats", "season_slug", "seasons", :restrict],
    ["pff_team_stats", "season_slug", "seasons", :restrict],
    ["pff_team_stats", "team_slug", "teams", :restrict],
    ["release_events", "release_slug", "releases", :restrict],
    # A pending review action belongs to its task's review queue.
    ["review_pending_actions", "task_slug", "tasks", :cascade],
    ["roster_spots", "person_slug", "people", :restrict],
    ["rosters", "slate_slug", "slates", :restrict],
    ["rosters", "team_slug", "teams", :restrict],
    ["skill_assignments", "agent_slug", "agents", :restrict],
    ["skill_assignments", "skill_slug", "skills", :restrict],
    ["slates", "season_slug", "seasons", :restrict],
    ["task_events", "task_slug", "tasks", :restrict],
    ["task_grades", "note_activity_slug", "activities", :nullify],
    ["task_grades", "task_slug", "tasks", :restrict],
    ["task_review_claims", "task_slug", "tasks", :restrict],
    ["tasks", "agent_slug", "agents", :nullify],
    ["tasks", "release_slug", "releases", :nullify],
    ["team_rankings", "season_slug", "seasons", :restrict],
    ["team_rankings", "team_slug", "teams", :restrict],
    ["teams", "home_arena_slug", "arenas", :nullify],
    ["triage_findings", "promoted_task_slug", "tasks", :nullify],
    ["usages", "agent_slug", "agents", :restrict],
    ["video_chunk_takes", "music_video_slug", "music_videos", :restrict],
    ["video_clips", "music_video_slug", "music_videos", :restrict],
    ["video_performers", "artist_slug", "artists", :nullify],
    ["video_performers", "music_video_slug", "music_videos", :restrict],
    ["video_performers", "recast_appearance_slug", "appearances", :nullify],
    ["video_performers", "recast_person_slug", "people", :nullify],
    ["video_stitches", "alt_video_slug", "alt_videos", :restrict],
    ["video_stitches", "music_video_slug", "music_videos", :restrict]
  ].freeze

  def up
    with_lock_timeout do
      KEYS.each { |child, column, parent, on_delete| add_key(child, column, parent, on_delete) }
    end
  end

  def down
    KEYS.each do |child, column, parent, _on_delete|
      remove_foreign_key child, parent, column: column if foreign_key_exists?(child, parent, column: column)
    end
    # The vault key predates this migration: put it back as it was.
    add_foreign_key "credential_records", "credential_vaults", column: "credential_vault_slug", primary_key: "slug"
  end

  private

  def add_key(child, column, parent, on_delete)
    # foreign_keys reads ON DELETE back as the symbol add_foreign_key takes
    # (:restrict, :nullify, :cascade), so the two compare directly.
    existing = foreign_keys(child).find { |key| key.column == column && key.to_table == parent }
    return if existing&.on_update == :cascade && existing.on_delete == on_delete

    attempt = 0
    begin
      attempt += 1
      remove_foreign_key child, parent, column: column if existing
      existing = nil
      add_foreign_key child, parent, column: column, primary_key: "slug",
                                     on_update: :cascade, on_delete: on_delete, validate: false
    rescue ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked
      raise if attempt >= ATTEMPTS

      say "#{child}.#{column}: lock not granted, retry #{attempt}"
      sleep attempt
      retry
    end
  end

  def with_lock_timeout
    execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    yield
  ensure
    execute "RESET lock_timeout"
  end
end
