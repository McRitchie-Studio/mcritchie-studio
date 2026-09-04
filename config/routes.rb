Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  root "landing#index"
  get "terms",   to: "landing#terms",   as: :terms
  get "privacy", to: "landing#privacy", as: :privacy

  # Broadcast emails — table view + editor. `preview` renders the email itself
  # (in the email shell) for the editor's live iframe.
  resources :broadcasts, only: %i[index edit update] do
    member do
      get  :preview
      post :deliver
    end
  end

  # One-click-safe unsubscribe: GET shows an inert confirm page, POST unsubscribes.
  get  "unsubscribe/:token", to: "unsubscribes#show",   as: :unsubscribe
  post "unsubscribe/:token", to: "unsubscribes#create"

  # Email engagement tracking (open pixel + click redirect), keyed by delivery token.
  get "e/o/:token", to: "email_tracking#open",  as: :email_open
  get "e/c/:token", to: "email_tracking#click", as: :email_click

  get "dashboard", to: "dashboard#index"
  # Task-development trends dashboard (stage speed, cycle time, tokens, cost,
  # estimate-vs-actual). Public-read like the other board surfaces.
  get "intelligence", to: "intelligence#index", as: :intelligence
  # Pokédex — read-only spawn/activity surface for session mascots. /pokemon
  # stays as a compatibility alias for the earlier reference-data inspector URL.
  get "pokedex", to: "pokemon#index", as: :pokedex
  get "pokemon", to: "pokemon#index", as: :pokemon
  # Board split: /tasks is the Build lane, /deployments is the Deploy lane (+ the
  # current-release module), /stages is the two-workflow stage guide. All three
  # are public-read like /tasks (mutations stay admin-gated in TasksController).
  # The findings TRIAGE inbox — agent follow-ups wait here for an operator call.
  # Reading is open like the boards; promote/dismiss are admin-gated (promote
  # MINTS a task — the operator's lane, mirrored by the API's file/list-only split).
  get "triage", to: "triage#index", as: :triage
  post "triage/:slug/promote", to: "triage#promote", as: :promote_triage_finding
  post "triage/:slug/dismiss", to: "triage#dismiss", as: :dismiss_triage_finding
  get "deployments", to: "tasks#deployments", as: :deployments
  get "deployments/all", to: "releases#index", as: :all_deployments
  get "deployments/:slug", to: "releases#show", as: :deployment
  get "review_events", to: "tasks#review_events_hub", as: :review_events_hub
  get "stages", to: "tasks#stages", as: :stages
  # /stages/sop — the operator's DevOps SOP as an accountability-swimlane infographic.
  get "stages/sop", to: "tasks#sop", as: :sop
  # Model-page protocol routes (/models/:model/:id, /models/:model/random) are
  # drawn by studio-engine's Studio.routes — see config/initializers/model_pages.rb
  # for the per-model registry (Release enabled).

  # Local-only (development + test, NEVER production) board toys for demoing the
  # live /deployments board: generate / move / delete a throwaway fixture task.
  # Drawn only when local? so the routes simply do not exist in production; the
  # controller re-checks Rails.env.local? as defense in depth. See Dev::BoardController.
  if Rails.env.local?
    namespace :dev do
      post "board/generate",     to: "board#generate",     as: :board_generate
      post "board/move",         to: "board#move",         as: :board_move
      post "board/delete",       to: "board#delete",       as: :board_delete
      post "board/ship_release", to: "board#ship_release", as: :board_ship_release
      # Deployment-step toys: open / advance / reset a fixture RELEASE so the live
      # tracker can be stepped Testing → … → Deploying without real data.
      post "board/open_release",    to: "board#open_release",    as: :board_open_release
      post "board/advance_release", to: "board#advance_release", as: :board_advance_release
      post "board/reset_release",   to: "board#reset_release",   as: :board_reset_release
      # The SPURIOUS redraw, on demand: re-broadcast the release modules with nothing
      # changed. The exact shape .ci_progress used to send on every CI upsert, and the
      # negative case the ReleaseFx router must answer with silence.
      post "board/rebroadcast_release_modules", to: "board#rebroadcast_release_modules",
                                                as: :board_rebroadcast_release_modules
    end
  end
  # Public link hub — general (non-admin) destinations. The admin counterpart
  # lives at /admin/links (admin#links, require_admin). Both are surfaced from
  # the nav dropdown (Admin Links shows only to admins).
  get "links", to: "links#index", as: :links

  # Session entry launcher — terminal-styled chooser for the avenue you enter a
  # session as (Session agent · Avi · Alex). Selecting Alex routes to the learning
  # heartbeat at /alex/heartbeat, the per-action atomic trajectory table
  # (HeartbeatController#show). The named route (alex_heartbeat_path) is stable, so
  # the launcher anchor follows it; it was repointed off LauncherController's
  # placeholder once the real view (T2) landed.
  get "launcher", to: "launcher#index", as: :launcher
  get "alex/heartbeat", to: "heartbeat#show", as: :alex_heartbeat
  # Feedback layer over the read-only trajectory (T5): a per-action grading drawer
  # (GET, lazy-loaded into a turbo-frame), the upsert/bank/discard write, and the
  # curated Insight Bank page. Like the view itself, this is an open meta surface.
  get  "alex/heartbeat/actions/:id/feedback", to: "heartbeat#feedback", as: :heartbeat_feedback
  post "alex/heartbeat/actions/:id/grade",    to: "heartbeat#grade",    as: :heartbeat_grade
  # Activity-level grade: upsert one grade for a narrated AgentActivity. JSON only
  # by design so it stays view-free from the drawer/turbo stream path.
  post "alex/heartbeat/activities/:id/grade", to: "heartbeat#grade_activity", as: :heartbeat_activity_grade
  # The per-activity grading drawer body, lazy-loaded into the shared turbo-frame
  # on an activity's grade click. Old /events paths stay as compatibility aliases.
  get  "alex/heartbeat/activities/:id/feedback", to: "heartbeat#feedback_activity", as: :heartbeat_activity_feedback
  post "alex/heartbeat/events/:id/grade", to: "heartbeat#grade_activity", as: :heartbeat_event_grade
  get  "alex/heartbeat/events/:id/feedback", to: "heartbeat#feedback_activity", as: :heartbeat_event_feedback
  # Every AgentActivity across ALL sessions, newest-first, paginated 100/page —
  # the cross-session analogue of the per-session heartbeat.
  get  "alex/heartbeat/activities", to: "heartbeat#all_activities", as: :heartbeat_all_activities
  get  "alex/heartbeat/spans", to: "heartbeat#all_activities", as: :heartbeat_all_spans
  get  "alex/insights", to: "heartbeat#insights", as: :alex_insights
  # The OPSD distillation pipeline, left→right: Activities → Insights (Alex's
  # grades) → Confirmations (McRitchie's mcr grades). `confirm` records the McRitchie
  # (mcr) confirmation of an insight and redirects back (a no-JS form action).
  get  "alex/pipeline", to: "heartbeat#pipeline", as: :alex_pipeline
  post "alex/pipeline/confirm/:id", to: "heartbeat#confirm", as: :alex_pipeline_confirm

  get "toast_test", to: "toast_test#index"
  post "toast_test/flash", to: "toast_test#trigger_flash"
  resources :chat, only: [:index, :create]
  resources :schedule, only: [:index]

  # Unified auth — login + signup are one create-or-login flow, so they share a
  # single canonical page at /signin (sessions#new). Legacy /login + /signup GETs
  # 301 here, preserving the query string (so ?email= prefill survives). Defined
  # BEFORE Studio.routes so they win GET recognition; the engine still draws
  # /login + /signup below, keeping login_path/signup_path helpers + the POST
  # actions. as: nil avoids a name clash with those engine-named routes.
  get "signin", to: "sessions#new", as: :signin
  signin_redirect = ->(_params, req) { req.query_string.present? ? "/signin?#{req.query_string}" : "/signin" }
  get "login",  to: redirect(&signin_redirect), as: nil
  get "signup", to: redirect(&signin_redirect), as: nil

  Studio.routes(self)

  # TikTok OAuth handshake (one-time, admin-only) — visit /admin/tiktok/connect
  # to authorize @turfmonstershow and capture refresh_token + open_id.
  # Resend inbound (email.received, svix-signed) -> the desk capture queue.
  post "webhooks/resend/inbound", to: "webhooks/resend_inbound#create"

  namespace :admin do
    get "dashboard", to: "dashboard#show", as: :dashboard
    # The knowledge-capture front door's mail queue (team@mcritchie.studio).
    get "desk", to: "desk#index", as: :desk
    get "models", to: "models#index", as: :models
    get "models/:key", to: "models#show", as: :model

    # Model Pricing — per-model $/1M rate roster + last-session cost summary, with
    # a slider UI to persist rate overrides. Glob `*model` + format:false so a
    # dotted canonical id (e.g. "gpt-5.5") is captured whole, not split as a format.
    get   "model_pricing", to: "model_pricing#index", as: :model_pricing
    get   "model_pricing/*model", to: "model_pricing#show", as: :model_pricing_model, format: false
    patch "model_pricing/*model", to: "model_pricing#update", format: false

    # Admin link hub — gathers every admin/operator destination (incl. the
    # on-chain Signing Console). admin#links, require_admin. /admin/links.
    get "links", to: "links#index", as: :links
    get "ai_builder_multiple", to: "ai_builder_multiple#index"
    get "ai_builder_multiple/commit_history", to: "ai_builder_multiple#commit_history", as: :ai_builder_multiple_commit_history

    get "tiktok/connect",  to: "tiktok#connect",  as: :tiktok_connect
    get "tiktok/callback", to: "tiktok#callback", as: :tiktok_callback
  end

  # HTML
  # The cross-session, filterable activity feed reimagined under the agents surface.
  # `collection` so /agents/activities routes to #activities instead of #show
  # (param :slug would otherwise swallow "activities" as an agent slug).
  resources :agents, only: [:index, :show], param: :slug do
    collection do
      get :activities
      # The activity feed's session-filter list is its OWN endpoint so the heavy
      # cross-session scan (session_filter_options) lazy-loads into the sidebar's
      # aa-filter-frame the first time the panel opens, instead of riding every
      # #activities render.
      get :activities_filter
    end
  end
  resources :tasks, param: :slug do
    collection do
      post :reorder
      # /tasks/recent — flat recency list surfacing testing-phase durations +
      # gate verdicts per task. Public-read like the board; declared on the
      # collection so "recent" is never swallowed as a :slug by #show.
      get :recent
    end
    member do
      # Stages move through PATCH update (one path shared by the board drag-drop,
      # bin/task, and the API). `comment` posts task-conversation activities.
      get :review_events
      # The board's WAITING APPROVAL CTA — PUBLIC (TasksController::PUBLIC_ACTIONS),
      # because a logged-out click must still reach the review. It mints nothing:
      # it 302s to the LOCAL stack's loopback-only mint endpoint, with no email.
      get :local_review
      post :comment
      # Block/unblock are `building` ATTRIBUTE toggles (not stage moves) — the
      # show-page Block/Resume controls, routed through Task#block!/#unblock!.
      patch :block
      patch :unblock
    end
    resource :sizing, only: [:show, :update]
  end
  resources :news, param: :slug do
    collection do
      get :workflow
      post :reorder
    end
    member do
      post :archive
      post :review
      post :process_step
      post :refine
      post :conclude
      post :create_content
    end
  end
  resources :contents, param: :slug do
    collection do
      post :reorder
      post :starter_post_x,                action: :create_starter_post_x
      post :starter_post_tiktok_offense,   action: :create_starter_post_tiktok_offense
      post :starter_post_tiktok_defense,   action: :create_starter_post_tiktok_defense
    end
    member do
      post :hook_step
      post :script_step
      post :assets_step
      post :assemble_step
      post :post_step
      post :review_step
      post :script_agent_step
      post :assets_agent_step
      post :assemble_agent_step
      post :finalize_step
      post :metadata_step
      post :generate_lineup_assets
      post :post_to_x
      post :post_to_tiktok
      post :prep_for_tiktok
      post :use_caption_variant
      post :mark_posted
      post :studio_upload_to_tiktok
    end
  end
  resources :teams, only: [:index], param: :slug
  resources :builders, only: [:index], param: :github_login do
    collection do
      get :all
      get :history
    end

    member do
      patch :archive
      patch :restore
    end
  end
  resources :people, only: [:index], param: :slug do
    collection do
      get :merge
      post :merge, action: :merge_execute
      get :duplicates
    end
  end

  # NFL hub + rankings (SEO-friendly URLs)
  get "nfl", to: "nfl#index", as: :nfl_hub
  get "nfl-rosters", to: "nfl#rosters", as: :nfl_rosters
  get  "teams/:slug/depth-chart",                to: "depth_charts#show",        as: :team_depth_chart
  get  "teams/:slug/lineup-graphic",             to: "lineup_graphics#show",     as: :team_lineup_graphic
  post "teams/:slug/depth-chart/reorder",        to: "depth_charts#reorder",     as: :reorder_depth_chart
  post "depth_chart_entries/:id/toggle_lock",    to: "depth_charts#toggle_lock", as: :toggle_lock_depth_chart_entry
  get "nfl-quarterback-rankings", to: "rankings#quarterback", as: :nfl_quarterback_rankings
  get "nfl-offensive-line-rankings", to: "rankings#offensive_line", as: :nfl_offensive_line_rankings
  get "nfl-receiving-rankings",      to: "rankings#receiving",      as: :nfl_receiving_rankings
  get "nfl-rushing-rankings",        to: "rankings#rushing",        as: :nfl_rushing_rankings
  get "nfl-defense-rankings",        to: "rankings#defense",        as: :nfl_defense_rankings
  get "nfl-pass-rush-rankings",      to: "rankings#pass_rush",      as: :nfl_pass_rush_rankings
  get "nfl-coverage-rankings",       to: "rankings#coverage",       as: :nfl_coverage_rankings
  get "nfl-prospects",                 to: "rankings#prospects",      as: :nfl_prospects
  get "nfl-coaches",                  to: "rankings#coaches",        as: :nfl_coaches
  get "nfl-pass-first-rankings",       to: "rankings#pass_first",     as: :nfl_pass_first_rankings
  get "nfl-team-rankings/:id",         to: "rankings#team_unit",      as: :nfl_team_rankings
  get "nfl-team-grades/:team_slug",    to: "team_grades#show",        as: :nfl_team_grades
  get "nfl-player-impact/:player_id/to/:team_id", to: "rankings#player_impact", as: :nfl_player_impact
  post "nfl-player-impact/:player_id/to/:team_id/confirm", to: "rankings#confirm_draft_pick", as: :confirm_draft_pick
  get "nfl-contracts",                to: "contracts#index",         as: :nfl_contracts

  # NFL game slate pages
  get "games/:year", to: "games#season", as: :games_season, constraints: { year: /\d{4}/ }
  get "games/:year/week/:week", to: "games#week", as: :games_week
  get "games/:year/week/:week/:slug", to: "games#show", as: :game_show
  get "people/search", to: "people#search", as: :search_people
  get "activities", to: redirect("/agents"), as: :activities
  resources :usages, only: [:index]

  get "docs", to: "docs#index"
  get "docs/*path", to: "docs#show", as: :doc

  # JSON API
  namespace :api do
    namespace :v1 do
      post "auth", to: "auth#create"
      post "release_notes", to: "release_notes#create"
      # GitHub Actions webhook receiver (workflow_run events). Called by GitHub,
      # not an agent — GithubWebhooksController skips bearer auth and gates ONLY
      # on the HMAC signature. DevOps v2: agents read CI status off the board.
      post "github/webhook", to: "github_webhooks#create"
      # Triage findings: agents FILE and LIST; promotion to a task is deliberately
      # web-only (TriageController#promote, admin-gated) — the operator's lane.
      resources :triage_findings, only: [:index, :create]
      # The desk ledger — the audit row `bin/agent-worktree` files when it nominates or
      # tears down a worktree desk. It used to be a markdown table in the hub repo, which
      # a teardown run from the PRIMARY checkout wrote onto `main` and could never commit.
      # `sync` folds a whole `snapshot --write` registry in; `create` files one desk.
      resources :desk_records, only: [:index, :create] do
        collection do
          post :sync
        end
      end
      # The armed-merge roster — "what is armed right now, pinned to what,
      # expiring when". Read-only; arming is per-task (member routes below).
      resources :review_pending_actions, only: [:index]
      resources :agents, only: [:index, :show, :update], param: :slug
      # Stages move via PATCH update (task: { stage: ... }); no named-transition
      # endpoints — one path for the CLI, the board, and external callers.
      resources :tasks, only: [:index, :show, :create, :update, :destroy], param: :slug do
        collection do
          # The ATOMIC review pop (relocate-review-selection-to-server) — a COLLECTION
          # route (no slug: the server picks WHICH task). Claims the highest-ranked
          # reviewable GREEN-CI task in one transaction. Mirrors the per-task
          # review_claim member routes below, one decision up (the server chooses the
          # task instead of the caller naming it). CLI: `bin/task claim-next-review`.
          post "claim_next_review", to: "task_review_claims#claim_next"
        end
        member do
          # Record an INTENT — an agent STARTING a stage's work (review pair picked,
          # Steffon QA started, Avi ship e2e started) — so the board + task timeline
          # show who's on it with a live ticker before the transition lands.
          post :intent
          # Block is a `building` ATTRIBUTE, not a stage move — Task#block! stamps
          # the block columns and lands the task on building (no →blocked stage).
          patch :block
          post "review_events", to: "review_events#create", as: :review_events
          # Per-task REVIEW claim (per-task-pr-review-claim) — the review LANE's
          # per-task lease, so many pr-review sessions run in parallel and skip a
          # task already under live review. `review_claim` is the atomic
          # take-or-skip; `renew` the detached renewer's heartbeat; `release` the
          # clean review-end drop. Mirrors the role-lease (devops_shifts) one level
          # down. The submitted-and-unclaimed query is GET /tasks?reviewable=1.
          # The ARMED MERGE (autopilot-review-seam-execution) — a reviewer writes
          # down the merge-ready verdict it ALREADY recorded, so the merge finishes
          # executing after that reviewer's process ends. `create` arms (and is
          # refused unless a merge-ready scout report is on the record), `execute`
          # is the manual "run it now", `destroy` disarms. CLI: bin/review-autopilot.
          post   "review_pending_action", to: "review_pending_actions#create", as: :review_pending_action
          delete "review_pending_action", to: "review_pending_actions#destroy"
          post   "review_pending_action/execute", to: "review_pending_actions#execute",
                 as: :review_pending_action_execute
          get  "review_claim", to: "task_review_claims#show", as: :review_claim_status
          post "review_claim", to: "task_review_claims#acquire", as: :review_claim
          post "review_claim/renew", to: "task_review_claims#renew", as: :review_claim_renew
          post "review_claim/release", to: "task_review_claims#release", as: :review_claim_release
          post "events/:stage/start", to: "task_events#start", as: :event_start
          post "events/:stage/complete", to: "task_events#complete", as: :event_complete
          post "events/:stage/fail", to: "task_events#fail", as: :event_fail
        end
      end
      # Cross-release conductor-claim liveness (release-conductor-claims) — "is ANY
      # claim for this role live?" (NOT nested under a slug). bin/agent-worktree's
      # `_ship`/`_gate` reclaim guard asks `?role=deployer`: a live deployer claim means a
      # ship is in progress, so those fixed-path workspaces must not be reclaimed mid-ship.
      get "release_conductor_claims/live", to: "release_conductor_claims#live", as: :release_conductor_claims_live
      # The `backend_migration` exclusive lane (exclusive-lanes.md) — a SINGLETON,
      # not nested under a task: the lane is global and the holding task is a
      # property of the claim. CLI: `bin/task migration-lane acquire|release|status`.
      # These routes are the whole reason the lane is operable at all — it shipped
      # as a session advisory lock that no agent could reach (see MigrationLaneClaim).
      get  "migration_lane", to: "migration_lane_claims#show", as: :migration_lane
      post "migration_lane", to: "migration_lane_claims#acquire", as: :migration_lane_acquire
      post "migration_lane/release", to: "migration_lane_claims#release", as: :migration_lane_release
      resources :releases, only: [], param: :slug do
        member do
          post "events/:step/start", to: "release_events#start", as: :event_start
          post "events/:step/complete", to: "release_events#complete", as: :event_complete
          post "events/:step/fail", to: "release_events#fail", as: :event_fail
          # Per-RELEASE conductor claim (release-conductor-claims) — the assembler
          # (prepare/qa-release) and deployer (ship/production-deploy) locks live on
          # the RELEASE record now, not on a per-role devops shift, so a stale claim
          # can never strand a global lane: the lock turns over each release.
          # `conductor_claim` is the atomic take-or-stand-down; `renew` the detached
          # renewer's heartbeat; `release` the clean completion drop. Role travels in
          # the body/param. Mirrors the review lane's per-task claim one level over
          # (task → release, role).
          get  "conductor_claim", to: "release_conductor_claims#show", as: :conductor_claim_status
          post "conductor_claim", to: "release_conductor_claims#acquire", as: :conductor_claim
          post "conductor_claim/renew", to: "release_conductor_claims#renew", as: :conductor_claim_renew
          post "conductor_claim/release", to: "release_conductor_claims#release", as: :conductor_claim_release
          # OPERATOR-GATED force-reassign — hands a LIVE (release, role) claim to the
          # session asking without waiting out its TTL (release-conductor-claims).
          # Requires the operator secret on top of the bearer, so it is not an agent steal.
          post "conductor_claim/reassign", to: "release_conductor_claims#reassign", as: :conductor_claim_reassign
        end
      end
      # Gate-run markers — the branded testing gates (GateRun::GATES, G1 Cert …
      # G4 Ship). open/sops/close is the whole write surface; deterministic
      # markers, so NO usage gate here (see Api::V1::GateRunsController).
      scope "gates/:subject_type/:subject_slug", constraints: { subject_type: /task|release/ } do
        get  "",           to: "gate_runs#index",      as: :gate_runs
        post ":key/open",  to: "gate_runs#open",       as: :gate_run_open
        post ":key/sops",  to: "gate_runs#append_sop", as: :gate_run_sops
        post ":key/close", to: "gate_runs#close",      as: :gate_run_close
      end
      resources :activities, only: [:index, :create]
      resources :usages, only: [:index, :create]
      # Live-capture sink for the forward-only action log — the live-capture
      # hook POSTs one AgentAction per agent step. Best-effort: a capture miss
      # returns 204, never a 500 (telemetry must not break the work it observes).
      resources :agent_actions, only: [:create]
      resources :atomic_actions, only: [:create]
      # Agent-narration sink — the agent OPENs a meaningful activity
      # (category+reason) and CLOSEs it with a result; raw actions attribute to the
      # open activity.
      resources :agent_activities, only: [:create] do
        collection do
          post :close
          post :close_all
          post :turn_open # NEUTRALIZED (retire-turn-auto-open-spans) — 204 no-op; kept for the future meter
          # Fan-out token reconciliation (fan-out-token-attribution): `windows`
          # serves a session's activity windows to the local reconciler (which reads
          # the child subagents/*.jsonl transcripts the board can't see); `reconcile`
          # takes the computed per-activity usage back and stamps it.
          get  :windows
          post :reconcile
        end
      end
      # Compatibility path for existing capture/narration hooks.
      resources :atomic_events, only: [:create] do
        collection do
          post :close
          post :close_all
        end
      end
      # DevOps SHIFT lease (devops-shift-lease) — at most one live conductor per role
      # lane (avi/steffon/alex), so two same-role sessions can't collide. `acquire` is
      # the atomic take-or-stand-down, `renew` the heartbeat, `release` the clean
      # session-end drop; `index` is the "who's on shift" read.
      resources :devops_shifts, only: [:index] do
        collection do
          post :acquire
          post :renew
          post :release
        end
      end
      # Learning-loop grading — the bearer AGENT path for the Alex heartbeat
      # grade-events loop. `awaiting` lists resolved activities still ungraded by
      # Alex; `grade` upserts Alex's grade of one activity. The grader is FORCED to alex here
      # (the mcr audit-of-Alex stays admin-browser-only), so the shared agent token
      # can never forge McRitchie's audit.
      get  "agent_activities/awaiting_grade", to: "activity_grades#awaiting", as: :awaiting_grade_agent_activities
      post "agent_activities/:id/grade",      to: "activity_grades#create",   as: :grade_agent_activity
      get  "atomic_events/awaiting_grade", to: "event_grades#awaiting", as: :awaiting_grade_atomic_events
      post "atomic_events/:id/grade",      to: "event_grades#create",   as: :grade_atomic_event
      # Eagerly draw (or return) a session's Pokémon mascot before any task exists,
      # so a SessionStart hook can show it on the status line in seconds.
      post "sessions/:session_id/mascot", to: "sessions#mascot"
      # The learning loop's feed-forward READ path — the curated Insight Bank
      # (ActionGrade.banked) as a capped, newest-first list, so a SessionStart hook
      # can inject past sessions' lessons into a fresh agent's context.
      get "insights", to: "insights#index"
    end
  end
end
