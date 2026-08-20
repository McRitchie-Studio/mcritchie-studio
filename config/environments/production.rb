require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot. This eager loads most of Rails and
  # your application in memory, allowing both threaded web servers
  # and those relying on copy on write to perform better.
  # Rake tasks automatically ignore this option for performance.
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local = false
  config.action_controller.perform_caching = true

  # Ensures that a master key has been made available in ENV["RAILS_MASTER_KEY"], config/master.key, or an environment
  # key such as config/credentials/production.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Disable serving static files from `public/`, relying on NGINX/Apache to do so instead.
  # config.public_file_server.enabled = false

  # CACHE WHAT WE SERVE OURSELVES. Files under public/ went out with no
  # Cache-Control at all — only Last-Modified — so every visit re-fetched or
  # re-validated the agent portraits, and a cold load pulled 7.4MB of them.
  #
  # A WEEK, not a year, because this header covers BOTH kinds of file here:
  # fingerprinted /assets/* (whose name changes on every edit, so they could safely
  # be immutable) and unfingerprinted /agents/*.png (whose name does NOT change, so
  # a year-long TTL would pin a replaced portrait in browsers for a year). A week is
  # the longest window worth the staleness on the second kind; fingerprinted assets
  # give up nothing that matters at this traffic. Fingerprint the portraits and this
  # can go immutable.
  config.public_file_server.headers = { "cache-control" => "public, max-age=604800" }

  # Compress CSS using a preprocessor.
  # config.assets.css_compressor = :sass

  # Do not fall back to assets pipeline if a precompiled asset is missed.
  config.assets.compile = false

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Specifies the header that your server uses for sending files.
  # config.action_dispatch.x_sendfile_header = "X-Sendfile" # for Apache
  # config.action_dispatch.x_sendfile_header = "X-Accel-Redirect" # for NGINX

  # Store uploaded files on S3 in production (see config/storage.yml for options).
  config.active_storage.service = :amazon

  # Mount Action Cable outside main process or domain.
  # config.action_cable.mount_path = nil
  # config.action_cable.url = "wss://example.com/cable"
  # config.action_cable.allowed_request_origins = [ "http://example.com", /http:\/\/example.*/ ]

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # Can be used together with config.force_ssl for Strict-Transport-Security and secure cookies.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # "info" includes generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). If you
  # want to log everything, set the level to "debug".
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Use a different cache store in production.
  # config.cache_store = :mem_cache_store

  # Background jobs run through Solid Queue so enqueued mail/auth work survives
  # web dyno restarts. Keep at least one worker dyno scaled in production.
  config.active_job.queue_adapter = :solid_queue

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # APP_HOST is the canonical public hostname for this deployment. Production
  # defaults to the public app host; QA/staging apps set APP_HOST explicitly so
  # magic links and host authorization point at the QA server.
  app_host = ENV.fetch("APP_HOST", "mcritchie.studio")
  mailer_host = ENV.fetch("MAILER_HOST", app_host)
  app_host_aliases = ENV.fetch("APP_HOST_ALIASES", "")
    .split(",")
    .map(&:strip)
    .reject(&:empty?)

  # Required by the magic-link mailer: UserMailer#magic_link builds an absolute
  # URL via magic_link_url(token:), which needs a host. Without this, every
  # magic-link send raises "Missing host to link to" in production.
  config.action_mailer.default_url_options = { host: mailer_host, protocol: "https" }

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Prelaunch audit C4 (2026-05-24): enable DNS-rebinding + Host-header
  # protection. Without this, Rails 7 accepts any Host header, which lets
  # attackers reach the SSO hub under a foreign origin's cookie scope and
  # replay against the dyno's direct *.herokuapp.com URL (bypassing CDN/WAF
  # allowlists). Especially critical here since this app is the SSO hub.
  config.hosts = [
    app_host,                                                # primary public URL for this deploy target
    ENV.fetch("DYNO_HOST", "mcritchie-studio.herokuapp.com"), # direct Heroku dyno URL (health checks, etc.)
    *app_host_aliases
  ].uniq
  # /up is the Rails health-check endpoint Heroku polls — Heroku's load balancer
  # may use internal addressing, so exclude it from host authorization to avoid
  # false-positive health-check failures.
  config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
