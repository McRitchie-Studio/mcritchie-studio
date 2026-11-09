# frozen_string_literal: true

require "json"
require "time"
require "yaml"
require "fileutils"
require_relative "secret_cache"
require_relative "op_meter"

# SoulSecrets — each soul's own set of 1Password items, warmed into the secret
# cache at launch and read from there. Config: config/soul_secret_sets.yml. Doc:
# docs/agents/modules/secret-cache.md, section "Soul secret sets".
#
# WHY (Alex McRitchie, 2026-11-09). Overnight a release waited four hours on one
# live `op item get solana.mack.agent` inside the devnet gauntlet. A soul's items
# are warmed into <cache>/<soul>/ by one bounded pass when the soul launches, so a
# later read costs no 1Password call and a stalled `op` stops nothing until an
# entry expires.
#
# THE RULES THIS FILE HOLDS
#   * A soul reads only its own set. A read of an item another soul's set names is
#     REFUSED and logged (bin/op-reads shows it as action `soul-refused`). An item
#     no set names is NOT_MANAGED: the caller falls back to the classic read. The
#     ratchet that closes that fallback is a later task (agent-op-reads-ratchet).
#   * Nothing from an admin vault lands in a soul folder. A config that names one
#     is refused at load, and the write path refuses it again.
#   * Each soul's set is a portable unit (ruling 2): #manifest is everything a
#     fresh machine needs besides that soul's own service-account token.
#   * Every `op` call is bounded (OpMeter: at most OP_DEADLINE_CAP seconds an
#     attempt). After a hang the pass stops calling `op`.
#   * NEVER A VALUE IN OUTPUT. Lines name souls, items, fields and times only.
#
# ONE UNIX USER (for now). Per-soul folders on one Unix user are a POLICY line,
# not a security boundary: any process running as this user can open any file.
# The refusal stops a soul's tooling from reading another soul's items by
# accident and records every attempt. Moving a soul to its own machine (ruling 2)
# is what turns the line into a boundary.
#
# Ruby 2.6 syntax, like secret_cache.rb.
module SoulSecrets
  CONFIG_ENV = "MCR_SOUL_SECRET_SETS"
  SOUL_ENV = "MCR_SOUL"
  FORMAT = "soul-secret-set/1"
  NOT_MANAGED = 3
  REFUSED = 4
  OP_DEADLINE_CAP = 20
  DEFAULT_OP_BIN = "/opt/homebrew/bin/op"
  SLUG = /\A[a-z][a-z0-9-]*\z/.freeze
  DURATION = /\A(\d+)\s*([smhd])\z/.freeze
  UNITS = { "s" => 1, "m" => 60, "h" => 3600, "d" => 86_400 }.freeze

  class ConfigError < StandardError; end

  # Raised when a soul asks for an item outside its own set. Its message names the
  # soul and the item, never a value.
  class Refused < StandardError; end

  # Raised when an item could not be read and nothing unexpired is cached.
  class Unavailable < StandardError; end

  module_function

  # ── config ─────────────────────────────────────────────────────────────────

  def config_path(env = ENV)
    override = env[CONFIG_ENV].to_s.strip
    override.empty? ? File.expand_path("../../config/soul_secret_sets.yml", __dir__) : File.expand_path(override)
  end

  def config(env = ENV)
    data = YAML.safe_load(File.read(config_path(env)))
    validate!(data, env)
  rescue Errno::ENOENT
    raise ConfigError, "soul secret sets: no config at #{config_path(env)}"
  rescue Psych::SyntaxError => e
    raise ConfigError, "soul secret sets: #{config_path(env)} is not valid YAML (#{e.message})"
  end

  # "30m", "12h", "1d", or a number of seconds.
  def seconds(value)
    return value if value.is_a?(Integer) && value.positive?

    match = DURATION.match(value.to_s.strip)
    raise ConfigError, "soul secret sets: #{value.inspect} is not a duration (30m, 12h, 1d)" unless match

    match[1].to_i * UNITS.fetch(match[2])
  end

  def validate!(data, env = ENV)
    raise ConfigError, "soul secret sets: the config is not a map" unless data.is_a?(Hash)

    souls = data["souls"]
    raise ConfigError, "soul secret sets: `souls` is not a map" unless souls.is_a?(Hash)

    souls.each { |soul, set| validate_set!(soul, set, env) }
    validate_admin!(data["admin_tier"]) if data.key?("admin_tier")
    data
  end

  def validate_set!(soul, set, env = ENV)
    raise ConfigError, "soul secret sets: #{soul.inspect} is not a soul slug" unless SLUG.match?(soul.to_s)
    raise ConfigError, "soul secret sets: #{soul}'s set is not a map" unless set.is_a?(Hash)

    items = set["items"]
    raise ConfigError, "soul secret sets: #{soul}.items is not a list" unless items.is_a?(Array)

    items.each do |entry|
      unless entry.is_a?(Hash) && !entry["item"].to_s.strip.empty? && !entry["vault"].to_s.strip.empty?
        raise ConfigError, "soul secret sets: #{soul} has an item with no `item` or `vault`"
      end
      if SecretCache.admin_vault?(entry["vault"], env)
        raise ConfigError, "soul secret sets: #{soul} names #{entry['item']} from the admin vault " \
                           "#{entry['vault']}; admin items live in admin_tier, never in a soul's set"
      end
      fields = entry["fields"]
      unless fields.is_a?(Array) && !fields.empty? && fields.all? { |f| !f.to_s.strip.empty? }
        raise ConfigError, "soul secret sets: #{soul}/#{entry['item']} names no `fields` to keep"
      end
      seconds(entry["lifetime"])
      seconds(entry["refresh_window"]) if entry.key?("refresh_window")
    end
    set
  end

  def validate_admin!(tier)
    raise ConfigError, "soul secret sets: admin_tier is not a map" unless tier.is_a?(Hash)

    unless tier["storage"].to_s == "memory"
      raise ConfigError, "soul secret sets: admin_tier.storage #{tier['storage'].inspect} is not implemented; " \
                         "only `memory` is (the doc names the threat a disk tier carries)"
    end
    seconds(tier["lifetime"])
    raise ConfigError, "soul secret sets: admin_tier.scripts is not a list" unless tier["scripts"].is_a?(Array)

    tier
  end

  # ── the portable unit (ruling 2) ───────────────────────────────────────────

  # One soul's manifest: everything a fresh machine needs to warm this soul,
  # except the token itself. Names and metadata only.
  def manifest(soul, cfg)
    set = cfg.fetch("souls", {})[soul.to_s]
    raise ConfigError, "soul secret sets: no set for #{soul.inspect}" unless set

    {
      "format" => FORMAT,
      "soul" => soul.to_s,
      "service_account" => { "token_env" => set.dig("service_account", "token_env").to_s },
      "shared" => Array(set["shared"]),
      "items" => set["items"].map do |entry|
        lifetime = seconds(entry["lifetime"])
        window = entry.key?("refresh_window") ? seconds(entry["refresh_window"]) : lifetime / 10
        {
          "item" => entry["item"].to_s, "vault" => entry["vault"].to_s, "fields" => entry["fields"].map(&:to_s),
          "lifetime_seconds" => lifetime, "refresh_window_seconds" => window,
          "readers" => Array(entry["readers"]).map(&:to_s)
        }
      end
    }
  end

  # A manifest read from a file (a fresh machine): validated like the config.
  def load_manifest(path, env = ENV)
    data = JSON.parse(File.read(path))
    raise ConfigError, "soul secret sets: #{path} is not a #{FORMAT} manifest" unless data["format"] == FORMAT

    items = data["items"].map do |e|
      e.merge("lifetime" => e["lifetime_seconds"].to_i, "refresh_window" => e["refresh_window_seconds"].to_i)
    end
    validate_set!(data["soul"].to_s, { "items" => items }, env)
    data
  rescue JSON::ParserError, NoMethodError, TypeError
    raise ConfigError, "soul secret sets: #{path} is not a #{FORMAT} manifest"
  end

  def manifests(cfg)
    cfg.fetch("souls", {}).keys.map { |soul| manifest(soul, cfg) }
  end

  # ── the folder ─────────────────────────────────────────────────────────────

  def soul_dir(soul, env = ENV)
    raise ConfigError, "soul secret sets: #{soul.inspect} is not a soul slug" unless SLUG.match?(soul.to_s)

    File.join(SecretCache.dir(env), soul.to_s)
  end

  # The soul's folder, 0700, a real directory this user owns.
  def ensure_soul_dir!(soul, env = ENV)
    SecretCache.ensure_home!(env)
    path = soul_dir(soul, env)
    begin
      Dir.mkdir(path, SecretCache::DIR_MODE)
    rescue Errno::EEXIST
      nil
    end
    check_soul_dir!(path)
  end

  def check_soul_dir!(path, uid: Process.euid)
    stat = File.lstat(path)
    raise SecretCache::Unsafe, "soul folder #{path} is not a real directory; refusing it" unless stat.directory?
    raise SecretCache::Unsafe, "soul folder #{path} is owned by uid #{stat.uid}, not this user; refusing it" if stat.uid != uid
    if SecretCache.wider?(stat.mode, SecretCache::DIR_MODE)
      raise SecretCache::Unsafe, format("soul folder %s has mode %04o, wider than 0700; run `chmod 700 %s`",
                                        path, stat.mode & 0o777, path)
    end
    path
  end

  def item_file(item)
    "item.#{item.to_s.gsub(/[^A-Za-z0-9._-]/, '_')}.json"
  end

  # The cached copy of +entry+ for +soul+: { "fields" => {...}, "expires_at" => Time }
  # or nil. Raises Unsafe on a widened, foreign or symlinked file.
  def cached(soul, entry, env: ENV)
    SecretCache.check_safe!(env)
    home = SecretCache.readable_dir(env)
    return nil unless home

    dir = File.join(home, soul.to_s)
    return nil unless File.exist?(dir) || File.symlink?(dir)

    check_soul_dir!(dir)
    path = File.join(dir, item_file(entry["item"]))
    return nil unless File.exist?(path) || File.symlink?(path)

    SecretCache.check_file!(path)
    data = JSON.parse(File.read(path))
    return nil unless data.is_a?(Hash) && data["fields"].is_a?(Hash) && data["vault"] == entry["vault"]

    expires = SecretCache.time_or_nil(data["expires_at"])
    expires ? { "fields" => data["fields"], "expires_at" => expires } : nil
  rescue JSON::ParserError
    nil
  end

  # :fresh, :window, :expired or :absent, with the expiry.
  def state(soul, entry, env: ENV, now: Time.now)
    copy = cached(soul, entry, env: env)
    return [:absent, nil] unless copy

    left = copy["expires_at"] - now
    return [:expired, copy["expires_at"]] if left <= 0
    return [:window, copy["expires_at"]] if left <= entry["refresh_window_seconds"].to_i

    [:fresh, copy["expires_at"]]
  end

  def store(soul, entry, fields, env: ENV, now: Time.now)
    if SecretCache.admin_vault?(entry["vault"], env)
      raise SecretCache::AdminVaultRefused, "soul secret sets: #{entry['item']} is in an admin vault and is never written to disk"
    end

    dir = ensure_soul_dir!(soul, env)
    expires = now + entry["lifetime_seconds"].to_i
    data = { "soul" => soul.to_s, "item" => entry["item"], "vault" => entry["vault"], "fields" => fields,
             "fetched_at" => now.utc.iso8601, "expires_at" => expires.utc.iso8601 }
    SecretCache.atomic_write(File.join(dir, item_file(entry["item"])), "#{JSON.generate(data)}\n")
    expires
  end

  def forget(soul, item, env: ENV)
    path = File.join(soul_dir(soul, env), item_file(item))
    File.delete(path) if File.exist?(path) || File.symlink?(path)
    true
  rescue Errno::ENOENT
    true
  end

  # ── 1Password ──────────────────────────────────────────────────────────────

  def op_bin(env = ENV)
    override = env["SECRET_OP_BIN"].to_s.strip
    override.empty? ? DEFAULT_OP_BIN : override
  end

  # The env OpMeter reads its deadline from, capped at OP_DEADLINE_CAP.
  def bounded_env(env)
    limit = [OpMeter.deadline(env), OP_DEADLINE_CAP].min
    env.to_h.merge(OpMeter::DEADLINE_ENV => limit.to_s)
  end

  # The op child's own env: the soul's service-account token when it is set,
  # else nothing added (the machine's shared agent token). [env, words].
  def op_env(manifest, env)
    token_env = manifest.dig("service_account", "token_env").to_s
    if !token_env.empty? && !env[token_env].to_s.strip.empty?
      [{ "OP_SERVICE_ACCOUNT_TOKEN" => env[token_env] }, "#{token_env} (this soul's own service account)"]
    else
      [{}, "the shared agent service account#{token_env.empty? ? '' : " (#{token_env} is not set)"}"]
    end
  end

  # The kept fields of one item, from one bounded `op item get`. Raises
  # Unavailable (its message says whether 1Password hung) and never a value.
  def fetch(manifest, entry, env: ENV)
    child_env, = op_env(manifest, env)
    via = "soul:#{manifest['soul']}:#{entry['vault']}/#{entry['item']}"
    argv = [op_bin(env), "item", "get", entry["item"], "--vault", entry["vault"], "--format", "json"]
    out = OpMeter.popen(child_env, argv, via: via, env: bounded_env(env), announce: false, err: File::NULL)
    raise Unavailable, "1Password is not answering (#{entry['item']})" if OpMeter.last_hung?
    raise Unavailable, "op could not read #{entry['vault']}/#{entry['item']}" unless $?.success?

    keep(JSON.parse(out), entry)
  rescue JSON::ParserError
    raise Unavailable, "op answered #{entry['item']} with something that is not JSON"
  rescue SystemCallError
    raise Unavailable, "the 1Password CLI is not at #{op_bin(env)}"
  end

  # Only the configured labels survive; every other field of the item is dropped.
  def keep(item_json, entry)
    wanted = entry["fields"]
    kept = {}
    Array(item_json["fields"]).each do |field|
      next unless field.is_a?(Hash)

      label = field["label"] || field["id"]
      kept[label] = field["value"].to_s if wanted.include?(label) && !field["value"].to_s.empty?
    end
    raise Unavailable, "#{entry['item']} has none of the fields #{wanted.join(', ')}" if kept.empty?

    kept
  end

  # ── warm ───────────────────────────────────────────────────────────────────

  # One pass over a soul's set: an entry that is fresh costs nothing; any other is
  # read once from 1Password and written to the soul's folder. After a hang the
  # pass stops calling `op`. Returns [lines, ok].
  def warm(manifest, env: ENV, now: Time.now, only: nil)
    soul = manifest["soul"]
    _child, account = op_env(manifest, env)
    lines = ["#{soul}: warming #{manifest['items'].size} item(s) with #{account}"]
    ok = true
    hung = false
    manifest["items"].each do |entry|
      next if only && !only.include?(entry["item"])

      line, good, hung = warm_one(manifest, entry, env: env, now: now, hung: hung)
      ok &&= good
      lines << "  #{entry['item']}: #{line}"
    end
    [lines, ok]
  end

  def warm_one(manifest, entry, env:, now:, hung:)
    current, expires = state(manifest["soul"], entry, env: env, now: now)
    return ["fresh, expires in #{SecretCache.duration_words(expires - now)} (no 1Password read)", true, hung] if current == :fresh
    return ["skipped: 1Password hung earlier in this pass", current == :window, hung] if hung

    fields = fetch(manifest, entry, env: env)
    expires = store(manifest["soul"], entry, fields, env: env, now: now)
    ["warmed, expires in #{SecretCache.duration_words(expires - now)}", true, false]
  rescue Unavailable => e
    still = current == :window ? "; the cached copy still serves until #{expires.utc.iso8601}" : ""
    ["FAILED: #{e.message}#{still}", current == :window, hung || OpMeter.last_hung?]
  end

  # True when any item in the set is not fresh. Reads files only.
  def due?(manifest, env: ENV, now: Time.now)
    manifest["items"].any? { |entry| state(manifest["soul"], entry, env: env, now: now).first != :fresh }
  rescue StandardError
    true
  end

  # ── read ───────────────────────────────────────────────────────────────────

  # The souls whose sets name this item.
  def owners(cfg, vault, item)
    cfg.fetch("souls", {}).select do |_soul, set|
      set["items"].any? { |e| e["vault"].to_s == vault.to_s && e["item"].to_s == item.to_s }
    end.keys
  end

  # :mine (with the entry), :refused, or :not_managed.
  def resolve(soul, vault, item, cfg)
    owners = owners(cfg, vault, item)
    return [:not_managed, nil] if owners.empty?
    return [:refused, owners] unless owners.include?(soul.to_s)

    entry = manifest(soul, cfg)["items"].find { |e| e["vault"] == vault.to_s && e["item"] == item.to_s }
    [:mine, entry]
  end

  # Record a refusal in the read log (bin/op-reads shows action `soul-refused`).
  def log_refusal(soul, vault, item, env: ENV)
    OpMeter.record(action: "soul-refused", outcome: "refused", via: "soul:#{soul}:#{vault}/#{item}", env: env)
  end

  # The kept fields of +item+ for +soul+: the cache first, then one bounded read
  # written back. When the read fails, a copy inside its refresh window still
  # serves. Raises Refused or Unavailable; returns nil when no set names it.
  def read(soul, vault, item, cfg:, env: ENV, now: Time.now, err: $stderr)
    kind, detail = resolve(soul, vault, item, cfg)
    return nil if kind == :not_managed

    if kind == :refused
      log_refusal(soul, vault, item, env: env)
      raise Refused, "secret: #{soul} may not read #{vault}/#{item}: it is in #{detail.join(', ')}'s set, " \
                     "not #{soul}'s (config/soul_secret_sets.yml). The attempt is logged."
    end

    copy = cached(soul, detail, env: env)
    if copy
      left = copy["expires_at"] - now
      if left > detail["refresh_window_seconds"].to_i
        OpMeter.record(action: "cache-hit", outcome: "ok", via: "soul:#{soul}:#{vault}/#{item}", env: env)
        return copy["fields"]
      end
    end

    begin
      fields = fetch(manifest(soul, cfg), detail, env: env)
      store(soul, detail, fields, env: env, now: now)
      fields
    rescue Unavailable => e
      raise unless copy && copy["expires_at"] > now

      err.puts("secret: #{e.message}; serving the cached copy of #{item} (expires #{copy['expires_at'].utc.iso8601})")
      copy["fields"]
    end
  end

  # The fields in the shape `op item get --format json` prints, for a caller that
  # parses that (turf-monster's KeyStore, through bin/shims/op-cache/op).
  def op_item_json(item, vault, fields)
    JSON.generate("title" => item, "vault" => { "name" => vault },
                  "fields" => fields.map { |label, value| { "id" => label, "label" => label, "value" => value } })
  end

  # ── status ─────────────────────────────────────────────────────────────────

  def status_lines(cfg, env: ENV, now: Time.now)
    lines = []
    manifests(cfg).each do |m|
      _child, account = op_env(m, env)
      lines << "#{m['soul']}: #{m['items'].size} item(s); #{account}"
      m["items"].each do |entry|
        current, expires = state(m["soul"], entry, env: env, now: now)
        words = case current
                when :fresh then "expires in #{SecretCache.duration_words(expires - now)}"
                when :window then "expires in #{SecretCache.duration_words(expires - now)}, inside the refresh window"
                when :expired then "expired #{SecretCache.duration_words(now - expires)} ago"
                else "not warmed"
                end
        lines << "  #{entry['vault']}/#{entry['item']}: #{words}"
      end
    end
    lines
  end

  # ── the launch seam: the SubagentStart hook ───────────────────────────────

  # Given the hook's stdin JSON, start a detached `warm` for the subagent's soul
  # when its set has an item that is not fresh. Returns the soul it started, or
  # nil. Never raises: a hook must never stop a launch. +spawner+ takes the soul.
  def hook(payload, env: ENV, now: Time.now, spawner:)
    soul = JSON.parse(payload.to_s)["agent_type"].to_s
    return nil unless SLUG.match?(soul)

    cfg = config(env)
    return nil unless cfg.fetch("souls", {}).key?(soul)

    m = manifest(soul, cfg)
    return nil if m["items"].empty? || !due?(m, env: env, now: now)

    spawner.call(soul)
    soul
  rescue StandardError
    nil
  end

  # ── the admin tier (ruling 1) ─────────────────────────────────────────────

  # An admin value, read inside an allowlisted script's own process and kept in
  # its memory for the tier's lifetime. Nothing is written to disk and there is
  # no command that prints one. The soul folders are never consulted.
  module Admin
    class Refused < StandardError; end

    @memo = {}

    module_function

    def tooling_root
      File.expand_path("../..", __dir__)
    end

    # True when +program+ (a $PROGRAM_NAME) is one of the tier's scripts in this
    # tooling tree.
    def allowed?(program, tier, root: tooling_root)
      real = begin
        File.realpath(program.to_s)
      rescue SystemCallError
        return false
      end
      Array(tier["scripts"]).any? do |script|
        File.realpath(File.join(root, script.to_s)) == real
      rescue SystemCallError
        false
      end
    end

    def vault(tier, env)
      named = env[tier["vault_env"].to_s].to_s.strip
      named.empty? ? tier["default_vault"].to_s : named
    end

    # The value of op://<admin vault>/<item>/<field>, for an allowlisted script.
    def read(item, field, cfg:, env: ENV, program: $PROGRAM_NAME, now: Time.now, root: tooling_root)
      tier = SoulSecrets.validate_admin!(cfg["admin_tier"])
      unless allowed?(program, tier, root: root)
        SoulSecrets.log_admin_refusal(program, item, env: env)
        raise Refused, "secret: #{File.basename(program.to_s)} is not an admin-tier script; " \
                       "admin items are read only by the scripts config/soul_secret_sets.yml lists (logged)"
      end

      key = [item.to_s, field.to_s]
      hit = @memo[key]
      return hit[0] if hit && hit[1] > now

      value = fetch(tier, item, field, env)
      @memo[key] = [value, now + SoulSecrets.seconds(tier["lifetime"])]
      value
    end

    def fetch(tier, item, field, env)
      token = env[tier["token_env"].to_s].to_s
      raise SoulSecrets::Unavailable, "secret: #{tier['token_env']} is not set; the admin tier cannot read" if token.strip.empty?

      ref = "op://#{vault(tier, env)}/#{item}/#{field}"
      out = OpMeter.popen({ "OP_SERVICE_ACCOUNT_TOKEN" => token }, [SoulSecrets.op_bin(env), "read", ref],
                          via: "admin:#{item}", env: SoulSecrets.bounded_env(env), announce: false, err: File::NULL)
      raise SoulSecrets::Unavailable, "1Password is not answering (admin #{item})" if OpMeter.last_hung?
      raise SoulSecrets::Unavailable, "op could not read admin #{item}/#{field}" unless $?.success? && !out.to_s.strip.empty?

      out.to_s.chomp
    end

    # Tests only.
    def reset!
      @memo = {}
    end
  end

  def log_admin_refusal(program, item, env: ENV)
    OpMeter.record(action: "admin-refused", outcome: "refused", via: "admin:#{item}:#{File.basename(program.to_s)}", env: env)
  end
end
