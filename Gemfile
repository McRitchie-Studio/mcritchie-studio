source "https://rubygems.org"

ruby "3.3.11"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1"
# The original asset pipeline for Rails [https://github.com/rails/sprockets-rails]
gem "sprockets-rails"
# Use postgresql as the database for Active Record
gem "pg", "~> 1.1"
# Durable Active Job backend for production worker dynos.
gem "solid_queue", "~> 1.4"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Redis adapter to run Action Cable in production
# gem "redis", ">= 4.0.1"

# Use Kredis to get higher-level data types in Redis [https://github.com/rails/kredis]
# gem "kredis"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
gem "bcrypt", "~> 3.1.7"

gem "omniauth"
gem "omniauth-google-oauth2"
gem "omniauth-rails_csrf_protection"

# Rate limiting (prelaunch audit H6 — SSO hub brute-force prevention)
gem "rack-attack"

# Pure-Ruby Solana primitives (Borsh encode / PDA derivation / keypair / tx
# build + partial-sign). Powers the admin signing console + durable-nonce
# primitives. Same gem turf-monster uses.
gem "solana-studio", "~> 0.4.7"

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ mswin mswin64 mingw x64_mingw jruby ]

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"
gem "aws-sdk-s3", require: false

# Charts for the /intelligence task-development trends dashboard. Chartkick
# renders Chart.js (pinned via importmap, no build step); Groupdate powers the
# time-series (group_by_week) trend aggregations.
gem "chartkick"
gem "groupdate"

group :development, :test do
  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri mswin mswin64 mingw x64_mingw ], require: "debug/prelude"

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"
end

group :test do
  # Use system testing [https://guides.rubyonrails.org/testing.html#system-testing]
  gem "capybara"
  gem "selenium-webdriver"
  # minitest 6.0 dropped minitest/mock (Object#stub / Minitest::Mock); the suite
  # relies on Object#stub. Rails only needs >= 5.15, so pin to the 5.x line.
  gem "minitest", "~> 5.25"
end
gem "dotenv-rails", groups: [:development, :test]
gem "redcarpet"
gem "tailwindcss-rails", "~> 4.5"
# Sentry — production error monitoring. ErrorLog.capture! fans out to Sentry
# when SENTRY_DSN env var is set. No-op if absent.
gem "sentry-ruby"
gem "sentry-rails"

gem "studio-engine", "~> 0.26" # 0.26.1 fixes the /admin/style Turbo-nav modal store: dsModals re-registers on a Turbo visit, so the sidebar-nav to Design System opens modals and fails glows closed; 0.26.0 self-pins the navbar under the smooth-load convention (engine-navbar-self-pins); 0.25 rebuilds Profile Leveling on /admin/style: per-card leveling toggles with modal ids change-username + join-newsletter (the updated state opens the same id with celebrate: true), replacing the old -plain demo fork; 0.24 ships the smooth-load convention (layouts/studio/smooth_load, engine.css view transitions, vt-pinned-header @utility, Studio.smooth_load + nav_spinner_min_ms — this app's initializer calls those accessors, so 0.24 is the floor); 0.23 ships the board primitive; 0.22 ships the confetti/pulse Tricks (window.studioConfetti + .pulse-cta) + the leveling-activity modal primitives (change-username + quest; render leveling-OFF for MS); 0.19 ships the dev-only /_studio/local_review mint endpoint (the local half of the board WAITING APPROVAL button); 0.18 ships the full /admin/style page (Theme·Modals·Tricks·Tasks) + engine-motion; 0.13 ships engine component CSS + de-forked modal/user-nav primitives; 0.12 added the model-page protocol (Studio::ModelPage)
