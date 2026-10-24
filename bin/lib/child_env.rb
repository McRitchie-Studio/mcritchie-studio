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
  # RUBY_DEBUG_* are the debug gem's switches (hub bin/dev sets OPEN and LAZY).
  DESK_SERVER_ALLOW_PREFIXES = %w[ENABLE_ RUBY_DEBUG_].freeze

  # Every locale variable (LC_ALL, LC_CTYPE, LC_MESSAGES, ...) passes by prefix:
  # launchd and a bare `env -i` start without a locale and Ruby then reads UTF-8
  # files as US-ASCII and crashes.
  LOCALE_PREFIXES = %w[LC_].freeze

  # The desk's mail credentials, exported EMPTY (bin/agent-worktree
  # local_email_values) so dotenv cannot fill them from a .env and a desk never
  # sends real mail. Kept only while empty: a SET value, from the parent or from
  # a stack file, is replaced by the empty blank, never passed on and never
  # dropped, because a dropped name is one dotenv would then fill. Twin of
  # turf-monster bin/lib/desk_env.sh TM_ENV_KEEP_IF_EMPTY, which blanks the same way.
  MAIL_KEEP_IF_EMPTY = %w[RESEND_API_KEY SES_SMTP_USERNAME SES_SMTP_PASSWORD].freeze

  # What a lease RENEWER (bin/devops-shift, bin/lib/review_claim_cli.rb,
  # bin/lib/release_claim_cli.rb `renew-loop`) reads besides its own session and
  # nonce, which its launcher passes explicitly: the board URL and the projects
  # directory that holds the cached board token (AgentApi), and the test
  # sandbox's pins so a renewer started under a test cannot reach real state.
  # It re-mints from the cache or the repo .env, never from an agent credential.
  RENEWER_ALLOW = %w[
    ATOMIC_CAPTURE_URL CLAUDE_PROJECTS_DIR
    TASK_USAGE_SANDBOX TASK_USAGE_DIR OUTBOUND_SEAMS OUTBOUND_SEAM_LOG
  ].freeze

  # What a pre-flight LANE (bin/fast-check through LaneRunner: the Rails suite,
  # rubocop, a gem's declared suite, turf-vault's anchor build) reads from the
  # parent. A lane's needs are OPEN in a way a server's are not: the toolchains
  # (BUNDLE_*, CARGO_*, RUSTUP_*, MISE_*, ...), an operator's one-run knob
  # (`PARALLEL_WORKERS=1 bin/fast-check`), and the stub commands the test suite
  # drives fast-check with, each reading its own variable. So a lane keeps every
  # name that does not look like a credential (SECRET_SHAPED), the names below
  # even though they do, and the caller's values, minus FORBIDDEN as everywhere.
  # That is a pattern deny-list, chosen on purpose for this one short-lived
  # launcher; the servers and renewers keep the strict allow-list. A suite reads
  # its real secrets from the checkout (.env.test.local, config/master.key),
  # never from the agent's shell, so RAILS_MASTER_KEY, PGPASSWORD and NPM_TOKEN
  # are dropped with the rest.
  LANE_ALLOW = %w[SSH_AUTH_SOCK].freeze
  # A name that says it carries a credential.
  SECRET_SHAPED = /KEY|SECRET|TOKEN|PASSW|CREDENTIAL|PRIVATE|SESSION|COOKIE|AUTH|SIGN/i

  # AgentApi's off-switch for the shared board token (AgentApi::LEGACY_ENV and
  # LEGACY_OFF, copied so this file stays loadable on its own; a unit test pins
  # the two lists equal). Its OFF values are a setting, not a credential, and a
  # renewer must keep one: a session running with AGENT_LEGACY_TOKEN=off whose
  # renewer lost the name would re-mint with the shared token behind its back
  # (secrets-scrub-review-notes). Any OTHER value stays dropped, so the name can
  # never carry a token into a child even if somebody pastes one there.
  LEGACY_SWITCH = "AGENT_LEGACY_TOKEN"
  LEGACY_SWITCH_OFF = %w[off 0 false no].freeze

  # Never in a child's environment, whoever asks. AGENT_LEGACY_TOKEN is here so no
  # value under that name ever reaches a child; renewer() alone re-adds it, and
  # only with an OFF value (LEGACY_SWITCH_OFF above).
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

  # The subset of `env` whose names start with one of `prefixes`.
  def by_prefix(env, prefixes)
    env.to_h.select { |name, _| prefixes.any? { |prefix| name.start_with?(prefix) } }
  end

  # A child's whole environment from the parent's: the system names, the locale,
  # `allow` by name and `prefixes` by prefix, then the launcher's own `values`
  # over them, minus every forbidden name. Apply with `unsetenv_others: true`.
  def build(values, env, allow: [], prefixes: [])
    allowed(env, SYSTEM_ALLOW + allow)
      .merge(by_prefix(env, LOCALE_PREFIXES + prefixes))
      .merge(values.to_h)
      .reject { |name, _| forbidden?(name) }
  end

  # A desk server's whole environment: the system and desk-server names from the
  # parent, then the launcher's own `values` over them, minus every forbidden
  # name, with the mail credentials held to the empty desk blank.
  def desk_server(values, env = ENV)
    kept = build(values, env, allow: DESK_SERVER_ALLOW, prefixes: DESK_SERVER_ALLOW_PREFIXES)
    mail = MAIL_KEEP_IF_EMPTY.select { |name| env.key?(name) || values.to_h.key?(name) }
    kept.merge(mail.to_h { |name| [name, ""] })
  end

  # A detached lease renewer's environment; `values` carries its session and nonce.
  # AGENT_LEGACY_TOKEN passes only with an OFF value (LEGACY_SWITCH_OFF).
  def renewer(values, env = ENV, allow: [])
    kept = build(values, env, allow: RENEWER_ALLOW + allow)
    switch = env[LEGACY_SWITCH]
    kept[LEGACY_SWITCH] = switch if legacy_off?(switch)
    kept
  end

  # True when `value` is one of the shared token's OFF spellings.
  def legacy_off?(value)
    !value.nil? && LEGACY_SWITCH_OFF.include?(value.to_s.strip.downcase)
  end

  # A pre-flight lane's environment; `values` is what the caller sets for the lane.
  # See LANE_ALLOW for why a lane keeps the names that do not look secret.
  def lane(values, env = ENV)
    plain = env.to_h.reject { |name, _| name.match?(SECRET_SHAPED) }
    plain.merge(build(values, env, allow: LANE_ALLOW)).reject { |name, _| forbidden?(name) }
  end

  # `ruby bin/lib/child_env.rb desk-server -- <cmd> [args...]` execs <cmd> under
  # desk_server({}), so a shell launcher (bin/dev, bin/ecosystem-build) shares
  # this one list instead of keeping a copy. Names travel through the
  # environment, values never touch argv.
  def exec_cli(argv)
    kind = argv.shift
    argv.shift if argv.first == "--"
    abort "usage: child_env.rb desk-server -- <command> [args...]" unless kind == "desk-server" && argv.any?

    exec(desk_server({}), *argv, unsetenv_others: true)
  end
end

ChildEnv.exec_cli(ARGV.dup) if $PROGRAM_NAME == __FILE__
