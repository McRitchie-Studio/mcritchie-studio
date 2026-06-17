# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_06_17_182000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activities", force: :cascade do |t|
    t.string "agent_slug"
    t.string "activity_type"
    t.text "description"
    t.string "task_slug"
    t.jsonb "metadata", default: {}
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["activity_type", "created_at"], name: "index_activities_on_activity_type_and_created_at"
    t.index ["activity_type"], name: "index_activities_on_activity_type"
    t.index ["agent_slug"], name: "index_activities_on_agent_slug"
    t.index ["slug"], name: "index_activities_on_slug", unique: true
    t.index ["task_slug"], name: "index_activities_on_task_slug"
  end

  create_table "agents", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "status", default: "active"
    t.text "description"
    t.string "agent_type"
    t.string "title"
    t.jsonb "config", default: {}
    t.jsonb "metadata", default: {}
    t.datetime "last_active_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "avatar"
    t.integer "position", default: 0
    t.index ["slug"], name: "index_agents_on_slug", unique: true
    t.index ["status"], name: "index_agents_on_status"
  end

  create_table "arenas", force: :cascade do |t|
    t.string "slug", null: false
    t.string "name", null: false
    t.string "address"
    t.string "location"
    t.string "city"
    t.string "state"
    t.string "country"
    t.string "timezone"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_arenas_on_slug", unique: true
  end

  create_table "athlete_grades", force: :cascade do |t|
    t.string "athlete_slug", null: false
    t.string "season_slug", null: false
    t.float "overall_grade_pff"
    t.float "offense_grade_pff"
    t.float "defense_grade_pff"
    t.float "pass_grade_pff"
    t.float "run_grade_pff"
    t.float "pass_route_grade_pff"
    t.float "pass_block_grade_pff"
    t.float "run_block_grade_pff"
    t.float "pass_rush_grade_pff"
    t.float "coverage_grade_pff"
    t.float "rush_defense_grade_pff"
    t.integer "games_played"
    t.integer "snaps"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.float "fg_grade_pff"
    t.float "kickoff_grade_pff"
    t.float "punting_grade_pff"
    t.float "return_grade_pff"
    t.jsonb "grade_ranges"
    t.integer "position_pass_rank"
    t.integer "position_pass_grade"
    t.integer "position_run_rank"
    t.integer "position_run_grade"
    t.index ["athlete_slug", "season_slug"], name: "index_athlete_grades_on_athlete_slug_and_season_slug", unique: true
    t.index ["athlete_slug"], name: "index_athlete_grades_on_athlete_slug"
    t.index ["position_pass_rank"], name: "index_athlete_grades_on_position_pass_rank"
    t.index ["position_run_rank"], name: "index_athlete_grades_on_position_run_rank"
    t.index ["season_slug"], name: "index_athlete_grades_on_season_slug"
    t.index ["slug"], name: "index_athlete_grades_on_slug", unique: true
  end

  create_table "athletes", force: :cascade do |t|
    t.string "person_slug", null: false
    t.string "sport", null: false
    t.string "position"
    t.integer "draft_year"
    t.integer "draft_round"
    t.integer "draft_pick"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "pff_id"
    t.string "skin_tone"
    t.string "hair_description"
    t.string "build"
    t.integer "height_inches"
    t.integer "weight_lbs"
    t.string "espn_id"
    t.string "espn_headshot_url"
    t.string "team_slug"
    t.string "gsis_id"
    t.string "otc_id"
    t.string "sleeper_id"
    t.string "pfr_id"
    t.string "nflverse_id"
    t.index ["espn_id"], name: "index_athletes_on_espn_id"
    t.index ["gsis_id"], name: "index_athletes_on_gsis_id", unique: true
    t.index ["nflverse_id"], name: "index_athletes_on_nflverse_id", unique: true
    t.index ["otc_id"], name: "index_athletes_on_otc_id", unique: true
    t.index ["person_slug"], name: "index_athletes_on_person_slug", unique: true
    t.index ["pff_id"], name: "index_athletes_on_pff_id", unique: true
    t.index ["pfr_id"], name: "index_athletes_on_pfr_id", unique: true
    t.index ["position"], name: "index_athletes_on_position"
    t.index ["sleeper_id"], name: "index_athletes_on_sleeper_id", unique: true
    t.index ["slug"], name: "index_athletes_on_slug", unique: true
    t.index ["sport"], name: "index_athletes_on_sport"
    t.index ["team_slug"], name: "index_athletes_on_team_slug"
  end

  create_table "broadcast_deliveries", force: :cascade do |t|
    t.bigint "broadcast_id", null: false
    t.bigint "contact_id", null: false
    t.string "token", null: false
    t.datetime "sent_at"
    t.datetime "opened_at"
    t.integer "open_count", default: 0, null: false
    t.datetime "clicked_at"
    t.integer "click_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["broadcast_id", "contact_id"], name: "index_broadcast_deliveries_on_broadcast_id_and_contact_id", unique: true
    t.index ["broadcast_id"], name: "index_broadcast_deliveries_on_broadcast_id"
    t.index ["contact_id"], name: "index_broadcast_deliveries_on_contact_id"
    t.index ["token"], name: "index_broadcast_deliveries_on_token", unique: true
  end

  create_table "broadcasts", force: :cascade do |t|
    t.string "slug", null: false
    t.string "subject", default: "", null: false
    t.string "preview_text"
    t.string "template_key", null: false
    t.string "status", default: "draft", null: false
    t.string "target_list"
    t.string "survivor_url"
    t.string "turf_totals_url"
    t.datetime "sent_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "header"
    t.string "subheader"
    t.string "hero_url"
    t.index ["slug"], name: "index_broadcasts_on_slug", unique: true
    t.index ["status"], name: "index_broadcasts_on_status"
  end

  create_table "builders", force: :cascade do |t|
    t.bigint "person_id", null: false
    t.string "github_login", null: false
    t.string "github_profile_url"
    t.string "github_avatar_url"
    t.string "github_name"
    t.string "github_company"
    t.text "github_bio"
    t.string "github_blog"
    t.string "github_email"
    t.string "github_twitter_username"
    t.string "primary_language"
    t.string "source_dataset"
    t.string "source_url"
    t.integer "source_rank"
    t.integer "source_contributions"
    t.boolean "active", default: true, null: false
    t.jsonb "raw_profile", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "included_in_roster", default: true, null: false
    t.index ["active", "included_in_roster"], name: "index_builders_on_active_and_included_in_roster"
    t.index ["github_login"], name: "index_builders_on_github_login", unique: true
    t.index ["person_id"], name: "index_builders_on_person_id"
    t.index ["primary_language", "active"], name: "index_builders_on_primary_language_and_active"
    t.index ["source_dataset"], name: "index_builders_on_source_dataset"
  end

  create_table "coach_rankings", force: :cascade do |t|
    t.string "coach_slug", null: false
    t.string "season_slug", null: false
    t.string "rank_type", null: false
    t.integer "rank", null: false
    t.string "tier"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["coach_slug", "rank_type", "season_slug"], name: "index_coach_rankings_unique_type_season", unique: true
    t.index ["coach_slug"], name: "index_coach_rankings_on_coach_slug"
    t.index ["season_slug"], name: "index_coach_rankings_on_season_slug"
    t.index ["slug"], name: "index_coach_rankings_on_slug", unique: true
  end

  create_table "coaches", force: :cascade do |t|
    t.string "person_slug", null: false
    t.string "team_slug", null: false
    t.string "role", null: false
    t.string "lean"
    t.string "sport", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "espn_id"
    t.string "espn_headshot_url"
    t.index ["espn_id"], name: "index_coaches_on_espn_id"
    t.index ["person_slug", "team_slug", "role"], name: "index_coaches_unique_role", unique: true
    t.index ["person_slug"], name: "index_coaches_on_person_slug"
    t.index ["slug"], name: "index_coaches_on_slug", unique: true
    t.index ["sport"], name: "index_coaches_on_sport"
    t.index ["team_slug"], name: "index_coaches_on_team_slug"
  end

  create_table "contacts", force: :cascade do |t|
    t.string "email", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "tags", default: [], null: false, array: true
    t.boolean "subscribed", default: true, null: false
    t.datetime "unsubscribed_at"
    t.string "unsubscribe_token", null: false
    t.string "source"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_contacts_on_lower_email", unique: true
    t.index ["tags"], name: "index_contacts_on_tags", using: :gin
    t.index ["unsubscribe_token"], name: "index_contacts_on_unsubscribe_token", unique: true
  end

  create_table "contents", force: :cascade do |t|
    t.string "stage", default: "idea", null: false
    t.integer "position"
    t.string "slug", null: false
    t.string "title", null: false
    t.text "description"
    t.string "source_type"
    t.string "source_news_slug"
    t.string "content_type", default: "tiktok_video"
    t.string "hook_image_url"
    t.jsonb "hook_ideas", default: []
    t.integer "selected_hook_index"
    t.text "script_text"
    t.integer "duration_seconds"
    t.jsonb "scenes", default: []
    t.jsonb "scene_assets", default: []
    t.string "final_video_url"
    t.string "music_track"
    t.jsonb "text_overlays", default: []
    t.boolean "logo_overlay", default: true
    t.string "platform", default: "tiktok"
    t.string "post_url"
    t.string "post_id"
    t.datetime "posted_at"
    t.integer "views"
    t.integer "likes"
    t.integer "comments_count"
    t.integer "shares"
    t.text "review_notes"
    t.datetime "hooked_at"
    t.datetime "scripted_at"
    t.datetime "asset_at"
    t.datetime "assembled_at"
    t.datetime "reviewed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "reference_video_url"
    t.integer "reference_video_start"
    t.integer "reference_video_end"
    t.string "rival_team_slug"
    t.text "captions"
    t.jsonb "hashtags", default: []
    t.jsonb "music_suggestions", default: []
    t.string "workflow", default: "video", null: false
    t.string "team_slug"
    t.jsonb "caption_variants", default: []
    t.index ["rival_team_slug"], name: "index_contents_on_rival_team_slug"
    t.index ["slug"], name: "index_contents_on_slug", unique: true
    t.index ["source_news_slug"], name: "index_contents_on_source_news_slug"
    t.index ["stage", "position"], name: "index_contents_on_stage_and_position"
    t.index ["stage"], name: "index_contents_on_stage"
    t.index ["team_slug"], name: "index_contents_on_team_slug"
    t.index ["workflow"], name: "index_contents_on_workflow"
  end

  create_table "contracts", force: :cascade do |t|
    t.string "person_slug", null: false
    t.string "team_slug", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.date "expires_at"
    t.bigint "annual_value_cents"
    t.string "position"
    t.string "contract_type", default: "active"
    t.index ["contract_type"], name: "index_contracts_on_contract_type"
    t.index ["expires_at"], name: "index_contracts_on_expires_at"
    t.index ["person_slug", "team_slug"], name: "index_contracts_on_person_slug_and_team_slug", unique: true
    t.index ["person_slug"], name: "index_contracts_on_person_slug"
    t.index ["slug"], name: "index_contracts_on_slug", unique: true
    t.index ["team_slug"], name: "index_contracts_on_team_slug"
  end

  create_table "depth_chart_entries", force: :cascade do |t|
    t.string "depth_chart_slug", null: false
    t.string "person_slug", null: false
    t.string "position", null: false
    t.string "side", null: false
    t.integer "depth", null: false
    t.boolean "locked", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "formation_slot"
    t.index ["depth_chart_slug", "person_slug", "position"], name: "idx_dce_unique", unique: true
    t.index ["depth_chart_slug", "position", "depth"], name: "idx_on_depth_chart_slug_position_depth_8e80d39ff6"
    t.index ["depth_chart_slug"], name: "index_depth_chart_entries_on_depth_chart_slug"
    t.index ["formation_slot"], name: "index_depth_chart_entries_on_formation_slot"
  end

  create_table "depth_charts", force: :cascade do |t|
    t.string "team_slug", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_depth_charts_on_slug", unique: true
    t.index ["team_slug"], name: "index_depth_charts_on_team_slug", unique: true
  end

  create_table "durable_nonces", force: :cascade do |t|
    t.string "slug", null: false
    t.string "pubkey", null: false
    t.string "authority", null: false
    t.string "cluster", default: "devnet", null: false
    t.string "status", default: "active", null: false
    t.string "label"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster", "status"], name: "index_durable_nonces_on_cluster_and_status"
    t.index ["pubkey"], name: "index_durable_nonces_on_pubkey", unique: true
    t.index ["slug"], name: "index_durable_nonces_on_slug", unique: true
  end

  create_table "error_logs", force: :cascade do |t|
    t.text "message"
    t.text "inspect"
    t.text "backtrace"
    t.string "target_type"
    t.bigint "target_id"
    t.string "parent_type"
    t.bigint "parent_id"
    t.string "target_name"
    t.string "parent_name"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_type", "parent_id"], name: "index_error_logs_on_parent_type_and_parent_id"
    t.index ["slug"], name: "index_error_logs_on_slug", unique: true
    t.index ["target_type", "target_id"], name: "index_error_logs_on_target_type_and_target_id"
  end

  create_table "games", force: :cascade do |t|
    t.string "slug", null: false
    t.string "slate_slug", null: false
    t.string "home_team_slug", null: false
    t.string "away_team_slug", null: false
    t.datetime "kickoff_at"
    t.string "venue"
    t.string "status", default: "scheduled"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "location"
    t.index ["away_team_slug"], name: "index_games_on_away_team_slug"
    t.index ["home_team_slug"], name: "index_games_on_home_team_slug"
    t.index ["slate_slug"], name: "index_games_on_slate_slug"
    t.index ["slug"], name: "index_games_on_slug", unique: true
  end

  create_table "github_builder_commit_range_caches", force: :cascade do |t|
    t.bigint "tracked_github_builder_id", null: false
    t.bigint "github_commit_range_id", null: false
    t.string "github_login", null: false
    t.string "cohort", null: false
    t.integer "commits_count", default: 0, null: false
    t.integer "non_merge_commits_count", default: 0, null: false
    t.integer "bot_adjusted_commits_count", default: 0, null: false
    t.integer "active_repos_count", default: 0, null: false
    t.decimal "trailing_90d_avg_weekly_commits", precision: 12, scale: 4
    t.decimal "builder_multiple", precision: 12, scale: 4
    t.decimal "bot_adjusted_builder_multiple", precision: 12, scale: 4
    t.jsonb "commit_shas", default: [], null: false
    t.datetime "cached_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "cache_run_key", default: "legacy", null: false
    t.index ["cache_run_key", "tracked_github_builder_id", "github_commit_range_id"], name: "idx_builder_range_caches_on_run_key_builder_range"
    t.index ["cache_run_key"], name: "idx_builder_range_caches_on_cache_run_key"
    t.index ["github_commit_range_id", "cohort"], name: "idx_builder_range_caches_on_range_cohort"
    t.index ["github_commit_range_id"], name: "index_builder_range_caches_on_range_id"
    t.index ["github_login", "github_commit_range_id"], name: "idx_builder_range_caches_on_login_range"
    t.index ["tracked_github_builder_id", "github_commit_range_id"], name: "idx_builder_range_caches_on_builder_range", unique: true
    t.index ["tracked_github_builder_id"], name: "index_builder_range_caches_on_builder_id"
  end

  create_table "github_builder_index_weeks", force: :cascade do |t|
    t.date "week_start_date", null: false
    t.decimal "ai_builder_multiple", precision: 12, scale: 4
    t.decimal "control_builder_multiple", precision: 12, scale: 4
    t.decimal "difficulty_adjusted_ai_builder_multiple", precision: 12, scale: 4
    t.integer "ai_builder_count", default: 0, null: false
    t.integer "control_builder_count", default: 0, null: false
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["week_start_date"], name: "index_github_builder_index_weeks_on_week_start_date", unique: true
  end

  create_table "github_builder_weekly_metrics", force: :cascade do |t|
    t.string "github_login", null: false
    t.string "cohort", null: false
    t.date "week_start_date", null: false
    t.integer "commits_count", default: 0, null: false
    t.integer "non_merge_commits_count", default: 0, null: false
    t.integer "bot_adjusted_commits_count", default: 0, null: false
    t.integer "active_repos_count", default: 0, null: false
    t.decimal "trailing_90d_avg_weekly_commits", precision: 12, scale: 4
    t.decimal "builder_multiple", precision: 12, scale: 4
    t.decimal "bot_adjusted_builder_multiple", precision: 12, scale: 4
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_login", "week_start_date"], name: "index_builder_weekly_metrics_on_login_week", unique: true
    t.index ["week_start_date", "cohort"], name: "idx_on_week_start_date_cohort_0406de51f1"
  end

  create_table "github_commit_observations", force: :cascade do |t|
    t.string "github_login", null: false
    t.string "repo_full_name", null: false
    t.string "sha", null: false
    t.string "author_login"
    t.string "committer_login"
    t.datetime "authored_at"
    t.datetime "committed_at"
    t.text "message"
    t.string "html_url"
    t.boolean "is_merge", default: false, null: false
    t.boolean "is_bot", default: false, null: false
    t.string "source_strategy", null: false
    t.jsonb "raw_payload", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["github_login", "authored_at"], name: "idx_on_github_login_authored_at_00ca1cd94c"
    t.index ["github_login", "committed_at"], name: "idx_on_github_login_committed_at_810ec88674"
    t.index ["repo_full_name", "sha", "github_login"], name: "index_commit_observations_on_repo_sha_login", unique: true
    t.index ["source_strategy"], name: "index_github_commit_observations_on_source_strategy"
  end

  create_table "github_commit_ranges", force: :cascade do |t|
    t.date "week_start_date", null: false
    t.date "week_end_date", null: false
    t.string "label", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["week_end_date"], name: "index_github_commit_ranges_on_week_end_date"
    t.index ["week_start_date"], name: "index_github_commit_ranges_on_week_start_date", unique: true
  end

  create_table "image_caches", force: :cascade do |t|
    t.string "owner_type", null: false
    t.bigint "owner_id", null: false
    t.string "purpose", null: false
    t.string "variant", null: false
    t.string "s3_key", null: false
    t.string "source_url"
    t.integer "bytes"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_type", "owner_id", "purpose", "variant"], name: "idx_image_caches_owner_purpose_variant", unique: true
    t.index ["owner_type", "owner_id"], name: "index_image_caches_on_owner"
    t.index ["s3_key"], name: "index_image_caches_on_s3_key", unique: true
  end

  create_table "news", force: :cascade do |t|
    t.string "stage", default: "new", null: false
    t.integer "position"
    t.string "slug", null: false
    t.string "title", null: false
    t.string "url"
    t.string "x_post_id"
    t.string "x_post_url"
    t.string "author"
    t.datetime "published_at"
    t.string "primary_person"
    t.string "primary_team"
    t.string "primary_action"
    t.string "secondary_person"
    t.string "secondary_team"
    t.string "article_image_url"
    t.string "primary_person_slug"
    t.string "primary_team_slug"
    t.string "secondary_person_slug"
    t.string "secondary_team_slug"
    t.string "title_short"
    t.text "summary"
    t.string "feeling"
    t.string "feeling_emoji"
    t.string "what_happened"
    t.text "opinion"
    t.datetime "reviewed_at"
    t.datetime "processed_at"
    t.datetime "refined_at"
    t.datetime "concluded_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "callback_ideas", default: []
    t.index ["primary_person_slug"], name: "index_news_on_primary_person_slug"
    t.index ["primary_team_slug"], name: "index_news_on_primary_team_slug"
    t.index ["secondary_person_slug"], name: "index_news_on_secondary_person_slug"
    t.index ["secondary_team_slug"], name: "index_news_on_secondary_team_slug"
    t.index ["slug"], name: "index_news_on_slug", unique: true
    t.index ["stage", "position"], name: "index_news_on_stage_and_position"
    t.index ["stage"], name: "index_news_on_stage"
  end

  create_table "people", force: :cascade do |t|
    t.string "first_name", null: false
    t.string "last_name", null: false
    t.string "slug", null: false
    t.boolean "athlete", default: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "aliases", default: []
    t.boolean "coach", default: false
    t.string "location"
    t.string "avatar_url"
    t.string "website_url"
    t.string "email"
    t.string "linkedin_url"
    t.string "x_url"
    t.string "instagram_url"
    t.string "facebook_url"
    t.index ["email"], name: "index_people_on_email"
    t.index ["last_name", "first_name"], name: "index_people_on_last_name_and_first_name"
    t.index ["slug"], name: "index_people_on_slug", unique: true
  end

  create_table "pff_stats", force: :cascade do |t|
    t.string "athlete_slug", null: false
    t.string "season_slug", null: false
    t.string "stat_type", null: false
    t.string "team_slug"
    t.integer "pff_player_id"
    t.integer "games_played"
    t.jsonb "data", default: {}, null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["athlete_slug", "season_slug", "stat_type"], name: "idx_pff_stats_unique", unique: true
    t.index ["data"], name: "index_pff_stats_on_data", using: :gin
    t.index ["pff_player_id"], name: "index_pff_stats_on_pff_player_id"
    t.index ["slug"], name: "index_pff_stats_on_slug", unique: true
    t.index ["stat_type"], name: "index_pff_stats_on_stat_type"
  end

  create_table "pff_team_stats", force: :cascade do |t|
    t.string "team_slug", null: false
    t.string "season_slug", null: false
    t.string "stat_type", null: false
    t.jsonb "data", default: {}, null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["data"], name: "index_pff_team_stats_on_data", using: :gin
    t.index ["slug"], name: "index_pff_team_stats_on_slug", unique: true
    t.index ["team_slug", "season_slug", "stat_type"], name: "idx_pff_team_stats_unique", unique: true
  end

  create_table "roster_spots", force: :cascade do |t|
    t.bigint "roster_id", null: false
    t.string "person_slug", null: false
    t.string "position", null: false
    t.string "side", null: false
    t.integer "depth", default: 1, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["person_slug"], name: "index_roster_spots_on_person_slug"
    t.index ["roster_id", "position", "depth"], name: "index_roster_spots_on_roster_id_and_position_and_depth", unique: true
    t.index ["roster_id"], name: "index_roster_spots_on_roster_id"
  end

  create_table "rosters", force: :cascade do |t|
    t.string "team_slug", null: false
    t.string "slate_slug", null: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slate_slug"], name: "index_rosters_on_slate_slug"
    t.index ["slug"], name: "index_rosters_on_slug", unique: true
    t.index ["team_slug", "slate_slug"], name: "index_rosters_on_team_slug_and_slate_slug", unique: true
    t.index ["team_slug"], name: "index_rosters_on_team_slug"
  end

  create_table "seasons", force: :cascade do |t|
    t.integer "year", null: false
    t.string "sport", null: false
    t.string "league", null: false
    t.string "name", null: false
    t.boolean "active", default: false
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["league", "active"], name: "index_seasons_on_league_and_active"
    t.index ["slug"], name: "index_seasons_on_slug", unique: true
    t.index ["year", "league"], name: "index_seasons_on_year_and_league", unique: true
  end

  create_table "signing_requests", force: :cascade do |t|
    t.string "slug", null: false
    t.string "title"
    t.string "program", default: "turf_vault", null: false
    t.string "program_id", null: false
    t.string "cluster", default: "devnet", null: false
    t.string "instruction_name", null: false
    t.jsonb "args", default: {}, null: false
    t.jsonb "accounts", default: {}, null: false
    t.string "coordination", default: "multi", null: false
    t.integer "threshold", default: 1, null: false
    t.string "expected_signers", default: [], null: false, array: true
    t.jsonb "collected_signatures", default: {}, null: false
    t.string "multisig_pubkey"
    t.string "fee_payer"
    t.string "durable_nonce_pubkey"
    t.string "nonce_authority"
    t.text "unsigned_message_base64"
    t.string "status", default: "awaiting_signatures", null: false
    t.string "tx_signature"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_signing_requests_on_slug", unique: true
    t.index ["status"], name: "index_signing_requests_on_status"
  end

  create_table "skill_assignments", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.string "skill_slug", null: false
    t.integer "proficiency", default: 100
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "skill_slug"], name: "index_skill_assignments_on_agent_slug_and_skill_slug", unique: true
    t.index ["agent_slug"], name: "index_skill_assignments_on_agent_slug"
    t.index ["skill_slug"], name: "index_skill_assignments_on_skill_slug"
  end

  create_table "skills", force: :cascade do |t|
    t.string "name", null: false
    t.string "slug", null: false
    t.string "category"
    t.text "description"
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_skills_on_category"
    t.index ["slug"], name: "index_skills_on_slug", unique: true
  end

  create_table "slates", force: :cascade do |t|
    t.string "season_slug", null: false
    t.integer "sequence", null: false
    t.string "label", null: false
    t.string "slate_type", null: false
    t.date "starts_at"
    t.date "ends_at"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["season_slug", "sequence"], name: "index_slates_on_season_slug_and_sequence", unique: true
    t.index ["season_slug"], name: "index_slates_on_season_slug"
    t.index ["slug"], name: "index_slates_on_slug", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "studio_email_deliveries", force: :cascade do |t|
    t.string "email_key", null: false
    t.string "to"
    t.string "mailer", null: false
    t.string "action", null: false
    t.jsonb "args", default: [], null: false
    t.jsonb "kwargs", default: {}, null: false
    t.boolean "sent", default: false, null: false
    t.datetime "sent_at"
    t.text "error"
    t.bigint "user_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_studio_email_deliveries_on_created_at"
    t.index ["email_key"], name: "index_studio_email_deliveries_on_email_key"
    t.index ["sent"], name: "index_studio_email_deliveries_on_sent"
    t.index ["user_id"], name: "index_studio_email_deliveries_on_user_id"
  end

  create_table "tasks", force: :cascade do |t|
    t.string "title", null: false
    t.string "slug", null: false
    t.text "description"
    t.string "stage", default: "new"
    t.integer "priority", default: 0
    t.string "agent_slug"
    t.jsonb "required_skills", default: []
    t.jsonb "result", default: {}
    t.jsonb "metadata", default: {}
    t.text "error_message"
    t.integer "position"
    t.datetime "queued_at"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "failed_at"
    t.datetime "archived_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "pm_size"
    t.string "po_size"
    t.string "dev_size"
    t.string "actual_size"
    t.datetime "sizes_revealed_at"
    t.boolean "requires_migration", default: false, null: false
    t.index ["agent_slug"], name: "index_tasks_on_agent_slug"
    t.index ["priority"], name: "index_tasks_on_priority"
    t.index ["requires_migration"], name: "index_tasks_on_requires_migration"
    t.index ["slug"], name: "index_tasks_on_slug", unique: true
    t.index ["stage", "created_at"], name: "index_tasks_on_stage_and_created_at"
    t.index ["stage", "position"], name: "index_tasks_on_stage_and_position"
    t.index ["stage"], name: "index_tasks_on_stage"
  end

  create_table "team_rankings", force: :cascade do |t|
    t.string "team_slug", null: false
    t.string "season_slug", null: false
    t.string "rank_type", null: false
    t.integer "rank", null: false
    t.decimal "score", precision: 10, scale: 2
    t.integer "week"
    t.string "slug", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["season_slug"], name: "index_team_rankings_on_season_slug"
    t.index ["slug"], name: "index_team_rankings_on_slug", unique: true
    t.index ["team_slug", "rank_type", "season_slug", "week"], name: "idx_team_rankings_unique_with_week", unique: true, where: "(week IS NOT NULL)"
    t.index ["team_slug", "rank_type", "season_slug"], name: "idx_team_rankings_unique_preseason", unique: true, where: "(week IS NULL)"
    t.index ["team_slug"], name: "index_team_rankings_on_team_slug"
  end

  create_table "teams", force: :cascade do |t|
    t.string "name", null: false
    t.string "short_name"
    t.string "slug", null: false
    t.string "location"
    t.string "emoji"
    t.string "color_primary"
    t.string "color_secondary"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "color_text_light", default: false
    t.string "sport"
    t.string "league"
    t.string "conference"
    t.string "division"
    t.jsonb "rivals", default: []
    t.string "team_website"
    t.string "coaches_url"
    t.string "hashtag"
    t.string "hashtag2"
    t.string "x_handle"
    t.string "home_arena_slug"
    t.string "mascot"
    t.string "logo_url"
    t.string "logo_path"
    t.string "logo_source"
    t.index ["home_arena_slug"], name: "index_teams_on_home_arena_slug"
    t.index ["slug"], name: "index_teams_on_slug", unique: true
    t.index ["sport", "league"], name: "index_teams_on_sport_and_league"
  end

  create_table "theme_settings", force: :cascade do |t|
    t.string "app_name", null: false
    t.string "primary"
    t.string "accent1"
    t.string "accent2"
    t.string "warning"
    t.string "danger"
    t.string "dark"
    t.string "light"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["app_name"], name: "index_theme_settings_on_app_name", unique: true
  end

  create_table "tracked_github_builder_repos", force: :cascade do |t|
    t.bigint "tracked_github_builder_id", null: false
    t.string "repo_full_name", null: false
    t.string "repo_category"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["repo_full_name"], name: "index_tracked_github_builder_repos_on_repo_full_name"
    t.index ["tracked_github_builder_id", "repo_full_name"], name: "index_builder_repos_on_builder_and_repo", unique: true
    t.index ["tracked_github_builder_id"], name: "index_builder_repos_on_builder_id"
  end

  create_table "tracked_github_builders", force: :cascade do |t|
    t.string "github_login", null: false
    t.string "display_name"
    t.string "cohort", null: false
    t.string "category"
    t.text "notes"
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["cohort", "active"], name: "index_tracked_github_builders_on_cohort_and_active"
    t.index ["github_login"], name: "index_tracked_github_builders_on_github_login", unique: true
  end

  create_table "usages", force: :cascade do |t|
    t.string "agent_slug"
    t.date "period_date", null: false
    t.string "period_type", null: false
    t.string "model"
    t.integer "tokens_in", default: 0
    t.integer "tokens_out", default: 0
    t.integer "api_calls", default: 0
    t.decimal "cost", precision: 10, scale: 4, default: "0.0"
    t.integer "tasks_completed", default: 0
    t.integer "tasks_failed", default: 0
    t.jsonb "metadata", default: {}
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "period_date", "period_type", "model"], name: "idx_usages_unique", unique: true
    t.index ["agent_slug"], name: "index_usages_on_agent_slug"
    t.index ["slug"], name: "index_usages_on_slug", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.string "name"
    t.string "email"
    t.string "password_digest"
    t.string "provider"
    t.string "uid"
    t.string "role", default: "viewer"
    t.string "slug"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "session_token"
    t.string "solana_address"
    t.datetime "email_verified_at"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["slug"], name: "index_users_on_slug", unique: true
    t.index ["solana_address"], name: "index_users_on_solana_address", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "broadcast_deliveries", "broadcasts"
  add_foreign_key "broadcast_deliveries", "contacts"
  add_foreign_key "builders", "people"
  add_foreign_key "github_builder_commit_range_caches", "github_commit_ranges"
  add_foreign_key "github_builder_commit_range_caches", "tracked_github_builders"
  add_foreign_key "roster_spots", "rosters"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "studio_email_deliveries", "users"
  add_foreign_key "tracked_github_builder_repos", "tracked_github_builders"
end
