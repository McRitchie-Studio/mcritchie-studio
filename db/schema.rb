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

ActiveRecord::Schema[8.1].define(version: 2026_08_13_223520) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "action_grades", force: :cascade do |t|
    t.bigint "agent_action_id"
    t.bigint "agent_activity_id"
    t.boolean "banked", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "discarded", default: false, null: false
    t.string "disposition", null: false
    t.string "grader", null: false
    t.text "long_form"
    t.string "slug", null: false
    t.string "source_activity_slug"
    t.datetime "updated_at", null: false
    t.index ["agent_action_id", "grader"], name: "index_action_grades_on_agent_action_id_and_grader", unique: true
    t.index ["agent_action_id"], name: "index_action_grades_on_agent_action_id"
    t.index ["agent_activity_id", "grader"], name: "index_action_grades_on_agent_activity_id_and_grader", unique: true, where: "(agent_activity_id IS NOT NULL)"
    t.index ["agent_activity_id"], name: "index_action_grades_on_agent_activity_id"
    t.index ["banked"], name: "index_action_grades_on_banked"
    t.index ["source_activity_slug"], name: "index_action_grades_on_source_activity_slug", unique: true, where: "(source_activity_slug IS NOT NULL)"
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "activities", force: :cascade do |t|
    t.string "activity_type"
    t.string "agent_slug"
    t.datetime "created_at", null: false
    t.text "description"
    t.jsonb "metadata", default: {}
    t.string "slug"
    t.string "task_slug"
    t.datetime "updated_at", null: false
    t.index ["activity_type", "created_at"], name: "index_activities_on_activity_type_and_created_at"
    t.index ["activity_type"], name: "index_activities_on_activity_type"
    t.index ["agent_slug"], name: "index_activities_on_agent_slug"
    t.index ["slug"], name: "index_activities_on_slug", unique: true
    t.index ["task_slug"], name: "index_activities_on_task_slug"
  end

  create_table "agent_actions", force: :cascade do |t|
    t.string "actor", default: "agent", null: false
    t.bigint "agent_activity_id"
    t.integer "cache_read_tokens", default: 0
    t.decimal "cost", precision: 10, scale: 4, default: "0.0"
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.string "event_slug"
    t.boolean "feedback_anchor", default: false, null: false
    t.string "idempotency_key"
    t.text "input"
    t.text "key_method"
    t.string "key_method_lang"
    t.string "kind", null: false
    t.string "mascot"
    t.string "model"
    t.datetime "occurred_at", null: false
    t.string "outcome", default: "pending", null: false
    t.text "output"
    t.string "result_slug"
    t.integer "seq", default: 0, null: false
    t.string "session_id", null: false
    t.string "source_turn_uuid"
    t.string "stage"
    t.string "summary"
    t.string "task_slug"
    t.integer "tokens_in", default: 0, null: false
    t.integer "tokens_out", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_activity_id"], name: "index_agent_actions_on_agent_activity_id"
    t.index ["feedback_anchor"], name: "index_agent_actions_on_feedback_anchor"
    t.index ["idempotency_key"], name: "index_agent_actions_on_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["occurred_at"], name: "index_agent_actions_on_occurred_at"
    t.index ["session_id", "seq"], name: "index_agent_actions_on_session_id_and_seq"
    t.index ["source_turn_uuid"], name: "index_agent_actions_on_source_turn_uuid"
    t.index ["task_slug", "seq"], name: "index_agent_actions_on_task_slug_and_seq"
  end

  create_table "agent_activities", force: :cascade do |t|
    t.string "agent"
    t.integer "cache_creation_tokens"
    t.integer "cache_read_tokens"
    t.string "category", null: false
    t.datetime "closed_at"
    t.decimal "cost", precision: 10, scale: 4
    t.datetime "created_at", null: false
    t.text "key_method"
    t.string "key_method_lang"
    t.string "mascot"
    t.string "model"
    t.datetime "opened_at", null: false
    t.string "outcome_slug"
    t.bigint "parent_span_id"
    t.string "reason_slug", null: false
    t.integer "seq", default: 0, null: false
    t.string "session_id", null: false
    t.string "stage"
    t.string "supervisor_agent"
    t.string "task_slug"
    t.integer "tokens_in"
    t.integer "tokens_out"
    t.string "transcript_path"
    t.string "turn_uuid"
    t.datetime "updated_at", null: false
    t.index ["model", "opened_at"], name: "index_agent_activities_on_model_and_opened_at"
    t.index ["opened_at"], name: "index_agent_activities_on_opened_at"
    t.index ["parent_span_id"], name: "index_agent_activities_on_parent_span_id"
    t.index ["session_id", "closed_at"], name: "index_agent_activities_on_session_id_and_closed_at"
    t.index ["session_id", "seq"], name: "index_agent_activities_on_session_id_and_seq"
    t.index ["session_id", "transcript_path"], name: "index_agent_activities_on_session_and_transcript"
    t.index ["session_id", "turn_uuid"], name: "index_agent_activities_on_session_and_turn", unique: true, where: "(turn_uuid IS NOT NULL)"
    t.index ["task_slug", "seq"], name: "index_agent_activities_on_task_slug_and_seq"
  end

  create_table "agents", force: :cascade do |t|
    t.string "agent_type"
    t.string "avatar"
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.text "description"
    t.datetime "last_active_at"
    t.jsonb "metadata", default: {}
    t.string "name", null: false
    t.integer "position", default: 0
    t.string "slug", null: false
    t.string "status", default: "active"
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_agents_on_slug", unique: true
    t.index ["status"], name: "index_agents_on_status"
  end

  create_table "apps", force: :cascade do |t|
    t.string "color"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "emoji"
    t.string "name", null: false
    t.integer "position", default: 0
    t.string "slug", null: false
    t.string "status", default: "active"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_apps_on_slug", unique: true
  end

  create_table "arenas", force: :cascade do |t|
    t.string "address"
    t.string "city"
    t.string "country"
    t.datetime "created_at", null: false
    t.string "location"
    t.string "name", null: false
    t.string "slug", null: false
    t.string "state"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_arenas_on_slug", unique: true
  end

  create_table "athlete_grades", force: :cascade do |t|
    t.string "athlete_slug", null: false
    t.float "coverage_grade_pff"
    t.datetime "created_at", null: false
    t.float "defense_grade_pff"
    t.float "fg_grade_pff"
    t.integer "games_played"
    t.jsonb "grade_ranges"
    t.float "kickoff_grade_pff"
    t.float "offense_grade_pff"
    t.float "overall_grade_pff"
    t.float "pass_block_grade_pff"
    t.float "pass_grade_pff"
    t.float "pass_route_grade_pff"
    t.float "pass_rush_grade_pff"
    t.integer "position_pass_grade"
    t.integer "position_pass_rank"
    t.integer "position_run_grade"
    t.integer "position_run_rank"
    t.float "punting_grade_pff"
    t.float "return_grade_pff"
    t.float "run_block_grade_pff"
    t.float "run_grade_pff"
    t.float "rush_defense_grade_pff"
    t.string "season_slug", null: false
    t.string "slug", null: false
    t.integer "snaps"
    t.datetime "updated_at", null: false
    t.index ["athlete_slug", "season_slug"], name: "index_athlete_grades_on_athlete_slug_and_season_slug", unique: true
    t.index ["athlete_slug"], name: "index_athlete_grades_on_athlete_slug"
    t.index ["position_pass_rank"], name: "index_athlete_grades_on_position_pass_rank"
    t.index ["position_run_rank"], name: "index_athlete_grades_on_position_run_rank"
    t.index ["season_slug"], name: "index_athlete_grades_on_season_slug"
    t.index ["slug"], name: "index_athlete_grades_on_slug", unique: true
  end

  create_table "athletes", force: :cascade do |t|
    t.string "build"
    t.datetime "created_at", null: false
    t.integer "draft_pick"
    t.integer "draft_round"
    t.integer "draft_year"
    t.string "espn_headshot_url"
    t.string "espn_id"
    t.string "gsis_id"
    t.string "hair_description"
    t.integer "height_inches"
    t.string "nflverse_id"
    t.string "otc_id"
    t.string "person_slug", null: false
    t.integer "pff_id"
    t.string "pfr_id"
    t.string "position"
    t.string "skin_tone"
    t.string "sleeper_id"
    t.string "slug", null: false
    t.string "sport", null: false
    t.string "team_slug"
    t.datetime "updated_at", null: false
    t.integer "weight_lbs"
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
    t.integer "click_count", default: 0, null: false
    t.datetime "clicked_at"
    t.bigint "contact_id", null: false
    t.datetime "created_at", null: false
    t.integer "open_count", default: 0, null: false
    t.datetime "opened_at"
    t.datetime "sent_at"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["broadcast_id", "contact_id"], name: "index_broadcast_deliveries_on_broadcast_id_and_contact_id", unique: true
    t.index ["broadcast_id"], name: "index_broadcast_deliveries_on_broadcast_id"
    t.index ["contact_id"], name: "index_broadcast_deliveries_on_contact_id"
    t.index ["token"], name: "index_broadcast_deliveries_on_token", unique: true
  end

  create_table "broadcasts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "header"
    t.string "hero_url"
    t.string "preview_text"
    t.datetime "sent_at"
    t.string "slug", null: false
    t.string "status", default: "draft", null: false
    t.string "subheader"
    t.string "subject", default: "", null: false
    t.string "survivor_url"
    t.string "target_list"
    t.string "template_key", null: false
    t.string "turf_totals_url"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_broadcasts_on_slug", unique: true
    t.index ["status"], name: "index_broadcasts_on_status"
  end

  create_table "builders", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "github_avatar_url"
    t.text "github_bio"
    t.string "github_blog"
    t.string "github_company"
    t.string "github_email"
    t.string "github_login", null: false
    t.string "github_name"
    t.string "github_profile_url"
    t.string "github_twitter_username"
    t.boolean "included_in_roster", default: true, null: false
    t.bigint "person_id", null: false
    t.string "primary_language"
    t.jsonb "raw_profile", default: {}, null: false
    t.integer "source_contributions"
    t.string "source_dataset"
    t.integer "source_rank"
    t.string "source_url"
    t.datetime "updated_at", null: false
    t.index ["active", "included_in_roster"], name: "index_builders_on_active_and_included_in_roster"
    t.index ["github_login"], name: "index_builders_on_github_login", unique: true
    t.index ["person_id"], name: "index_builders_on_person_id"
    t.index ["primary_language", "active"], name: "index_builders_on_primary_language_and_active"
    t.index ["source_dataset"], name: "index_builders_on_source_dataset"
  end

  create_table "ci_check_jobs", force: :cascade do |t|
    t.datetime "completed_at"
    t.string "conclusion"
    t.datetime "created_at", null: false
    t.string "head_branch"
    t.string "head_sha", null: false
    t.bigint "job_id", null: false
    t.string "name"
    t.string "repo", null: false
    t.bigint "run_id"
    t.datetime "started_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.string "workflow_name"
    t.index ["job_id"], name: "index_ci_check_jobs_on_job_id", unique: true
    t.index ["repo", "head_sha"], name: "index_ci_check_jobs_on_repo_and_head_sha"
  end

  create_table "coach_rankings", force: :cascade do |t|
    t.string "coach_slug", null: false
    t.datetime "created_at", null: false
    t.integer "rank", null: false
    t.string "rank_type", null: false
    t.string "season_slug", null: false
    t.string "slug", null: false
    t.string "tier"
    t.datetime "updated_at", null: false
    t.index ["coach_slug", "rank_type", "season_slug"], name: "index_coach_rankings_unique_type_season", unique: true
    t.index ["coach_slug"], name: "index_coach_rankings_on_coach_slug"
    t.index ["season_slug"], name: "index_coach_rankings_on_season_slug"
    t.index ["slug"], name: "index_coach_rankings_on_slug", unique: true
  end

  create_table "coaches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "espn_headshot_url"
    t.string "espn_id"
    t.string "lean"
    t.string "person_slug", null: false
    t.string "role", null: false
    t.string "slug", null: false
    t.string "sport", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["espn_id"], name: "index_coaches_on_espn_id"
    t.index ["person_slug", "team_slug", "role"], name: "index_coaches_unique_role", unique: true
    t.index ["person_slug"], name: "index_coaches_on_person_slug"
    t.index ["slug"], name: "index_coaches_on_slug", unique: true
    t.index ["sport"], name: "index_coaches_on_sport"
    t.index ["team_slug"], name: "index_coaches_on_team_slug"
  end

  create_table "contacts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "first_name"
    t.string "last_name"
    t.string "source"
    t.boolean "subscribed", default: true, null: false
    t.string "tags", default: [], null: false, array: true
    t.string "unsubscribe_token", null: false
    t.datetime "unsubscribed_at"
    t.datetime "updated_at", null: false
    t.index "lower((email)::text)", name: "index_contacts_on_lower_email", unique: true
    t.index ["tags"], name: "index_contacts_on_tags", using: :gin
    t.index ["unsubscribe_token"], name: "index_contacts_on_unsubscribe_token", unique: true
  end

  create_table "contents", force: :cascade do |t|
    t.datetime "assembled_at"
    t.datetime "asset_at"
    t.jsonb "caption_variants", default: []
    t.text "captions"
    t.integer "comments_count"
    t.string "content_type", default: "tiktok_video"
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "duration_seconds"
    t.string "final_video_url"
    t.jsonb "hashtags", default: []
    t.jsonb "hook_ideas", default: []
    t.string "hook_image_url"
    t.datetime "hooked_at"
    t.integer "likes"
    t.boolean "logo_overlay", default: true
    t.jsonb "music_suggestions", default: []
    t.string "music_track"
    t.string "platform", default: "tiktok"
    t.integer "position"
    t.string "post_id"
    t.string "post_url"
    t.datetime "posted_at"
    t.integer "reference_video_end"
    t.integer "reference_video_start"
    t.string "reference_video_url"
    t.text "review_notes"
    t.datetime "reviewed_at"
    t.string "rival_team_slug"
    t.jsonb "scene_assets", default: []
    t.jsonb "scenes", default: []
    t.text "script_text"
    t.datetime "scripted_at"
    t.integer "selected_hook_index"
    t.integer "shares"
    t.string "slug", null: false
    t.string "source_news_slug"
    t.string "source_type"
    t.string "stage", default: "idea", null: false
    t.string "team_slug"
    t.jsonb "text_overlays", default: []
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.integer "views"
    t.string "workflow", default: "video", null: false
    t.index ["rival_team_slug"], name: "index_contents_on_rival_team_slug"
    t.index ["slug"], name: "index_contents_on_slug", unique: true
    t.index ["source_news_slug"], name: "index_contents_on_source_news_slug"
    t.index ["stage", "position"], name: "index_contents_on_stage_and_position"
    t.index ["stage"], name: "index_contents_on_stage"
    t.index ["team_slug"], name: "index_contents_on_team_slug"
    t.index ["workflow"], name: "index_contents_on_workflow"
  end

  create_table "contracts", force: :cascade do |t|
    t.bigint "annual_value_cents"
    t.string "contract_type", default: "active"
    t.datetime "created_at", null: false
    t.date "expires_at"
    t.string "person_slug", null: false
    t.string "position"
    t.string "slug", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["contract_type"], name: "index_contracts_on_contract_type"
    t.index ["expires_at"], name: "index_contracts_on_expires_at"
    t.index ["person_slug", "team_slug"], name: "index_contracts_on_person_slug_and_team_slug", unique: true
    t.index ["person_slug"], name: "index_contracts_on_person_slug"
    t.index ["slug"], name: "index_contracts_on_slug", unique: true
    t.index ["team_slug"], name: "index_contracts_on_team_slug"
  end

  create_table "depth_chart_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "depth", null: false
    t.string "depth_chart_slug", null: false
    t.string "formation_slot"
    t.boolean "locked", default: false, null: false
    t.string "person_slug", null: false
    t.string "position", null: false
    t.string "side", null: false
    t.datetime "updated_at", null: false
    t.index ["depth_chart_slug", "person_slug", "position"], name: "idx_dce_unique", unique: true
    t.index ["depth_chart_slug", "position", "depth"], name: "idx_on_depth_chart_slug_position_depth_8e80d39ff6"
    t.index ["depth_chart_slug"], name: "index_depth_chart_entries_on_depth_chart_slug"
    t.index ["formation_slot"], name: "index_depth_chart_entries_on_formation_slot"
  end

  create_table "depth_charts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "slug", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_depth_charts_on_slug", unique: true
    t.index ["team_slug"], name: "index_depth_charts_on_team_slug", unique: true
  end

  create_table "devops_shifts", force: :cascade do |t|
    t.datetime "acquired_at"
    t.datetime "claim_expires_at"
    t.string "claim_nonce"
    t.string "claimed_session"
    t.datetime "created_at", null: false
    t.string "holder_label"
    t.string "lane", null: false
    t.datetime "updated_at", null: false
    t.index ["lane"], name: "index_devops_shifts_on_lane", unique: true
  end

  create_table "durable_nonces", force: :cascade do |t|
    t.string "authority", null: false
    t.string "cluster", default: "devnet", null: false
    t.datetime "created_at", null: false
    t.string "label"
    t.string "pubkey", null: false
    t.string "slug", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["cluster", "status"], name: "index_durable_nonces_on_cluster_and_status"
    t.index ["pubkey"], name: "index_durable_nonces_on_pubkey", unique: true
    t.index ["slug"], name: "index_durable_nonces_on_slug", unique: true
  end

  create_table "error_logs", force: :cascade do |t|
    t.text "backtrace"
    t.datetime "created_at", null: false
    t.text "inspect"
    t.text "message"
    t.bigint "parent_id"
    t.string "parent_name"
    t.string "parent_type"
    t.string "slug"
    t.bigint "target_id"
    t.string "target_name"
    t.string "target_type"
    t.datetime "updated_at", null: false
    t.index ["parent_type", "parent_id"], name: "index_error_logs_on_parent_type_and_parent_id"
    t.index ["slug"], name: "index_error_logs_on_slug", unique: true
    t.index ["target_type", "target_id"], name: "index_error_logs_on_target_type_and_target_id"
  end

  create_table "games", force: :cascade do |t|
    t.string "away_team_slug", null: false
    t.datetime "created_at", null: false
    t.string "home_team_slug", null: false
    t.datetime "kickoff_at"
    t.string "location"
    t.string "slate_slug", null: false
    t.string "slug", null: false
    t.string "status", default: "scheduled"
    t.datetime "updated_at", null: false
    t.string "venue"
    t.index ["away_team_slug"], name: "index_games_on_away_team_slug"
    t.index ["home_team_slug"], name: "index_games_on_home_team_slug"
    t.index ["slate_slug"], name: "index_games_on_slate_slug"
    t.index ["slug"], name: "index_games_on_slug", unique: true
  end

  create_table "gate_runs", force: :cascade do |t|
    t.string "actor"
    t.integer "attempt", null: false
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.string "key", null: false
    t.jsonb "metadata", default: {}, null: false
    t.jsonb "sops", default: [], null: false
    t.string "source"
    t.datetime "started_at", null: false
    t.string "subject_slug", null: false
    t.string "subject_type", null: false
    t.boolean "success"
    t.datetime "updated_at", null: false
    t.index ["subject_slug", "started_at"], name: "index_gate_runs_on_subject_slug_and_started_at"
    t.index ["subject_type", "subject_slug", "key", "attempt"], name: "index_gate_runs_on_subject_key_attempt", unique: true
    t.index ["subject_type", "subject_slug", "key"], name: "index_gate_runs_one_open_per_gate", unique: true, where: "(finished_at IS NULL)"
  end

  create_table "github_builder_commit_range_caches", force: :cascade do |t|
    t.integer "active_repos_count", default: 0, null: false
    t.decimal "bot_adjusted_builder_multiple", precision: 12, scale: 4
    t.integer "bot_adjusted_commits_count", default: 0, null: false
    t.decimal "builder_multiple", precision: 12, scale: 4
    t.string "cache_run_key", default: "legacy", null: false
    t.datetime "cached_at", null: false
    t.string "cohort", null: false
    t.jsonb "commit_shas", default: [], null: false
    t.integer "commits_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.bigint "github_commit_range_id", null: false
    t.string "github_login", null: false
    t.integer "non_merge_commits_count", default: 0, null: false
    t.bigint "tracked_github_builder_id", null: false
    t.decimal "trailing_90d_avg_weekly_commits", precision: 12, scale: 4
    t.datetime "updated_at", null: false
    t.index ["cache_run_key", "tracked_github_builder_id", "github_commit_range_id"], name: "idx_builder_range_caches_on_run_key_builder_range"
    t.index ["cache_run_key"], name: "idx_builder_range_caches_on_cache_run_key"
    t.index ["github_commit_range_id", "cohort"], name: "idx_builder_range_caches_on_range_cohort"
    t.index ["github_commit_range_id"], name: "index_builder_range_caches_on_range_id"
    t.index ["github_login", "github_commit_range_id"], name: "idx_builder_range_caches_on_login_range"
    t.index ["tracked_github_builder_id", "github_commit_range_id"], name: "idx_builder_range_caches_on_builder_range", unique: true
    t.index ["tracked_github_builder_id"], name: "index_builder_range_caches_on_builder_id"
  end

  create_table "github_builder_index_weeks", force: :cascade do |t|
    t.integer "ai_builder_count", default: 0, null: false
    t.decimal "ai_builder_multiple", precision: 12, scale: 4
    t.integer "control_builder_count", default: 0, null: false
    t.decimal "control_builder_multiple", precision: 12, scale: 4
    t.datetime "created_at", null: false
    t.decimal "difficulty_adjusted_ai_builder_multiple", precision: 12, scale: 4
    t.text "notes"
    t.datetime "updated_at", null: false
    t.date "week_start_date", null: false
    t.index ["week_start_date"], name: "index_github_builder_index_weeks_on_week_start_date", unique: true
  end

  create_table "github_builder_weekly_metrics", force: :cascade do |t|
    t.integer "active_repos_count", default: 0, null: false
    t.decimal "bot_adjusted_builder_multiple", precision: 12, scale: 4
    t.integer "bot_adjusted_commits_count", default: 0, null: false
    t.decimal "builder_multiple", precision: 12, scale: 4
    t.string "cohort", null: false
    t.integer "commits_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.string "github_login", null: false
    t.integer "non_merge_commits_count", default: 0, null: false
    t.decimal "trailing_90d_avg_weekly_commits", precision: 12, scale: 4
    t.datetime "updated_at", null: false
    t.date "week_start_date", null: false
    t.index ["github_login", "week_start_date"], name: "index_builder_weekly_metrics_on_login_week", unique: true
    t.index ["week_start_date", "cohort"], name: "idx_on_week_start_date_cohort_0406de51f1"
  end

  create_table "github_commit_observations", force: :cascade do |t|
    t.string "author_login"
    t.datetime "authored_at"
    t.datetime "committed_at"
    t.string "committer_login"
    t.datetime "created_at", null: false
    t.string "github_login", null: false
    t.string "html_url"
    t.boolean "is_bot", default: false, null: false
    t.boolean "is_merge", default: false, null: false
    t.text "message"
    t.jsonb "raw_payload", default: {}, null: false
    t.string "repo_full_name", null: false
    t.string "sha", null: false
    t.string "source_strategy", null: false
    t.datetime "updated_at", null: false
    t.index ["github_login", "authored_at"], name: "idx_on_github_login_authored_at_00ca1cd94c"
    t.index ["github_login", "committed_at"], name: "idx_on_github_login_committed_at_810ec88674"
    t.index ["repo_full_name", "sha", "github_login"], name: "index_commit_observations_on_repo_sha_login", unique: true
    t.index ["source_strategy"], name: "index_github_commit_observations_on_source_strategy"
  end

  create_table "github_commit_ranges", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "label", null: false
    t.datetime "updated_at", null: false
    t.date "week_end_date", null: false
    t.date "week_start_date", null: false
    t.index ["week_end_date"], name: "index_github_commit_ranges_on_week_end_date"
    t.index ["week_start_date"], name: "index_github_commit_ranges_on_week_start_date", unique: true
  end

  create_table "github_observation_windows", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "observed_through_at"
    t.datetime "updated_at", null: false
  end

  create_table "github_workflow_runs", force: :cascade do |t|
    t.string "conclusion"
    t.datetime "created_at", null: false
    t.string "head_branch"
    t.string "head_sha"
    t.string "html_url"
    t.string "pending_environment"
    t.datetime "pending_since"
    t.string "repo", null: false
    t.integer "run_attempt"
    t.bigint "run_id", null: false
    t.datetime "run_started_at"
    t.string "status", null: false
    t.datetime "updated_at", null: false
    t.string "workflow_name"
    t.index ["head_sha"], name: "index_github_workflow_runs_on_head_sha"
    t.index ["pending_environment"], name: "index_github_workflow_runs_on_pending_environment", where: "(pending_environment IS NOT NULL)"
    t.index ["run_id"], name: "index_github_workflow_runs_on_run_id", unique: true
  end

  create_table "image_caches", force: :cascade do |t|
    t.integer "bytes"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.bigint "owner_id"
    t.string "owner_type"
    t.string "purpose", null: false
    t.string "s3_key", null: false
    t.string "source_url"
    t.datetime "updated_at", null: false
    t.string "variant", null: false
    t.index ["owner_type", "owner_id", "purpose", "variant"], name: "idx_image_caches_owner_purpose_variant", unique: true
    t.index ["owner_type", "owner_id"], name: "index_image_caches_on_owner"
    t.index ["s3_key"], name: "index_image_caches_on_s3_key", unique: true
  end

  create_table "migration_lane_claims", force: :cascade do |t|
    t.datetime "acquired_at"
    t.datetime "claim_expires_at"
    t.string "claim_nonce"
    t.string "claimed_session"
    t.datetime "created_at", null: false
    t.string "holder_agent"
    t.string "holder_label"
    t.string "lane", null: false
    t.string "task_slug"
    t.datetime "updated_at", null: false
    t.index ["lane"], name: "index_migration_lane_claims_on_lane", unique: true
  end

  create_table "model_rate_overrides", force: :cascade do |t|
    t.decimal "cache_creation_rate", precision: 12, scale: 4
    t.decimal "cache_read_rate", precision: 12, scale: 4
    t.datetime "created_at", null: false
    t.decimal "input_rate", precision: 12, scale: 4, null: false
    t.string "model", null: false
    t.decimal "output_rate", precision: 12, scale: 4, null: false
    t.datetime "updated_at", null: false
    t.index ["model"], name: "index_model_rate_overrides_on_model", unique: true
  end

  create_table "news", force: :cascade do |t|
    t.datetime "archived_at"
    t.string "article_image_url"
    t.string "author"
    t.jsonb "callback_ideas", default: []
    t.datetime "concluded_at"
    t.datetime "created_at", null: false
    t.string "feeling"
    t.string "feeling_emoji"
    t.text "opinion"
    t.integer "position"
    t.string "primary_action"
    t.string "primary_person"
    t.string "primary_person_slug"
    t.string "primary_team"
    t.string "primary_team_slug"
    t.datetime "processed_at"
    t.datetime "published_at"
    t.datetime "refined_at"
    t.datetime "reviewed_at"
    t.string "secondary_person"
    t.string "secondary_person_slug"
    t.string "secondary_team"
    t.string "secondary_team_slug"
    t.string "slug", null: false
    t.string "stage", default: "new", null: false
    t.text "summary"
    t.string "title", null: false
    t.string "title_short"
    t.datetime "updated_at", null: false
    t.string "url"
    t.string "what_happened"
    t.string "x_post_id"
    t.string "x_post_url"
    t.index ["primary_person_slug"], name: "index_news_on_primary_person_slug"
    t.index ["primary_team_slug"], name: "index_news_on_primary_team_slug"
    t.index ["secondary_person_slug"], name: "index_news_on_secondary_person_slug"
    t.index ["secondary_team_slug"], name: "index_news_on_secondary_team_slug"
    t.index ["slug"], name: "index_news_on_slug", unique: true
    t.index ["stage", "position"], name: "index_news_on_stage_and_position"
    t.index ["stage"], name: "index_news_on_stage"
  end

  create_table "people", force: :cascade do |t|
    t.jsonb "aliases", default: []
    t.boolean "athlete", default: false
    t.string "avatar_url"
    t.boolean "coach", default: false
    t.datetime "created_at", null: false
    t.string "email"
    t.string "facebook_url"
    t.string "first_name", null: false
    t.string "instagram_url"
    t.string "last_name", null: false
    t.string "linkedin_url"
    t.string "location"
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.string "website_url"
    t.string "x_url"
    t.index ["email"], name: "index_people_on_email"
    t.index ["last_name", "first_name"], name: "index_people_on_last_name_and_first_name"
    t.index ["slug"], name: "index_people_on_slug", unique: true
  end

  create_table "pff_stats", force: :cascade do |t|
    t.string "athlete_slug", null: false
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.integer "games_played"
    t.integer "pff_player_id"
    t.string "season_slug", null: false
    t.string "slug", null: false
    t.string "stat_type", null: false
    t.string "team_slug"
    t.datetime "updated_at", null: false
    t.index ["athlete_slug", "season_slug", "stat_type"], name: "idx_pff_stats_unique", unique: true
    t.index ["data"], name: "index_pff_stats_on_data", using: :gin
    t.index ["pff_player_id"], name: "index_pff_stats_on_pff_player_id"
    t.index ["slug"], name: "index_pff_stats_on_slug", unique: true
    t.index ["stat_type"], name: "index_pff_stats_on_stat_type"
  end

  create_table "pff_team_stats", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.jsonb "data", default: {}, null: false
    t.string "season_slug", null: false
    t.string "slug", null: false
    t.string "stat_type", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["data"], name: "index_pff_team_stats_on_data", using: :gin
    t.index ["slug"], name: "index_pff_team_stats_on_slug", unique: true
    t.index ["team_slug", "season_slug", "stat_type"], name: "idx_pff_team_stats_unique", unique: true
  end

  create_table "pokemons", force: :cascade do |t|
    t.integer "attack"
    t.string "avatar_fallback_url"
    t.string "avatar_url"
    t.jsonb "baby", default: [], null: false
    t.string "base"
    t.datetime "created_at", null: false
    t.integer "defense"
    t.integer "dex", null: false
    t.jsonb "evolution", default: [], null: false
    t.integer "generation", default: 1, null: false
    t.integer "hp"
    t.string "name", null: false
    t.string "primary_type"
    t.string "shiny_avatar_fallback_url"
    t.string "shiny_avatar_url"
    t.string "shiny_sprite_url"
    t.string "slug", null: false
    t.integer "special_attack"
    t.integer "special_defense"
    t.integer "speed"
    t.string "sprite_url"
    t.string "types", default: [], null: false, array: true
    t.datetime "updated_at", null: false
    t.index ["dex"], name: "index_pokemons_on_dex", unique: true
    t.index ["slug"], name: "index_pokemons_on_slug", unique: true
  end

  create_table "release_conductor_claims", force: :cascade do |t|
    t.datetime "acquired_at"
    t.datetime "claim_expires_at"
    t.string "claim_nonce"
    t.string "claimed_session"
    t.datetime "created_at", null: false
    t.string "holder_label"
    t.string "release_slug", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.index ["release_slug", "role"], name: "index_release_conductor_claims_on_release_slug_and_role", unique: true
  end

  create_table "release_events", force: :cascade do |t|
    t.string "actor"
    t.string "app"
    t.string "command"
    t.decimal "cost", precision: 10, scale: 4
    t.datetime "created_at", null: false
    t.string "idempotency_key"
    t.text "message"
    t.jsonb "metadata", default: {}, null: false
    t.string "model"
    t.datetime "occurred_at", null: false
    t.string "release_slug", null: false
    t.string "repo"
    t.string "sha"
    t.string "source"
    t.string "status", null: false
    t.string "step", null: false
    t.integer "tokens_in"
    t.integer "tokens_out"
    t.datetime "updated_at", null: false
    t.string "url"
    t.index ["release_slug", "idempotency_key"], name: "index_release_events_on_release_slug_and_idempotency_key", unique: true, where: "(idempotency_key IS NOT NULL)"
    t.index ["release_slug", "occurred_at"], name: "index_release_events_on_release_slug_and_occurred_at"
    t.index ["release_slug", "step", "status"], name: "index_release_events_on_release_slug_and_step_and_status"
  end

  create_table "releases", force: :cascade do |t|
    t.datetime "abandoned_at"
    t.datetime "assembled_at"
    t.datetime "assembling_started_at"
    t.string "branch"
    t.datetime "confirmed_at"
    t.string "confirmed_by"
    t.datetime "confirming_started_at"
    t.datetime "created_at", null: false
    t.string "deployed_sha"
    t.integer "duration_cache_version", default: 1, null: false
    t.jsonb "duration_metrics", default: {}, null: false
    t.datetime "duration_metrics_cached_at"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "prod_deploy_started_at"
    t.string "production_url"
    t.datetime "qa_deploy_started_at"
    t.datetime "qa_deployed_at"
    t.string "qa_url"
    t.datetime "release_notes_sent_at"
    t.datetime "shipped_at"
    t.string "slug", null: false
    t.jsonb "smoke_seal", default: {}, null: false
    t.string "state", default: "assembling", null: false
    t.datetime "tested_at"
    t.datetime "testing_started_at"
    t.datetime "updated_at", null: false
    t.index "(1)", name: "index_releases_single_active", unique: true, where: "((state)::text = ANY (ARRAY[('assembling'::character varying)::text, ('assembled'::character varying)::text]))"
    t.index ["slug"], name: "index_releases_on_slug", unique: true
  end

  create_table "review_pending_actions", force: :cascade do |t|
    t.string "action", default: "merge_to_accepted", null: false
    t.integer "attempts", default: 0, null: false
    t.string "authorized_by"
    t.string "base_branch", default: "accepted", null: false
    t.datetime "created_at", null: false
    t.datetime "executed_at"
    t.datetime "expires_at", null: false
    t.string "head_sha", null: false
    t.datetime "last_attempted_at"
    t.string "merge_method", default: "merge", null: false
    t.string "merge_sha"
    t.jsonb "metadata", default: {}, null: false
    t.text "outcome_reason"
    t.integer "pr_number", null: false
    t.string "pr_url"
    t.string "repo", null: false
    t.string "state", default: "pending", null: false
    t.string "task_slug", null: false
    t.datetime "updated_at", null: false
    t.string "verdict", null: false
    t.bigint "verdict_activity_id"
    t.datetime "verdict_recorded_at"
    t.index ["repo", "head_sha"], name: "index_review_pending_actions_on_repo_and_head_sha"
    t.index ["state", "expires_at"], name: "index_review_pending_actions_on_state_and_expires_at"
    t.index ["task_slug"], name: "index_review_pending_actions_on_live_task_slug", unique: true, where: "((state)::text = 'pending'::text)"
    t.index ["task_slug"], name: "index_review_pending_actions_on_task_slug"
  end

  create_table "roster_spots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "depth", default: 1, null: false
    t.string "person_slug", null: false
    t.string "position", null: false
    t.bigint "roster_id", null: false
    t.string "side", null: false
    t.datetime "updated_at", null: false
    t.index ["person_slug"], name: "index_roster_spots_on_person_slug"
    t.index ["roster_id", "position", "depth"], name: "index_roster_spots_on_roster_id_and_position_and_depth", unique: true
    t.index ["roster_id"], name: "index_roster_spots_on_roster_id"
  end

  create_table "rosters", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "slate_slug", null: false
    t.string "slug", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["slate_slug"], name: "index_rosters_on_slate_slug"
    t.index ["slug"], name: "index_rosters_on_slug", unique: true
    t.index ["team_slug", "slate_slug"], name: "index_rosters_on_team_slug_and_slate_slug", unique: true
    t.index ["team_slug"], name: "index_rosters_on_team_slug"
  end

  create_table "seasons", force: :cascade do |t|
    t.boolean "active", default: false
    t.datetime "created_at", null: false
    t.string "league", null: false
    t.string "name", null: false
    t.string "slug", null: false
    t.string "sport", null: false
    t.datetime "updated_at", null: false
    t.integer "year", null: false
    t.index ["league", "active"], name: "index_seasons_on_league_and_active"
    t.index ["slug"], name: "index_seasons_on_slug", unique: true
    t.index ["year", "league"], name: "index_seasons_on_year_and_league", unique: true
  end

  create_table "session_mascots", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "mascot_slug", null: false
    t.string "parent_session_id"
    t.string "session_id", null: false
    t.boolean "shiny", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["parent_session_id"], name: "index_session_mascots_on_parent_session_id"
    t.index ["session_id"], name: "index_session_mascots_on_session_id", unique: true
  end

  create_table "signing_requests", force: :cascade do |t|
    t.jsonb "accounts", default: {}, null: false
    t.jsonb "args", default: {}, null: false
    t.string "cluster", default: "devnet", null: false
    t.jsonb "collected_signatures", default: {}, null: false
    t.string "coordination", default: "multi", null: false
    t.datetime "created_at", null: false
    t.string "durable_nonce_pubkey"
    t.string "expected_signers", default: [], null: false, array: true
    t.string "fee_payer"
    t.string "instruction_name", null: false
    t.text "last_error"
    t.string "multisig_pubkey"
    t.string "nonce_authority"
    t.string "program", default: "turf_vault", null: false
    t.string "program_id", null: false
    t.string "slug", null: false
    t.string "status", default: "awaiting_signatures", null: false
    t.integer "threshold", default: 1, null: false
    t.string "title"
    t.string "tx_signature"
    t.text "unsigned_message_base64"
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_signing_requests_on_slug", unique: true
    t.index ["status"], name: "index_signing_requests_on_status"
  end

  create_table "skill_assignments", force: :cascade do |t|
    t.string "agent_slug", null: false
    t.datetime "created_at", null: false
    t.integer "proficiency", default: 100
    t.string "skill_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "skill_slug"], name: "index_skill_assignments_on_agent_slug_and_skill_slug", unique: true
    t.index ["agent_slug"], name: "index_skill_assignments_on_agent_slug"
    t.index ["skill_slug"], name: "index_skill_assignments_on_skill_slug"
  end

  create_table "skills", force: :cascade do |t|
    t.string "category"
    t.jsonb "config", default: {}
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "slug", null: false
    t.datetime "updated_at", null: false
    t.index ["category"], name: "index_skills_on_category"
    t.index ["slug"], name: "index_skills_on_slug", unique: true
  end

  create_table "slates", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.date "ends_at"
    t.string "label", null: false
    t.string "season_slug", null: false
    t.integer "sequence", null: false
    t.string "slate_type", null: false
    t.string "slug", null: false
    t.date "starts_at"
    t.datetime "updated_at", null: false
    t.index ["season_slug", "sequence"], name: "index_slates_on_season_slug_and_sequence", unique: true
    t.index ["season_slug"], name: "index_slates_on_season_slug"
    t.index ["slug"], name: "index_slates_on_slug", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "studio_email_deliveries", force: :cascade do |t|
    t.string "action", null: false
    t.jsonb "args", default: [], null: false
    t.datetime "created_at", null: false
    t.string "email_key", null: false
    t.text "error"
    t.jsonb "kwargs", default: {}, null: false
    t.string "mailer", null: false
    t.boolean "sent", default: false, null: false
    t.datetime "sent_at"
    t.string "to"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["created_at"], name: "index_studio_email_deliveries_on_created_at"
    t.index ["email_key"], name: "index_studio_email_deliveries_on_email_key"
    t.index ["sent"], name: "index_studio_email_deliveries_on_sent"
    t.index ["user_id"], name: "index_studio_email_deliveries_on_user_id"
  end

  create_table "studio_email_settings", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "cta_color"
    t.boolean "cta_enabled"
    t.string "cta_text"
    t.string "discord_url"
    t.string "email_key", null: false
    t.string "header"
    t.string "header_fallback"
    t.boolean "hide_logo", default: false, null: false
    t.string "logo_url"
    t.integer "scrim_percent"
    t.string "subject"
    t.string "subtext"
    t.datetime "updated_at", null: false
    t.index ["email_key"], name: "index_studio_email_settings_on_email_key", unique: true
  end

  create_table "studio_enumerals", force: :cascade do |t|
    t.string "category", null: false
    t.string "color"
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "label"
    t.jsonb "metadata", default: {}, null: false
    t.integer "position", default: 0, null: false
    t.integer "rank"
    t.datetime "updated_at", null: false
    t.index ["category", "key"], name: "index_studio_enumerals_on_category_and_key", unique: true
    t.index ["category", "position"], name: "index_studio_enumerals_on_category_and_position"
    t.index ["category", "rank"], name: "index_studio_enumerals_on_category_and_rank"
  end

  create_table "studio_links", force: :cascade do |t|
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "kind", null: false
    t.bigint "linkable_id"
    t.string "linkable_type"
    t.jsonb "metadata", default: {}, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["kind"], name: "index_studio_links_on_kind"
    t.index ["linkable_type", "linkable_id", "kind"], name: "idx_studio_links_owner_kind"
    t.index ["token"], name: "index_studio_links_on_token", unique: true
  end

  create_table "task_events", force: :cascade do |t|
    t.string "actor"
    t.integer "cache_creation_tokens"
    t.integer "cache_read_tokens"
    t.decimal "cost", precision: 10, scale: 4
    t.datetime "created_at", null: false
    t.string "from_stage"
    t.string "kind", default: "transition", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "model"
    t.datetime "occurred_at", null: false
    t.integer "seconds_in_from"
    t.string "source"
    t.string "task_slug", null: false
    t.string "to_stage", null: false
    t.integer "tokens_in"
    t.integer "tokens_out"
    t.datetime "updated_at", null: false
    t.index ["task_slug", "kind"], name: "index_task_events_on_task_slug_and_kind"
    t.index ["task_slug", "occurred_at"], name: "index_task_events_on_task_slug_and_occurred_at"
  end

  create_table "task_review_claims", force: :cascade do |t|
    t.datetime "acquired_at"
    t.datetime "claim_expires_at"
    t.string "claim_nonce"
    t.string "claimed_session"
    t.datetime "created_at", null: false
    t.string "holder_agent"
    t.string "holder_label"
    t.string "task_slug", null: false
    t.datetime "updated_at", null: false
    t.index ["task_slug"], name: "index_task_review_claims_on_task_slug", unique: true
  end

  create_table "tasks", force: :cascade do |t|
    t.string "actual_size"
    t.string "agent_slug"
    t.datetime "archived_at"
    t.datetime "assembled_at"
    t.string "block_kind"
    t.datetime "blocked_at"
    t.string "blocked_by"
    t.string "blocked_from"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.jsonb "dependencies", default: [], null: false
    t.text "description"
    t.string "dev_size"
    t.text "error_message"
    t.datetime "failed_at"
    t.datetime "g1_failed_at"
    t.datetime "g1_testing_finished_at"
    t.datetime "g1_testing_started_at"
    t.jsonb "gates", default: {}, null: false
    t.datetime "gates_cached_at"
    t.integer "gates_version", default: 0, null: false
    t.string "merged"
    t.jsonb "metadata", default: {}
    t.string "pm_size"
    t.string "po_size"
    t.integer "position"
    t.integer "priority", default: 0
    t.datetime "queued_at"
    t.string "release_slug"
    t.jsonb "required_skills", default: []
    t.boolean "requires_migration", default: false, null: false
    t.jsonb "result", default: {}
    t.datetime "reviewed_at"
    t.datetime "sizes_revealed_at"
    t.string "slug", null: false
    t.string "stage", default: "designed"
    t.datetime "started_at"
    t.datetime "submitted_at"
    t.jsonb "testing_phases", default: {}, null: false
    t.datetime "testing_phases_cached_at"
    t.integer "testing_phases_version", default: 0, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["agent_slug"], name: "index_tasks_on_agent_slug"
    t.index ["priority"], name: "index_tasks_on_priority"
    t.index ["release_slug"], name: "index_tasks_on_release_slug"
    t.index ["requires_migration"], name: "index_tasks_on_requires_migration"
    t.index ["slug"], name: "index_tasks_on_slug", unique: true
    t.index ["stage", "created_at"], name: "index_tasks_on_stage_and_created_at"
    t.index ["stage", "position"], name: "index_tasks_on_stage_and_position"
    t.index ["stage"], name: "index_tasks_on_stage"
  end

  create_table "team_rankings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "rank", null: false
    t.string "rank_type", null: false
    t.decimal "score", precision: 10, scale: 2
    t.string "season_slug", null: false
    t.string "slug", null: false
    t.string "team_slug", null: false
    t.datetime "updated_at", null: false
    t.integer "week"
    t.index ["season_slug"], name: "index_team_rankings_on_season_slug"
    t.index ["slug"], name: "index_team_rankings_on_slug", unique: true
    t.index ["team_slug", "rank_type", "season_slug", "week"], name: "idx_team_rankings_unique_with_week", unique: true, where: "(week IS NOT NULL)"
    t.index ["team_slug", "rank_type", "season_slug"], name: "idx_team_rankings_unique_preseason", unique: true, where: "(week IS NULL)"
    t.index ["team_slug"], name: "index_team_rankings_on_team_slug"
  end

  create_table "teams", force: :cascade do |t|
    t.string "coaches_url"
    t.string "color_primary"
    t.string "color_secondary"
    t.boolean "color_text_light", default: false
    t.string "conference"
    t.datetime "created_at", null: false
    t.string "division"
    t.string "emoji"
    t.string "hashtag"
    t.string "hashtag2"
    t.string "home_arena_slug"
    t.string "league"
    t.string "location"
    t.string "logo_path"
    t.string "logo_source"
    t.string "logo_url"
    t.string "mascot"
    t.string "name", null: false
    t.jsonb "rivals", default: []
    t.string "short_name"
    t.string "slug", null: false
    t.string "sport"
    t.string "team_website"
    t.datetime "updated_at", null: false
    t.string "x_handle"
    t.index ["home_arena_slug"], name: "index_teams_on_home_arena_slug"
    t.index ["slug"], name: "index_teams_on_slug", unique: true
    t.index ["sport", "league"], name: "index_teams_on_sport_and_league"
  end

  create_table "theme_settings", force: :cascade do |t|
    t.string "accent1"
    t.string "accent2"
    t.string "app_name", null: false
    t.datetime "created_at", null: false
    t.string "danger"
    t.string "dark"
    t.string "light"
    t.string "primary"
    t.string "slug"
    t.datetime "updated_at", null: false
    t.string "warning"
    t.index ["app_name"], name: "index_theme_settings_on_app_name", unique: true
  end

  create_table "tracked_github_builder_repos", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "repo_category"
    t.string "repo_full_name", null: false
    t.bigint "tracked_github_builder_id", null: false
    t.datetime "updated_at", null: false
    t.index ["repo_full_name"], name: "index_tracked_github_builder_repos_on_repo_full_name"
    t.index ["tracked_github_builder_id", "repo_full_name"], name: "index_builder_repos_on_builder_and_repo", unique: true
    t.index ["tracked_github_builder_id"], name: "index_builder_repos_on_builder_id"
  end

  create_table "tracked_github_builders", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "category"
    t.string "cohort", null: false
    t.datetime "created_at", null: false
    t.string "display_name"
    t.string "github_login", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.index ["cohort", "active"], name: "index_tracked_github_builders_on_cohort_and_active"
    t.index ["github_login"], name: "index_tracked_github_builders_on_github_login", unique: true
  end

  create_table "triage_findings", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "prior_art", default: "unknown", null: false
    t.text "prior_art_note"
    t.string "promoted_task_slug"
    t.string "repo"
    t.datetime "resolved_at"
    t.string "slug", null: false
    t.string "source"
    t.string "status", default: "open", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["slug"], name: "index_triage_findings_on_slug", unique: true
    t.index ["status"], name: "index_triage_findings_on_status"
  end

  create_table "usages", force: :cascade do |t|
    t.string "agent_slug"
    t.integer "api_calls", default: 0
    t.decimal "cost", precision: 10, scale: 4, default: "0.0"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}
    t.string "model"
    t.date "period_date", null: false
    t.string "period_type", null: false
    t.string "slug"
    t.integer "tasks_completed", default: 0
    t.integer "tasks_failed", default: 0
    t.integer "tokens_in", default: 0
    t.integer "tokens_out", default: 0
    t.datetime "updated_at", null: false
    t.index ["agent_slug", "period_date", "period_type", "model"], name: "idx_usages_unique", unique: true
    t.index ["agent_slug"], name: "index_usages_on_agent_slug"
    t.index ["slug"], name: "index_usages_on_slug", unique: true
  end

  create_table "users", force: :cascade do |t|
    t.integer "birth_day"
    t.integer "birth_month"
    t.integer "birth_year"
    t.datetime "created_at", null: false
    t.string "email"
    t.datetime "email_verified_at"
    t.string "first_name"
    t.jsonb "ip_locations", default: [], null: false
    t.string "last_name"
    t.string "name"
    t.string "password_digest"
    t.string "provider"
    t.string "role", default: "viewer"
    t.string "session_token"
    t.string "slug"
    t.string "solana_address"
    t.string "uid"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["slug"], name: "index_users_on_slug", unique: true
    t.index ["solana_address"], name: "index_users_on_solana_address", unique: true
  end

  add_foreign_key "action_grades", "agent_actions"
  add_foreign_key "action_grades", "agent_activities", on_delete: :nullify
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "agent_actions", "agent_activities", on_delete: :nullify
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
