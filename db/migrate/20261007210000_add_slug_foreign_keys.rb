# Slug foreign keys, step 1 of 2: every slug column the census resolves takes a
# foreign key to its parent's `slug`, ON UPDATE CASCADE, so a slug change rewrites
# every child in the same statement and a dangling slug can no longer be written.
# ON DELETE refuses (NO ACTION, shown as nil) unless the parent's association
# nullifies or the column is a log pointer (SET NULL), or the rows belong to the
# parent outright (CASCADE). NO ACTION rather than RESTRICT: Postgres raises a
# foreign-key violation for it, which Rails reads as InvalidForeignKey and the
# controllers answer with a 422; RESTRICT raises a different error that Rails
# leaves as a bare StatementInvalid.
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

  # [child table, column, parent table, on_delete (nil = NO ACTION)]
  KEYS = [
    ["action_grades", "source_activity_slug", "activities", :nullify],
    ["activities", "agent_slug", "agents", nil],
    ["activities", "task_slug", "tasks", :nullify],
    ["agent_actions", "task_slug", "tasks", :nullify],
    ["agent_activities", "task_slug", "tasks", :nullify],
    ["agent_sessions", "task_slug", "tasks", :nullify],
    ["alt_video_clips", "alt_video_slug", "alt_videos", nil],
    ["alt_videos", "music_video_slug", "music_videos", nil],
    ["app_requests", "task_slug", "tasks", :nullify],
    ["appearance_reference_photos", "appearance_slug", "appearances", nil],
    ["appearances", "base_appearance_slug", "appearances", :nullify],
    ["appearances", "music_video_slug", "music_videos", :nullify],
    ["appearances", "person_slug", "people", nil],
    ["artifact_subjects", "appearance_slug", "appearances", :nullify],
    ["artifact_subjects", "artifact_slug", "artifacts", nil],
    ["artifact_subjects", "person_slug", "people", nil],
    ["artifacts", "brief_slug", "email_image_briefs", :nullify],
    ["artist_aliases", "artist_slug", "artists", nil],
    ["artist_memberships", "group_artist_slug", "artists", nil],
    ["artist_memberships", "member_artist_slug", "artists", nil],
    ["artists", "person_slug", "people", :nullify],
    ["athlete_grades", "athlete_slug", "athletes", nil],
    ["athlete_grades", "season_slug", "seasons", nil],
    ["athletes", "person_slug", "people", nil],
    ["coach_rankings", "coach_slug", "coaches", nil],
    ["coach_rankings", "season_slug", "seasons", nil],
    ["coaches", "person_slug", "people", nil],
    ["coaches", "team_slug", "teams", nil],
    ["contents", "source_news_slug", "news", :nullify],
    ["contracts", "person_slug", "people", nil],
    ["contracts", "team_slug", "teams", nil],
    ["credential_records", "credential_vault_slug", "credential_vaults", nil],
    ["depth_chart_entries", "depth_chart_slug", "depth_charts", nil],
    ["depth_chart_entries", "person_slug", "people", nil],
    ["depth_charts", "team_slug", "teams", nil],
    ["desk_records", "app_slug", "apps", :nullify],
    ["desk_records", "task_slug", "tasks", :nullify],
    ["email_image_briefs", "approved_artifact_slug", "artifacts", :nullify],
    ["games", "away_team_slug", "teams", nil],
    ["games", "home_team_slug", "teams", nil],
    ["games", "slate_slug", "slates", nil],
    ["music_video_artists", "artist_slug", "artists", nil],
    ["music_video_artists", "music_video_slug", "music_videos", nil],
    ["news", "primary_person_slug", "people", :nullify],
    ["news", "primary_team_slug", "teams", :nullify],
    ["news", "secondary_person_slug", "people", :nullify],
    ["news", "secondary_team_slug", "teams", :nullify],
    ["people", "default_appearance_slug", "appearances", :nullify],
    ["person_jewelries", "person_slug", "people", nil],
    ["pff_stats", "athlete_slug", "athletes", nil],
    ["pff_stats", "season_slug", "seasons", nil],
    ["pff_team_stats", "season_slug", "seasons", nil],
    ["pff_team_stats", "team_slug", "teams", nil],
    ["release_events", "release_slug", "releases", nil],
    # A pending review action belongs to its task's review queue.
    ["review_pending_actions", "task_slug", "tasks", :cascade],
    ["roster_spots", "person_slug", "people", nil],
    ["rosters", "slate_slug", "slates", nil],
    ["rosters", "team_slug", "teams", nil],
    ["skill_assignments", "agent_slug", "agents", nil],
    ["skill_assignments", "skill_slug", "skills", nil],
    ["slates", "season_slug", "seasons", nil],
    ["task_events", "task_slug", "tasks", nil],
    ["task_grades", "note_activity_slug", "activities", :nullify],
    ["task_grades", "task_slug", "tasks", nil],
    ["task_review_claims", "task_slug", "tasks", nil],
    ["tasks", "agent_slug", "agents", :nullify],
    ["tasks", "release_slug", "releases", :nullify],
    ["team_rankings", "season_slug", "seasons", nil],
    ["team_rankings", "team_slug", "teams", nil],
    ["teams", "home_arena_slug", "arenas", :nullify],
    ["triage_findings", "promoted_task_slug", "tasks", :nullify],
    ["usages", "agent_slug", "agents", nil],
    ["video_chunk_takes", "music_video_slug", "music_videos", nil],
    ["video_clips", "music_video_slug", "music_videos", nil],
    ["video_performers", "artist_slug", "artists", :nullify],
    ["video_performers", "music_video_slug", "music_videos", nil],
    ["video_performers", "recast_appearance_slug", "appearances", :nullify],
    ["video_performers", "recast_person_slug", "people", :nullify],
    ["video_stitches", "alt_video_slug", "alt_videos", nil],
    ["video_stitches", "music_video_slug", "music_videos", nil]
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
    # (nil, :nullify, :cascade), so the two compare directly.
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
