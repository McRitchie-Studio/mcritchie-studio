# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "securerandom"
require "tempfile"
require "fileutils"

# DevSecretKey: a local checkout's SECRET_KEY_BASE is a development key, never a
# production one.
#
# WHY THIS EXISTS. On 2026-10-06 all 23 local .env files that set SECRET_KEY_BASE
# (the hub and turf-monster primaries plus every desk cut from them) held the
# PRODUCTION mcritchie-studio key. Two steps put it there:
#
#   1. bin/ecosystem-build restored a primary's .env from `heroku config` of the
#      PRODUCTION app, SECRET_KEY_BASE included.
#   2. bin/agent-worktree copied the primary's .env into every new desk verbatim.
#
# Rails 8.1 development reads ENV["SECRET_KEY_BASE"] (measured: the app's key and
# the env key share a digest), so every local process signed cookies, magic links
# and API tokens that production would accept. Both writers now go through
# `rewrite`, and `scan` finds any file that still holds a production key.
#
# NEVER PRINTS A VALUE. Everything that leaves this module is a path, a state or a
# SHA-256 digest prefix. A full SHA-256 of a 512-bit random key does not reveal
# it, but only the 8-char prefix is ever shown, matching how the finding was
# reported.
module DevSecretKey
  KEY = "SECRET_KEY_BASE"
  # `SECRET_KEY_BASE=…` and `export SECRET_KEY_BASE=…`, leading space allowed.
  LINE = /\A(\s*(?:export\s+)?#{KEY}\s*=)(.*?)(\r?\n)?\z/m
  PREFIX_LEN = 8

  # Production Heroku apps whose SECRET_KEY_BASE a local file must never hold.
  # QA apps are listed too: a QA key is still not a development key.
  HEROKU_APPS = %w[
    mcritchie-studio turf-monster-mainnet mcritchie-industries
    rolio-prod tax-studio moms-app
    mcritchie-studio-qa turf-monster-qa mcritchie-industries-qa rolio-qa
  ].freeze

  # Where local env files live: the shared projects-root .env, each primary, and each desk.
  SCAN_GLOBS = [".env*", "*/.env*", "*/.worktrees/*/.env*"].freeze

  # THE DENY LIST: keys only a deployed app may hold. This constant is the ONE
  # place it lives. bin/ecosystem-build's restore drops every one of them
  # (`bin/dev-secret-key filter`), and `scan` flags a local file that holds a
  # production value for any of them.
  #
  # Found 2026-10-06: the old restore had copied all of these out of production
  # `heroku config` into the hub and turf primaries, and bin/agent-worktree then
  # copied them into every desk. Local dev needs none of them:
  #
  #   SOLANA_ADMIN_KEY      mainnet VaultState signer slot 0 and server fee payer
  #                         (turf-monster-mainnet). FIRST ON PURPOSE: it signs
  #                         money. turf-monster-qa carries the same key.
  #   CDP_API_KEY_*         the production Coinbase CDP key; only the ramp flows use it
  #   AWS_*                 the production IAM key; local storage runs on R2 (QA keys)
  #   RESEND_API_KEY        production mail; local stacks capture mail instead
  #                         (LOCAL_EMAIL_CAPTURE=1, /_studio/local_emails)
  #   GITHUB_TOKEN          the hub's static fallback PAT; answered 401 on 2026-10-06
  #   MANAGED_WALLET_ENCRYPTION_KEY(_PREVIOUS)
  #                         on turf-monster-mainnet it opens every custodial
  #                         mainnet wallet; development falls back to
  #                         secret_key_base (Solana::Keypair.current_encryptor)
  #   STRIPE_SECRET_KEY / STRIPE_WEBHOOK_SECRET
  #                         live Stripe on turf-monster-mainnet; local uses test mode
  #
  # PRODUCTION means the apps outside QA_HEROKU_APPS. A local file holding a QA
  # app's value for one of these keys is not flagged: local turf deliberately
  # shares QA's managed-wallet key, and QA's Stripe is test mode. The restore
  # filter is by NAME, so a production restore drops these whatever their value.
  #
  # Kept by design, NOT listed: RAILS_MASTER_KEY (decrypts the committed
  # credentials) and AGENT_API_SECRET (verifies board tokens).
  PRODUCTION_ONLY_KEYS = %w[
    SOLANA_ADMIN_KEY
    CDP_API_KEY_ID
    CDP_API_KEY_SECRET
    AWS_ACCESS_KEY_ID
    AWS_SECRET_ACCESS_KEY
    RESEND_API_KEY
    GITHUB_TOKEN
    MANAGED_WALLET_ENCRYPTION_KEY
    MANAGED_WALLET_ENCRYPTION_KEY_PREVIOUS
    STRIPE_SECRET_KEY
    STRIPE_WEBHOOK_SECRET
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze

  # The QA apps on HEROKU_APPS. Their SECRET_KEY_BASE is still flagged (a QA key
  # is not a development key), but their production-only values are not.
  QA_HEROKU_APPS = %w[mcritchie-studio-qa turf-monster-qa mcritchie-industries-qa rolio-qa].freeze

  # The key a dotenv/`heroku config --shell` line sets, or nil for a comment or blank.
  ANY_LINE = /\A\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)\z/m

  module_function

  # A fresh development key: 64 random bytes, hex, the shape `bin/rails secret` prints.
  def generate
    SecureRandom.hex(64)
  end

  def digest(value)
    Digest::SHA256.hexdigest(value.to_s)
  end

  def prefix(hex_digest)
    hex_digest.to_s[0, PREFIX_LEN]
  end

  # The value the file sets for `key`, as dotenv would read it; nil when no line sets it.
  def read_value(path, key = KEY)
    return nil unless File.file?(path)

    File.foreach(path) do |line|
      m = ANY_LINE.match(line) or next
      next unless m[1] == key

      return parse_value(m[2].chomp)
    end
    nil
  end

  def production_only?(key)
    PRODUCTION_ONLY_KEYS.include?(key.to_s)
  end

  # The restore filter: `text` (a `heroku config --shell` dump) minus every line
  # that sets a PRODUCTION_ONLY_KEYS key. A quoted value that runs over several
  # lines is dropped whole, so no tail of it is left behind as a stray line.
  # Returns [kept_text, dropped_key_names]; the names are safe to print, the
  # values are never returned.
  def filter_production_only(text)
    kept = []
    dropped = []
    open_quote = nil
    text.to_s.each_line do |line|
      if open_quote
        open_quote = nil if line.include?(open_quote)
        next
      end
      m = ANY_LINE.match(line)
      if m && production_only?(m[1])
        dropped << m[1]
        raw = m[2].lstrip
        quote = raw[0] if %w[" '].include?(raw[0])
        open_quote = quote if quote && !raw[1..].to_s.include?(quote)
        next
      end
      kept << line
    end
    [kept.join, dropped.uniq]
  end

  # Desk provisioning's hook: drop every PRODUCTION_ONLY_KEYS line from a COPIED
  # env file, so a desk never inherits a production-only key the primary still
  # holds. Returns the dropped key names (never a value); [] leaves the file as is.
  def strip_production_only(path)
    return [] unless File.file?(path)

    kept, dropped = filter_production_only(File.read(path))
    atomic_write(path, kept) unless dropped.empty?
    dropped
  end

  # Remove every line that sets `key` from `path` (atomic, permissions kept).
  # Returns the number of lines removed.
  def remove_key(path, key)
    lines = File.readlines(path)
    kept = lines.reject { |line| (m = ANY_LINE.match(line)) && m[1] == key }
    removed = lines.size - kept.size
    atomic_write(path, kept.join) if removed.positive?
    removed
  end

  # dotenv's reading of a raw right-hand side: a quoted value is its inner text;
  # an unquoted one ends at an inline ` #` comment.
  def parse_value(raw)
    raw = raw.to_s.strip
    if raw.length >= 2 && %w[" '].include?(raw[0]) && raw[-1] == raw[0]
      raw[1..-2]
    else
      raw.sub(/(\A|\s+)#.*\z/, "").strip
    end
  end

  # Set SECRET_KEY_BASE in `path` to a freshly generated development key. Every
  # line that sets it is rewritten to the one new value (so a duplicate line cannot
  # keep the old one alive); a file with no line gets one appended. The write is
  # atomic and keeps the file's permissions (0600 for a new file). Returns the new
  # value's digest, never the value.
  def rewrite(path, value: generate)
    lines = File.file?(path) ? File.readlines(path) : []
    replaced = false
    lines = lines.map do |line|
      m = LINE.match(line) or next line
      replaced = true
      "#{m[1]}#{value}#{m[3] || "\n"}"
    end
    unless replaced
      lines[-1] = "#{lines[-1]}\n" if lines.any? && !lines[-1].end_with?("\n")
      lines << "#{KEY}=#{value}\n"
    end
    atomic_write(path, lines.join)
    digest(value)
  end

  # Desk provisioning's hook: a COPIED env file that sets a non-empty key gets a
  # fresh one, so a desk can never inherit the value its primary holds, whatever it
  # is. A file with no key, or an empty one, is left alone (the app then falls back
  # to its own development secret). Returns the new digest, or nil when untouched.
  def replace_in_copy(path)
    value = read_value(path)
    return nil if value.nil? || value.empty?

    rewrite(path)
  end

  # Each env file under `projects_dir` (primaries and desks), sorted.
  def default_files(projects_dir)
    SCAN_GLOBS.flat_map { |glob| Dir.glob(File.join(projects_dir, glob), File::FNM_DOTMATCH) }
              .map { |path| File.expand_path(path) } # FNM_DOTMATCH lets `*` match `.`: ./.env
              .select { |path| File.file?(path) }
              .uniq.sort
  end

  # One row per file: {path:, state:, prefix:, app:}. state is
  #   :production  the value's digest is a known production digest (app: names it)
  #   :dev         a non-empty value that matches no production digest
  #   :empty       a line with no value (a template such as .env.example)
  #   :absent      no line sets the key
  # `production_digests` maps a full hex digest to the app that holds it.
  # `key` is the variable read (SECRET_KEY_BASE by default); every row carries it.
  def scan(files, production_digests, key: KEY)
    files.map do |path|
      value = read_value(path, key)
      if value.nil?
        { path: path, key: key, state: :absent, prefix: nil, app: nil }
      elsif value.empty?
        { path: path, key: key, state: :empty, prefix: nil, app: nil }
      else
        d = digest(value)
        app = production_digests[d]
        { path: path, key: key, state: app ? :production : :dev, prefix: prefix(d), app: app }
      end
    end
  end

  # The production-only sweep: one row per (file, key) for each PRODUCTION_ONLY_KEYS
  # key the file sets. `digests_by_key` maps key => {full_digest => app}.
  def scan_production_only(files, digests_by_key, keys: PRODUCTION_ONLY_KEYS)
    keys.flat_map do |key|
      scan(files, digests_by_key.fetch(key, {}), key: key).reject { |row| row[:state] == :absent }
    end
  end

  # {full_digest => app} for each Heroku app whose config sets the key, plus
  # {unread: [apps]} for any app whose config could not be read. The value is
  # hashed inside this process and dropped; it is never returned or printed.
  # `runner` is a seam for tests: (app) -> [stdout, success?].
  def heroku_digests(apps = HEROKU_APPS, runner: method(:heroku_config_json))
    by_key, unread = heroku_digests_by_key(apps, [KEY], runner: runner)
    [by_key.fetch(KEY), unread]
  end

  # {key => {full_digest => app}} for each of `keys`, from ONE config read per
  # app, plus the unread apps. A production-only key records no QA app's digest. Same contract as heroku_digests: values are hashed
  # in-process and dropped.
  def heroku_digests_by_key(apps = HEROKU_APPS, keys = [KEY] + PRODUCTION_ONLY_KEYS,
                            runner: method(:heroku_config_json))
    by_key = keys.to_h { |key| [key, {}] }
    unread = []
    apps.each do |app|
      out, ok = runner.call(app)
      config = ok ? (JSON.parse(out.to_s) rescue nil) : nil
      unless config.is_a?(Hash) && !config.empty?
        unread << app
        next
      end
      keys.each do |key|
        next if production_only?(key) && QA_HEROKU_APPS.include?(app)

        value = config[key].to_s
        by_key[key][digest(value)] = app unless value.empty?
      end
    end
    [by_key, unread]
  end

  def heroku_config_json(app)
    out, _err, status = Open3.capture3("heroku", "config", "--json", "-a", app)
    [out, status.success?]
  rescue Errno::ENOENT
    ["", false]
  end

  def atomic_write(path, content)
    mode = File.exist?(path) ? (File.stat(path).mode & 0o777) : 0o600
    dir = File.dirname(path)
    FileUtils.mkdir_p(dir)
    tmp = Tempfile.create([".#{File.basename(path)}.", ".tmp"], dir)
    begin
      tmp.write(content)
      tmp.close
      File.chmod(mode, tmp.path)
      File.rename(tmp.path, path)
    ensure
      File.unlink(tmp.path) if File.exist?(tmp.path)
    end
  end
end
