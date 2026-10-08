Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  root "landing#index"
  get "terms",   to: "landing#terms",   as: :terms
  get "privacy", to: "landing#privacy", as: :privacy
  get "about",   to: "landing#about",   as: :about
  get "packages", to: "packages#index", as: :packages
  # The full stack behind every tier: the software-by-tier matrix /packages links to.
  get "packages/stack", to: "packages#stack", as: :packages_stack
  # The app funnel: prompt → sign in → claim <name>.mcritchie.studio → queued
  # for an agent. `check` is the live subdomain availability probe.
  get   "build",        to: "build#new",    as: :build
  post  "build",        to: "build#create"
  get   "build/check",  to: "build#check",  as: :build_check
  # Admin: every app requested through the funnel. Before build/:token, or
  # "requests" would be read as a token.
  get   "build/requests", to: "build#index", as: :build_requests
  get   "build/:token", to: "build#show",   as: :build_request
  patch "build/:token", to: "build#update"
  # The public contact form, which is also the SMS opt-in page carriers review.
  get  "contact", to: "contact_submissions#new", as: :contact_form
  # Both routes are named. An unnamed `post "contact"` is auto-named `contact`
  # and takes `contact_path` away from the mailing list's /contacts/:id.
  post "contact", to: "contact_submissions#create", as: :contact_form_submit
  # Credential RECORDS by client workspace, with each workspace's 1Password
  # vault icon. Admin-only; no secret is ever stored or shown.
  get "credentials", to: "credential_vaults#index", as: :credentials
  # Every client's stack: tier, software (Studio chest when we host it), Google
  # users, Resend. Admin-only.
  get "stack", to: "stack#index", as: :stack
  # The same clients as a matrix: clients across, software down by category,
  # a tier/price/hosting band on top and the total MRR. Admin-only.
  get "stack/matrix", to: "stack#matrix", as: :stack_matrix

  # Broadcast emails — table view + editor. `preview` renders the email itself
  # (in the email shell) for the editor's live iframe.
  # Email analytics dashboard (before the resource, so "analytics" is not an id).
  get "broadcasts/analytics", to: "broadcast_analytics#show", as: :broadcast_analytics
  resources :broadcasts, only: %i[index edit update] do
    member do
      get  :preview
      post :deliver
    end
    # The staged email queue (task staged-email-queue): emails rendered and
    # held, then approved, then sent. /broadcasts/:broadcast_id/queue
    resource :queue, only: :show, controller: "broadcast_queues" do
      post :stage
      post :approve
      post :cancel
      post :execute
      get  "emails/:email_id/preview", action: :preview, as: :preview
      post "emails/:email_id/restage", action: :restage, as: :restage
    end
  end

  # The mailing list, watched live (admin). `stats` is the polled stats frame.
  get "contacts/stats", to: "contacts#stats", as: :contacts_stats
  resources :contacts, only: %i[index show]

  # One-click-safe unsubscribe: GET shows an inert confirm page, POST unsubscribes.
  get  "unsubscribe/:token", to: "unsubscribes#show",   as: :unsubscribe
  post "unsubscribe/:token", to: "unsubscribes#create"
  post "unsubscribe/:token/resubscribe", to: "unsubscribes#resubscribe", as: :resubscribe

  # Email engagement tracking (open pixel + click redirect), keyed by delivery token.
  get "e/o/:token", to: "email_tracking#open",  as: :email_open
  get "e/c/:token", to: "email_tracking#click", as: :email_click
  get "e/g/:token", to: "email_tracking#goal",  as: :email_goal

  get "dashboard", to: "dashboard#index"
  # Task-development trends dashboard (stage speed, cycle time, tokens, cost,
  # estimate-vs-actual). Admin-only like the other board surfaces (AdminWall).
  get "intelligence", to: "intelligence#index", as: :intelligence
  # Pokédex — read-only spawn/activity surface for session mascots.
  get "pokedex", to: "pokemon#index", as: :pokedex
  # Board split: /tasks is the Build lane, /deployments is the Deploy lane (+ the
  # current-release module), /stages is the two-workflow stage guide. All three
  # are admin-only, reads included (AdminWall).
  # The findings TRIAGE inbox — agent follow-ups wait here for an operator call.
  # Admin-only like the boards (AdminWall); promote MINTS a task
  # (the operator's lane, mirrored by the API's file/list-only split).
  get "triage", to: "triage#index", as: :triage
  post "triage/:slug/promote", to: "triage#promote", as: :promote_triage_finding
  post "triage/:slug/dismiss", to: "triage#dismiss", as: :dismiss_triage_finding
  get "deployments", to: "tasks#deployments", as: :deployments
  # THE MODEL PIPELINE BOARD — every character model in flight across five lanes
  # (designed → defined → source → model → generation), admin-only like the boards
  # above (AdminWall), reads and writes alike.
  #
  # NOT `/models`. `Studio.routes` already draws the model-page protocol at
  # `/models/:model/:id` and `/models/:model/random` (see
  # config/initializers/model_pages.rb), and `namespace :admin` draws `/admin/models`
  # for the LLM roster — a third meaning of the same word is how a reader ends up on
  # the wrong page.
  get "model_pipeline", to: "model_pipeline#index", as: :model_pipeline
  post "model_pipeline/reorder", to: "model_pipeline#reorder", as: :reorder_model_pipeline
  patch "model_pipeline/:slug", to: "model_pipeline#update", as: :model_pipeline_look
  # The epic view: every epic with its progress by stage, and one epic's tasks
  # grouped by stage on the board's own card (EpicsController, admin-only).
  get "epics", to: "epics#index", as: :epics
  get "epics/:slug", to: "epics#show", as: :epic
  get "deployments/all", to: "releases#index", as: :all_deployments
  get "deployments/:slug", to: "releases#show", as: :deployment
  # The operator's production-authority GRANT (design section 6): the Approve
  # button on the Next Release card posts here while a timed `bin/release ship`
  # waits on its window. Admin-gated in ReleasesController; records the one
  # `ship_authorized completed` event through Release#grant_ship_authorization!.
  post "deployments/:slug/ship_authorization", to: "releases#authorize_ship", as: :authorize_ship_deployment
  # The operator's answer to an admin login request (the board's Approve and Decline).
  post "agent_logins/:slug/approve", to: "agent_login_requests#approve", as: :approve_agent_login
  post "agent_logins/:slug/refuse", to: "agent_login_requests#refuse", as: :refuse_agent_login
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
  # /communications — the communications record (who said what, what was asked).
  # Short path by operator preference; admin-gated in the controller because the
  # page renders deal correspondence.
  get "communications", to: "communications#index", as: :communications

  # Email header briefs (EmailImagesController, require_admin): a brief, its
  # generated candidates, approve/retire, and a preview inside the real email
  # shell. Epic email-image-builder, piece 1.
  # THE CAST (CharactersController, require_admin): our fictional characters —
  # mascots and puppets — with their looks and every image they appear in.
  # Epic email-image-builder, addendum "Characters", piece A.
  resources :characters, param: :slug, only: %i[index show new create edit update] do
    member do
      post :looks, action: :create_look
    end
  end
  post "characters/:slug/looks/:look_slug/art", to: "characters#upload_art", as: :character_look_art
  post "characters/:slug/looks/:look_slug/default", to: "characters#make_default", as: :default_character_look
  post "characters/:slug/looks/:look_slug/sheet", to: "characters#build_sheet", as: :character_look_sheet

  # Email brand kits (EmailBrandKitsController, require_admin): each kit's base
  # assets, its approved headers and open briefs, and the uploaded references.
  # Declared BEFORE resources :email_images, whose show route would otherwise
  # read "brand_kits" as a brief slug. Task email-brand-asset-page.
  # The generator page (task email-image-generator-page): character model,
  # examples and the copy-paste SOP prompt. Also declared before the resources.
  get "email_images/generator", to: "email_image_generators#index", as: :email_image_generators
  get "email_images/generator/:kit", to: "email_image_generators#show", as: :email_image_generator
  get "email_images/brand_kits", to: "email_brand_kits#index", as: :email_brand_kits
  get "email_images/brand_kits/:kit", to: "email_brand_kits#show", as: :email_brand_kit
  post "email_images/brand_kits/:kit/references", to: "email_brand_kits#create_reference",
                                                  as: :email_brand_kit_references
  post "email_images/brand_kits/:kit/references/:slug/archive", to: "email_brand_kits#archive_reference",
                                                                as: :archive_email_brand_kit_reference
  resources :email_images, param: :slug, only: %i[index create show update] do
    member do
      post :generate
      get :preview
      post "candidates/:artifact_slug/approve", action: :approve, as: :approve_candidate
      post "candidates/:artifact_slug/retire", action: :retire, as: :retire_candidate
    end
  end
  # /assets — the object store as a folder tree (AssetsController, require_admin).
  # Query params only: Sprockets owns /assets/*, and cascades /assets itself here.
  get "assets", to: "assets#index", as: :asset_browser
  # Music video pipeline: the cast panel (stage 2) and clips (stage 5), admin only.
  get "artists/search", to: "artists#search", as: :search_artists
  get "recast_athletes/search", to: "recast_athletes#search", as: :search_recast_athletes
  # One person's look dropdown rows, polled by a cast card while a sheet builds.
  get "recast_athletes/:slug/looks", to: "recast_athletes#looks", as: :recast_athlete_looks
  # Every alt video across every source, with its clip progress.
  get "alt_videos", to: "alt_videos#index", as: :alt_videos
  resources :music_videos, only: [:show], param: :slug do
    post :confirm_cast, on: :member
    resources :performers, only: [:update], param: :ordinal, controller: "video_performers" do
      # Who replaces this performer: an athlete and a look, keep as is, or clear.
      resource :recast, only: [:update], controller: "video_performer_recasts"
      # "Generate a new look" on the card: a look for the athlete, and its sheet build.
      resources :recast_looks, only: [:create], controller: "video_performer_recast_looks"
    end
    resources :clips, only: [:update], param: :ordinal, controller: "video_clips"
    # Alt videos (recast pipeline, piece 13): Build Clips makes the next one from
    # the cast card's swaps; its page is the clip builder. Each clip (alt video x
    # chunk) takes uploaded versions, one primary, and a regenerate flag.
    resources :alt_videos, only: [:create, :show], param: :number do
      # The page's signed URLs again, as JSON: it outlives the fifteen minutes they last.
      get :links, on: :member, defaults: { format: :json }
      # The asset zips (piece 17): every clip's hand-off, or one clip's, streamed.
      resource :download, only: [:show], controller: "alt_video_downloads"
      resources :clips, only: [], param: :ordinal do
        resource :download, only: [:show], controller: "alt_video_downloads"
        resources :versions, only: [:create], param: :number, controller: "alt_video_clip_versions" do
          post :primary, on: :member
        end
        resource :regenerate, only: [:create, :destroy], controller: "alt_video_clip_regenerates"
        # Draft to TikTok (piece 19): the primary version into the operator's
        # TikTok drafts; refresh reads TikTok's status once more.
        resources :tiktok_drafts, only: [:create], controller: "alt_video_clip_tiktok_drafts" do
          post :refresh, on: :member
        end
      end
      # The final stitch: "Generate full video" records a request; show answers
      # its state as JSON for the page's progress poll.
      resources :stitches, only: [:create, :show], param: :number, controller: "alt_video_stitches"
    end
    resources :looks, only: [:create], param: :look_slug, controller: "music_video_looks" do
      post :sheet, on: :member
    end
  end

  # Public link hub — general (non-admin) destinations. The admin counterpart
  # lives at /admin/links (admin#links, require_admin). Both are surfaced from
  # the nav dropdown (Admin Links shows only to admins).
  get "links", to: "links#index", as: :links

  # Session entry launcher — terminal-styled chooser for the avenue you enter a
  # session as (Session agent · Avi · Xan). Selecting Xan routes to the learning
  # heartbeat at /xan/heartbeat, the per-action atomic trajectory table
  # (HeartbeatController#show). The named route (xan_heartbeat_path) is stable, so
  # the launcher anchor follows it; it was repointed off LauncherController's
  # placeholder once the real view (T2) landed.
  get "launcher", to: "launcher#index", as: :launcher
  get "xan/heartbeat", to: "heartbeat#show", as: :xan_heartbeat
  # Feedback layer over the read-only trajectory (T5): a per-action grading drawer
  # (GET, lazy-loaded into a turbo-frame), the upsert/bank/discard write, and the
  # curated Insight Bank page. Like the view itself, this is an open meta surface.
  get  "xan/heartbeat/actions/:id/feedback", to: "heartbeat#feedback", as: :heartbeat_feedback
  post "xan/heartbeat/actions/:id/grade",    to: "heartbeat#grade",    as: :heartbeat_grade
  # Activity-level grade: upsert one grade for a narrated AgentActivity. JSON only
  # by design so it stays view-free from the drawer/turbo stream path.
  post "xan/heartbeat/activities/:id/grade", to: "heartbeat#grade_activity", as: :heartbeat_activity_grade
  # The per-activity grading drawer body, lazy-loaded into the shared turbo-frame
  # on an activity's grade click.
  get  "xan/heartbeat/activities/:id/feedback", to: "heartbeat#feedback_activity", as: :heartbeat_activity_feedback
  # Every AgentActivity across ALL sessions, newest-first, paginated 100/page —
  # the cross-session analogue of the per-session heartbeat.
  get  "xan/heartbeat/activities", to: "heartbeat#all_activities", as: :heartbeat_all_activities
  get  "xan/insights", to: "heartbeat#insights", as: :xan_insights
  # The OPSD distillation pipeline, left→right: Activities → Insights (Xan's
  # grades) → Confirmations (McRitchie's mcr grades). `confirm` records the McRitchie
  # (mcr) confirmation of an insight and redirects back (a no-JS form action).
  get  "xan/pipeline", to: "heartbeat#pipeline", as: :xan_pipeline
  post "xan/pipeline/confirm/:id", to: "heartbeat#confirm", as: :xan_pipeline_confirm

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
  # Delivery, bounce, complaint and engagement events for broadcast email.
  post "webhooks/resend/events", to: "webhooks/resend_events#create"

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

    # Admin link hub — gathers every admin/operator destination. It lists no
    # on-chain destination: the signing console was deleted 2026-09-04
    # (/tasks/retire-signing-console). admin#links, require_admin. /admin/links.
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
      # gate verdicts per task. Admin-only like the board; declared on the
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
      # The rapper-replace inspection gate: confirm the jersey, attach each of
      # the three artifacts, then approve. Approval is what unlocks video.
      post :set_colorway
      post :attach_artifact
      post :approve_artifacts
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
      # Video Post (X): redraft the copy, publish, and settle a run that died.
      post :draft_x_copy
      post :post_video_to_x
      post :resolve_x_post
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
  # DECLARED BEFORE the :show member route below. Adding `:show` draws
  # GET /people/:slug, which matches "search" as a slug and 404s through
  # find_by! — silently breaking the person picker in news/edit and
  # people/merge. Route order is the fix; a literal must precede its wildcard.
  get "people/search", to: "people#search", as: :search_people

  resources :people, only: [:index, :show], param: :slug do
    collection do
      get :merge
      post :merge, action: :merge_execute
      get :duplicates
    end
    member do
      # The model library: a person's looks, and the images made of them.
      # Admin only, all three (hub signup is open; a session is no gate).
      post :create_appearance
      # One look's jersey number (the number clip prompts name the player by).
      patch :update_appearance
      # A free row: the iced-out twin of a look made before twins existed.
      post :create_iced_twin
      post :make_default_appearance
      post :attach_artifact
      # What this person does: many vocations, one primary. Admin only.
      patch :vocations, action: :update_vocations
      # The person's slug, renamed with every row that names it. Admin only.
      get :slug, action: :edit_slug, as: :edit_slug
      patch :slug, action: :update_slug
    end
    # What the person wears, for the iced-out sheet (PersonJewelry). Admin only.
    resources :jewelries, only: [:create, :update, :destroy], param: :jewelry_slug, controller: "person_jewelries"

    # ONE LOOK'S CHARACTER MODEL. Nested because a look has no meaning without its
    # person, and PATHED as "models" because that is the word the person page and
    # the operator both use for a look — `/people/drew-lock/models/look-abc123`.
    #
    # #show is a free read and is PUBLIC, like the person page it is reached from.
    # The other three POSTs sit behind `require_admin`, NOT merely behind a session:
    # #search buys one image-search query plus up to VISION_SHORTLIST vision
    # classifications, #mint buys one character identity, and #refresh is free but
    # fails as invisibly as either. Hub signup is OPEN, so a session costs a member of
    # the public one email address and is no control at all over a paid endpoint.
    # AppearancesController carries the full argument.
    resources :appearances, path: "models", param: :slug, only: [:show] do
      member do
        post :search
        post :mint
        post :refresh
        # #generate BUYS ONE IMAGE from a zero-shot identity adapter — one
        # headshot in, one picture out, no training step and therefore no
        # character model required. Behind `require_admin` with the other two
        # spenders, for the reason spelled out above: hub signup is open, so a
        # session is no control over a paid endpoint.
        post :generate
      end
    end

    # THE PHOTO SCOUTING PAGE — what the search found, what the ranker picked, and
    # what the operator would have picked instead.
    #
    # PER-PERSON RATHER THAN PER-LOOK, and SINGULAR for that reason: the question it
    # answers ("are we any good at finding photographs of this man?") is about the
    # person, so `/people/drew-lock/scouting` is the whole address. It resolves the
    # person's default look to search against, because the photographs are filed per
    # look and a page that made the operator pick a look first would be asking him
    # about a distinction he was not thinking about.
    #
    # #show IS PUBLIC, matching the person page and the model page it sits beside.
    # #search and #verdict are behind `require_admin` — #search because it buys a
    # query plus up to VISION_SHORTLIST classifications, and #verdict because it
    # writes the OPERATOR's taste, which is the one signal a future ranking change
    # would be measured against. Hub signup is open, so a session is not a control
    # over either. PhotoScoutingController carries the argument.
    resource :scouting, controller: "photo_scouting", only: [:show] do
      post :search
      post :verdict
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
  resources :usages, only: [:index]

  get "docs", to: "docs#index"
  get "docs/*path", to: "docs#show", as: :doc

  # JSON API
  namespace :api do
    namespace :v1 do
      post "auth", to: "auth#create"
      # Agent logins (agent-sessions phase one): a studio session at a task claim,
      # whoami, and log out. Api::V1::AgentSessionsController.
      post   "agent_sessions", to: "agent_sessions#create"
      get    "agent_sessions/current", to: "agent_sessions#show"
      delete "agent_sessions/current", to: "agent_sessions#destroy"
      post   "agent_login_requests", to: "agent_login_requests#create"
      post   "agent_login_requests/:slug/code", to: "agent_login_requests#code"
      post   "agent_login_requests/:slug/collect", to: "agent_login_requests#collect"
      post "release_notes", to: "release_notes#create"
      # Finished-game push from turf-monster (Nfl::LiveScores::PollCycle#finalise).
      # Creates the Content idea a faceless recap video is built from. Idempotent:
      # 201 when this call created the recap, 200 when it already existed.
      post "game_recaps", to: "game_recaps#create"
      # Facts about a person, a company or an app (agent sessions only).
      resources :facts, only: [:index, :create], param: :slug do
        member do
          post :supersede
          post :retire
        end
      end
      # Rename one record's slug with every row that names it (admin sessions).
      patch "slugs/:kind/:slug", to: "slug_renames#update", as: :slug_rename
      # The person/athlete projection turf-monster syncs from. Read-only by
      # design: MS masters durable facts, TM masters events, and neither writes
      # into the other's master.
      resources :athletes, only: [:index]
      # Written by bin/digest-video (stage 1), the cast vision pass (stage 2), bin/find-clips (stage 5),
      # bin/clip-references (lettered frames) and bin/stitch-video (the final stitch).
      resources :music_videos, only: [:show, :create], param: :slug do
        post :performers, on: :member
        post :clips, on: :member
        # A chunk's lettered reference frames, as bin/clip-references --apply posts them.
        resources :chunks, only: [], param: :ordinal do
          resource :references, only: [:create], controller: "music_video_chunk_references"
        end
        # The final stitch of an alt video, as bin/stitch-video drives it: read
        # the requests, open one, then report it started, finished or failed.
        resources :alt_videos, only: [], param: :number do
          resources :stitches, only: [:index, :create], param: :number, controller: "music_video_stitches" do
            member do
              post :start
              post :finish
              post :failed
            end
          end
        end
      end
      # The tiktok-draft SOP's chat door (piece 19), as bin/tiktok-draft drives it:
      # a clip by its slug, what a draft would send, its attempts, and the probe.
      resources :alt_video_clips, only: [], param: :slug do
        resources :tiktok_drafts, only: [:index, :create]
      end
      resources :tiktok_drafts, only: [] do
        post :refresh, on: :member
      end
      get "tiktok/creator_info", to: "tiktok_drafts#creator_info"
      # The content pipeline's AGENT surface. Non-deterministic steps (the take,
      # the scenes, the caption) are written by a soul during an SOP with its own
      # inference, so production needs no model key. `claim_next` is the atomic
      # pop — the SERVER picks which content — mirroring claim_next_review above.
      resources :contents, only: [:index, :show, :update], param: :slug do
        collection do
          post :claim_next
          post :record_x_post
        end
        member do
          post :release
          post :posted
        end
      end
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
          # Clears a live block (Task#unblock!); `bin/task begin` on a blocked task calls it.
          patch :unblock
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
      # Gate-run markers — the branded testing gates (GateRun::GATES, DoR …
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
      # DevOps SHIFT lease (devops-shift-lease) — at most one live conductor per role
      # lane (avi/steffon/xan), so two same-role sessions can't collide. `acquire` is
      # the atomic take-or-stand-down, `renew` the heartbeat, `release` the clean
      # session-end drop; `index` is the "who's on shift" read.
      resources :devops_shifts, only: [:index] do
        collection do
          post :acquire
          post :renew
          post :release
        end
      end
      # Learning-loop grading — the bearer AGENT path for the Xan heartbeat
      # grade-events loop. `awaiting` lists resolved activities still ungraded by
      # Xan; `grade` upserts Xan's grade of one activity. The grader is FORCED to xan here
      # (the mcr audit-of-Xan stays admin-browser-only), so the shared agent token
      # can never forge McRitchie's audit.
      get  "agent_activities/awaiting_grade", to: "activity_grades#awaiting", as: :awaiting_grade_agent_activities
      post "agent_activities/:id/grade",      to: "activity_grades#create",   as: :grade_agent_activity
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
