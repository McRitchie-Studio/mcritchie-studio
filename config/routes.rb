Rails.application.routes.draw do
  mount ActionCable.server => "/cable"

  get "up" => "rails/health#show", as: :rails_health_check
  get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker
  get "manifest" => "rails/pwa#manifest", as: :pwa_manifest

  root "landing#index"
  get "terms",   to: "landing#terms",   as: :terms
  get "privacy", to: "landing#privacy", as: :privacy

  get "dashboard", to: "dashboard#index"
  get "toast_test", to: "toast_test#index"
  post "toast_test/flash", to: "toast_test#trigger_flash"
  resources :chat, only: [:index, :create]
  resources :schedule, only: [:index]

  Studio.routes(self)

  # TikTok OAuth handshake (one-time, admin-only) — visit /admin/tiktok/connect
  # to authorize @turfmonstershow and capture refresh_token + open_id.
  namespace :admin do
    get "tiktok/connect",  to: "tiktok#connect",  as: :tiktok_connect
    get "tiktok/callback", to: "tiktok#callback", as: :tiktok_callback

    # In-wallet Phantom signing module (admin-gated). Build + Mason-partial-sign
    # a turf-vault instruction server-side; the operator's Phantom adds the
    # second signature + broadcasts. v1 instruction = update_signers.
    get  "signing/:instruction",       to: "signing#show",  as: :signing
    post "signing/:instruction/build", to: "signing#build", as: :signing_build
    post "signing/:instruction/rpc",   to: "signing#rpc",   as: :signing_rpc
  end

  # HTML
  resources :agents, only: [:index, :show], param: :slug
  resources :tasks, param: :slug do
    collection do
      post :reorder
    end
    member do
      post :queue
      post :start
      post :complete
      post :fail_task
      post :archive
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
      resources :agents, only: [:index, :show, :update], param: :slug
      resources :tasks, only: [:index, :show, :create, :update, :destroy], param: :slug do
        member do
          post :queue
          post :start
          post :complete
          post :fail_task
          post :archive
        end
      end
      resources :activities, only: [:index, :create]
      resources :usages, only: [:index, :create]
    end
  end
end
