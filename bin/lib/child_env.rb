# frozen_string_literal: true

# The environment a long-lived child process starts with, as an ALLOW-LIST.
#
# WHY (secrets-never-on-argv-or-desk-env, 2026-10-24). Desk servers inherited the
# agent shell's whole environment: HEROKU_API_KEY, OP_SERVICE_ACCOUNT_TOKEN,
# CLAUDE_CODE_*, AGENT_API_SECRET and the rest. Puma and Sidekiq rename their
# process titles, and on macOS `pgrep -fl` and `ps` then print the process's
# environment after the title, so one `pgrep -fl puma` put HEROKU_API_KEY into an
# agent transcript and the key had to be rotated. A server needs none of those
# names, so it gets none of them.
#
# An allow-list, not a deny-list: a deny-list misses the name somebody exports
# next week (see AgentMailbox::CHILD_ENV_ALLOW, the dispatcher's own list, which
# shares SYSTEM_ALLOW below). FORBIDDEN is a second fence, applied even to values
# a caller passes in explicitly, so a desk's stack file can never carry one of
# these names into a server either.
#
# Apply the result with `unsetenv_others: true`; without it Process.spawn MERGES
# the hash over the parent's environment and the allow-list does nothing.
module ChildEnv
  # The names any child process needs to behave like a normal login session.
  SYSTEM_ALLOW = %w[
    PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM TZ __CF_USER_TEXT_ENCODING
    GEM_HOME GEM_PATH
  ].freeze

  # What a Rails desk server (web, Sidekiq, the bin/tm wrapper) additionally reads
  # from its parent. The desk's own stack values (PORT, APP_PORT, DATABASE_URL,
  # REDIS_URL, TM_*, LOCAL_EMAIL_CAPTURE, ...) are passed explicitly by the
  # launcher and need not be listed; these are the ones a person may export.
  DESK_SERVER_ALLOW = %w[
    BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_WITHOUT
    RAILS_ENV RACK_ENV RAILS_LOG_TO_STDOUT RAILS_MAX_THREADS WEB_CONCURRENCY
    PORT APP_PORT DATABASE_URL TEST_DATABASE_URL REDIS_URL
    TM_PORT TM_REDIS_DB TM_STRIPE_LISTENER
    PGHOST PGPORT PGUSER
    BINDING PAYMENT_PROVIDER
    OBJC_DISABLE_INITIALIZE_FORK_SAFETY SCREENDIR
  ].freeze

  # Feature flags an operator sets on the command line for one boot
  # (`ENABLE_FIAT_RAILS=true … bin/tm up`, docs in turf-monster LOCAL_STACK.md).
  # Flags, never credentials; FORBIDDEN still applies.
  DESK_SERVER_ALLOW_PREFIXES = %w[ENABLE_].freeze

  # Never in a desk server's environment, whoever asks.
  FORBIDDEN_NAMES = %w[GH_TOKEN GITHUB_TOKEN AGENT_LEGACY_TOKEN].freeze
  FORBIDDEN_PREFIXES = %w[HEROKU_ OP_ CLAUDE_CODE_ ANTHROPIC_ AGENT_API_].freeze

  module_function

  def forbidden?(name)
    FORBIDDEN_NAMES.include?(name) || FORBIDDEN_PREFIXES.any? { |prefix| name.start_with?(prefix) }
  end

  # The allow-listed subset of `env`.
  def allowed(env, allow)
    allow.each_with_object({}) { |name, kept| kept[name] = env[name] if env.key?(name) }
  end

  # A desk server's whole environment: the system and desk-server names from the
  # parent, then the launcher's own `values` over them, minus every forbidden name.
  def desk_server(values, env = ENV)
    flags = env.to_h.select { |name, _| DESK_SERVER_ALLOW_PREFIXES.any? { |prefix| name.start_with?(prefix) } }
    allowed(env, SYSTEM_ALLOW + DESK_SERVER_ALLOW).merge(flags).merge(values.to_h).reject { |name, _| forbidden?(name) }
  end
end
