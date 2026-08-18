require "active_support/core_ext/integer/time"

# The test environment is used exclusively to run your application's
# test suite. You never need to work with it otherwise. Remember that
# your test database is "scratch space" for the test suite and is wiped
# and recreated between test runs. Don't rely on the data there!

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # While tests run files are not watched, reloading is not necessary.
  config.enable_reloading = false

  # Eager loading loads your entire application. When running a single test locally,
  # this is usually not necessary, and can slow down your test suite. However, it's
  # recommended that you enable it in continuous integration systems to ensure eager
  # loading is working properly before deploying your code.
  config.eager_load = ENV["CI"].present?

  # Configure public file server for tests with Cache-Control for performance.
  config.public_file_server.headers = { "Cache-Control" => "public, max-age=#{1.hour.to_i}" }

  # Show full error reports and disable caching.
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.cache_store = :null_store

  # Render exception templates for rescuable exceptions and raise for other exceptions.
  config.action_dispatch.show_exceptions = :rescuable

  # Disable request forgery protection in test environment.
  config.action_controller.allow_forgery_protection = false

  # Store uploaded files on the local file system in a temporary directory.
  config.active_storage.service = :test

  # Disable caching for Action Mailer templates even if Action Controller
  # caching is enabled.
  config.action_mailer.perform_caching = false

  # Tell Action Mailer not to deliver emails to the real world.
  # The :test delivery method accumulates sent emails in the
  # ActionMailer::Base.deliveries array.
  config.action_mailer.delivery_method = :test

  # Unlike controllers, the mailer instance doesn't have any context about the
  # incoming request so you'll need to provide the :host parameter yourself.
  config.action_mailer.default_url_options = { host: "www.example.com" }

  # Print deprecation notices to the stderr.
  config.active_support.deprecation = :stderr

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Raise error when a before_action's only/except options reference missing actions.
  config.action_controller.raise_on_missing_callback_actions = true

  # BCRYPT AT ITS MINIMUM COST, FOR THE WHOLE TEST PROCESS.
  #
  # bcrypt is deliberately slow, and the default cost (12) costs ~272ms PER HASH on
  # this hardware. test/fixtures/users.yml mints two through ERB, so every fixture
  # LOAD spends ~544ms hashing passwords no test asserts anything about. Fixtures
  # reload once per process, once per parallel CI worker, and again for every
  # non-transactional test (`invalidate_already_loaded_fixtures`) — 16 such cases
  # here. Measured: ~9s a local run, ~11s on CI's four workers.
  #
  # SET ON THE ENGINE, because the Rails knob cannot reach the call that costs us.
  # `ActiveModel::Railtie` already runs `SecurePassword.min_cost = Rails.env.test?`,
  # so `has_secure_password` has ALWAYS hashed cheaply here — that path needed
  # nothing. But `min_cost` is read only by `has_secure_password`; the fixture's bare
  # `BCrypt::Password.create(...)` reads `BCrypt::Engine.cost` and is unaffected.
  # Measured: with `min_cost = true`, a bare create still returns a cost-12 hash.
  # Setting the engine covers that path, and any future direct call site for free —
  # which a fixture-local `cost:` argument would not.
  #
  # (Note `config.active_record.bcrypt_cost` does not exist in Rails 8.1. It reads
  # like the obvious knob and would have been an inert config line.)
  BCrypt::Engine.cost = BCrypt::Engine::MIN_COST
end
