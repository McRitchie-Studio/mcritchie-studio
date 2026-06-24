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
  # Pokémon reference-data inspector — read-only grid of the seeded 151 (data
  # shape + bundled sprites). Public-read like the board pages.
  get "pokemon", to: "pokemon#index", as: :pokemon
  # Board split: /tasks is the Build lane, /deployments is the Deploy lane (+ the
  # current-release module), /stages is the two-workflow stage guide. All three
  # are public-read like /tasks (mutations stay admin-gated in TasksController).
  get "deployments", to: "tasks#deployments", as: :deployments
  get "stages", to: "tasks#stages", as: :stages
  # Public link hub — general (non-admin) destinations. The admin counterpart
  # lives at /admin/links (admin#links, require_admin). Both are surfaced from
  # the nav dropdown (Admin Links shows only to admins).
  get "links", to: "links#index", as: :links
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
  namespace :admin do
    get "dashboard", to: "dashboard#show", as: :dashboard
    get "models", to: "models#index", as: :models
    get "models/:key", to: "models#show", as: :model

    # Admin link hub — gathers every admin/operator destination (incl. the
    # on-chain Signing Console). admin#links, require_admin. /admin/links.
    get "links", to: "links#index", as: :links
    get "ai_builder_multiple", to: "ai_builder_multiple#index"
    get "ai_builder_multiple/commit_history", to: "ai_builder_multiple#commit_history", as: :ai_builder_multiple_commit_history

    get "tiktok/connect",  to: "tiktok#connect",  as: :tiktok_connect
    get "tiktok/callback", to: "tiktok#callback", as: :tiktok_callback

    # KEYLESS signing console — server is a pure coordinator (no keys). A
    # SigningRequest is built unsigned; each member signs in their own browser;
    # the assembled fully-signed tx is broadcast. Single-signer (initialize) +
    # multi-signer durable-nonce (update_signers).
    resources :signing_requests, only: %i[index new create show], param: :slug do
      member do
        get  :sign
        post :submit_signature
        post :broadcast
        post :rpc
      end
    end
  end

  # HTML
  resources :agents, only: [:index, :show], param: :slug
  resources :tasks, param: :slug do
    collection do
      post :reorder
    end
    member do
      # Stages move through PATCH update (one path shared by the board drag-drop,
      # bin/task, and the API). `comment` posts task-conversation activities.
      post :comment
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
  resources :activities, only: [:index]
  resources :usages, only: [:index]

  get "docs", to: "docs#index"
  get "docs/*path", to: "docs#show", as: :doc

  # JSON API
  namespace :api do
    namespace :v1 do
      post "auth", to: "auth#create"
      post "release_notes", to: "release_notes#create"
      resources :agents, only: [:index, :show, :update], param: :slug
      # Stages move via PATCH update (task: { stage: ... }); no named-transition
      # endpoints — one path for the CLI, the board, and external callers.
      resources :tasks, only: [:index, :show, :create, :update, :destroy], param: :slug do
        member do
          # Record an INTENT — an agent STARTING a stage's work (review pair picked,
          # Steffon QA started, Avi ship e2e started) — so the board + task timeline
          # show who's on it with a live ticker before the transition lands.
          post :intent
        end
      end
      resources :activities, only: [:index, :create]
      resources :usages, only: [:index, :create]
      # Eagerly draw (or return) a session's Pokémon mascot before any task exists,
      # so a SessionStart hook can show it on the status line in seconds.
      post "sessions/:session_id/mascot", to: "sessions#mascot"
    end
  end
end
