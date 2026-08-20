require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module McritchieStudio
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # `middleware` is ignored because config/initializers/edge_guard.rb requires it
    # explicitly to build the stack — a Zeitwerk-managed constant referenced at boot
    # would be loaded twice, once by the require and once by the autoloader.
    config.autoload_lib(ignore: %w[assets tasks middleware])

    # GZIP EVERY TEXT RESPONSE. Nothing in front of this app compresses — there is
    # no CDN (responses come back `via: heroku-router`, `server: Heroku`) and the
    # router does not do it for you. So /deployments was shipping 1,109,847 bytes of
    # HTML uncompressed on every view; the same body through gzip is 101,476 —
    # 10.9x smaller, measured on production 2026-08-19.
    #
    # Placed OUTSIDE Rack::ETag (which sits deep in the stack) so the ETag is still
    # computed over the uncompressed body and a conditional GET keeps working
    # regardless of what the client accepts. Deflater adds `Vary: Accept-Encoding`
    # itself, so a shared cache cannot hand a gzip body to a client that did not ask
    # for one. It no-ops on a client that sends no Accept-Encoding, and skips
    # already-encoded bodies, so images and fonts pass through untouched.
    #
    # ActionDispatch::Static is the insertion point rather than the very top: it
    # puts static files from public/ inside the compression too, and keeps
    # EdgeGuard/HostAuthorization — which reject requests outright — in front of the
    # work of compressing a response they were never going to send.
    require "rack/deflater"
    config.middleware.insert_after ActionDispatch::Static, Rack::Deflater

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
