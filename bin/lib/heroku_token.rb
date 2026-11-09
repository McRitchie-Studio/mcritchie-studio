# frozen_string_literal: true

# HerokuToken — the ONE place a Heroku API token comes from on this Mac: the
# caller's environment when it set one on purpose, else the lane's 1Password
# item, read at the moment of use.
#
# WHY (2026-10-27). The shell profiles held the tokens as literals:
# ~/.zprofile exported HEROKU_API_KEY and ~/.zprofile.admin exported three
# HEROKU_STUDIO_*_API_KEY copies. A rotation updates 1Password, so every copy
# went stale the moment a key turned over: the agents key rotated on 2026-10-24,
# the profile kept the revoked value, and bin/heroku-secret-set 401'd on it.
# The profiles now export no Heroku value at all; this module reads the item
# each time a token is needed, so a rotation can never leave a stale copy.
#
# WHY NOT AT SHELL START. Background agents open many shells, and the op cache
# daemon can hang a read for about fifteen minutes (bin/lib/bounded_command.rb)
# or the service account can be rate-limited. Resolving three tokens in every
# shell would pay both costs for shells that never touch Heroku. A read here
# happens only when something actually calls Heroku without a token.
#
# BOUNDED. Every read runs through OpMeter.popen (bin/lib/op_meter.rb): a
# deadline (MCR_OP_DEADLINE, 20 s by default) and SIGKILL past it. The read
# also runs with OP_CACHE=false from the first attempt, so a hung cache daemon
# is never consulted at all.
#
# NEVER PRINTED. The value is returned to the caller, which puts it in a header
# or a child's environment. Refusals name the lane, the item and the cause,
# never the value; `op` stderr is discarded because it can quote the reference.
#
# LANES. Each names its item, its 1Password lane (which token can read it, per
# bin/lib/op_vaults.rb) and the environment names a caller may set to override:
#   agents        heroku.studio.agents, studio-agents (the agent token). What
#                 HEROKU_API_KEY meant in ~/.zprofile: deploys, config, run.
#   admin         heroku.studio.admin, studio-agents-admin (the admin token).
#                 The only key that can mint and revoke authorizations.
#   applications  heroku.studio.applications, studio-applications (the admin
#                 token). The CI deploy key, rotated by bin/rotate-heroku-ci-key.
#
# WHERE THE READ GOES (task secret-silos-phase-two, 2026-11-09). This file runs
# no `op` of its own any more:
#   agents        steffon's soul secret set (config/soul_secret_sets.yml) names
#                 heroku.studio.agents with this file as a reader. The key is
#                 served from steffon's cache folder for its lifetime (12 h), and
#                 1Password is read once on a miss. Any soul's process reads it
#                 through this file (SoulSecrets.reader_owner says why).
#   admin, applications
#                 admin-vault items: SoulSecrets::Admin.read, in the calling
#                 script's memory only, and only for the admin-tier scripts.
# A from_env: false read (--check, the migrator) reads 1Password fresh, under
# the soul's lock for the agents lane, and rewrites the cached copy.
#
# REFUSED BY HEROKU (#with_refresh). A rotated key is served from the cache until
# it expires. A caller that can see Heroku's 401 wraps its call in
# HerokuToken.with_refresh: one fresh read, one retry, a second 401 stops
# (bin/lib/auth_refresh.rb). A HEROKU_API_KEY that export_once! set is replaced
# by the fresh key, or removed when the refresh fails, so no child inherits the
# refused one. A key the CALLER exported is theirs: it is used once and never
# replaced.
#
# Test seam: HEROKU_TOKEN_OP_BIN replaces the `op` binary (passed on as
# SECRET_OP_BIN).
require "digest"
require_relative "op_vaults"
require_relative "op_meter"
require_relative "soul_secrets"

module HerokuToken
  FIELD = "credential"

  LANES = {
    agents: {
      item: "heroku.studio.agents",
      op_lane: :agent,
      env: %w[HEROKU_API_KEY HEROKU_STUDIO_AGENTS_API_KEY]
    },
    admin: {
      item: "heroku.studio.admin",
      op_lane: :deployer,
      env: %w[HEROKU_STUDIO_ADMIN_API_KEY]
    },
    applications: {
      item: "heroku.studio.applications",
      op_lane: :deployer,
      vault_env: "MCR_OP_VAULT_APPLICATIONS",
      default_vault: "studio-applications",
      env: %w[HEROKU_STUDIO_APPLICATIONS_API_KEY]
    }
  }.freeze

  # Every environment name a profile used to carry as a literal. The migrator
  # (bin/heroku-profile-migrate) removes assignments to exactly these.
  PROFILE_NAMES = LANES.values.flat_map { |l| l[:env] }.uniq.freeze

  class Unresolved < StandardError; end

  module_function

  def lane(name)
    LANES.fetch(name.to_s.to_sym) do
      raise Unresolved, "unknown Heroku lane #{name.inspect} (known: #{LANES.keys.join(', ')})"
    end
  end

  # The op:// reference for a lane's token.
  def ref(name)
    spec = lane(name)
    if spec[:default_vault]
      vault = ENV[spec[:vault_env]].to_s.strip
      vault = spec[:default_vault] if vault.empty?
      "op://#{vault}/#{spec[:item]}/#{FIELD}"
    else
      OpVaults.ref(spec[:item], FIELD, spec[:op_lane])
    end
  end

  # The token for +name+. The first non-empty override in +env+ wins unless
  # +from_env+ is false (the migrator's preflight passes false, so a stale value
  # still exported in its own shell cannot vouch for the 1Password item; that
  # read also skips the cache). Raises Unresolved with an operator-facing reason;
  # never returns "".
  def resolve(name, env: ENV, from_env: true, op_bin: nil, program: $PROGRAM_NAME)
    spec = lane(name)
    if from_env
      found = override(spec, env)
      return found if found
    end
    read(name, spec, env, op_bin, fresh: !from_env, program: program)
  end

  # The first non-empty override variable's value, or nil.
  def override(spec, env)
    spec[:env].each do |var|
      value = env[var].to_s.strip
      return value unless value.empty?
    end
    nil
  end

  # ONE read for a whole process tree. A long-running caller that shells out to
  # `heroku` many times (bin/release: every board op is a `heroku run`, and the
  # ship polls; bin/qa-server) calls this once, BEFORE its first write, so every
  # child, and the shim inside it, finds HEROKU_API_KEY already set and reads
  # nothing. Without it each call is its own 1Password read, and a ship that
  # exhausts the hourly quota fails a board write halfway (Carl, PR 2271).
  # Returns the token; raises Unresolved, so the caller refuses before acting.
  def export_once!(name = :agents, env: ENV, op_bin: nil)
    lane(name)
    current = env["HEROKU_API_KEY"].to_s.strip
    return current unless current.empty?

    token = resolve(name, env: env, op_bin: op_bin)
    export!(env, token)
    token
  end

  # Set HEROKU_API_KEY for children and remember (by digest, never the value)
  # that this process set it, so #with_refresh may replace it.
  def export!(env, token)
    env["HEROKU_API_KEY"] = token
    exported_digests << Digest::SHA256.hexdigest(token.to_s)
  end

  def exported_here?(token)
    !token.to_s.empty? && exported_digests.include?(Digest::SHA256.hexdigest(token.to_s))
  end

  def exported_digests
    @exported_digests ||= []
  end

  # Tests only.
  def reset!
    @exported_digests = []
  end

  # Heroku's refusal of a key, as the CLI and the API word it. A 403 is not one:
  # the key works and lacks access to that app, and a fresh read changes nothing.
  REFUSAL = /\bHTTP (?:Error )?401\b|Invalid credentials provided|\bunauthorized\b/i

  def refusal?(output)
    REFUSAL.match?(output.to_s)
  end

  # Call the block with the lane's token. When Heroku refuses it (the block
  # raises AuthRefresh::Rejected, or +rejected+ says so of its result), read the
  # item fresh from 1Password once and call the block once more
  # (bin/lib/auth_refresh.rb). Raises AuthRefresh::StillRefused or RefreshFailed,
  # or Unresolved when no token can be read at all.
  #
  #   HerokuToken.with_refresh(:agents, rejected: ->(res) { res.code == "401" }) { |token| api(token) }
  def with_refresh(name = :agents, env: ENV, rejected: nil, op_bin: nil, program: $PROGRAM_NAME, err: $stderr, &block)
    spec = lane(name)
    given = override(spec, env)
    # The caller's own key: used as given, never replaced from 1Password.
    return block.call(given) if given && !exported_here?(given)

    ours = !given.nil?
    hand = lambda do |token|
      export!(env, token) if ours
      block.call(token)
    end
    senv = secret_env(env, op_bin)
    if spec[:op_lane] == :deployer
      SoulSecrets::Admin.with_refresh(spec[:item], FIELD, service: "heroku", cfg: config!(name, spec, senv),
                                      env: senv, program: program, rejected: rejected, err: err,
                                      vault: admin_vault(spec, env), &hand)
    else
      owner, vault, cfg = owner!(name, spec, senv)
      SoulSecrets.with_refresh(owner, vault, spec[:item], service: "heroku", cfg: cfg, env: senv,
                                                         rejected: rejected, err: err) { |fields| hand.call(fields[FIELD].to_s) }
    end
  rescue AuthRefresh::Stop
    # The refused key never stays in this process's environment.
    env.delete("HEROKU_API_KEY") if ours
    raise
  rescue SoulSecrets::Admin::Refused, SoulSecrets::Refused, SoulSecrets::ConfigError, SecretCache::Unsafe => e
    raise Unresolved, "#{spec[:item]}/#{FIELD}: #{e.message}"
  rescue SoulSecrets::Unavailable, SystemCallError => e
    raise unavailable(name, spec, senv || env, e, op_bin)
  end

  # The marker line every copy of bin/shims/heroku carries.
  SHIM_MARKER = "# heroku-token-shim-marker"

  # Is the `heroku` this process would run the heroku-token shim? Only the shim
  # spends a 1Password read per call, so only then does a long run need
  # export_once!. A different `heroku` first on PATH (the real CLI with its own
  # login, a test's fake) never consults 1Password, and resolving for it would
  # read, or refuse, for nothing.
  def shim_on_path?(env = ENV)
    env["PATH"].to_s.split(File::PATH_SEPARATOR).each do |dir|
      next if dir.empty?

      path = File.join(dir, "heroku")
      next unless File.file?(path) && File.executable?(path)

      return File.foreach(path).first(40).any? { |line| line.start_with?(SHIM_MARKER) }
    end
    false
  rescue SystemCallError, IOError, ArgumentError
    false
  end

  READER = "bin/lib/heroku_token.rb"

  # The env the secret tooling reads: +op_bin+ (the test seam) as SECRET_OP_BIN.
  def secret_env(env, op_bin)
    bin = (op_bin || env["HEROKU_TOKEN_OP_BIN"]).to_s.strip
    bin.empty? || bin == "op" ? env.to_h : env.to_h.merge("SECRET_OP_BIN" => bin)
  end

  def config!(_name, spec, env)
    SoulSecrets.config(env)
  rescue SoulSecrets::ConfigError => e
    raise Unresolved, "#{spec[:item]}/#{FIELD}: #{e.message}"
  end

  # [soul, vault, cfg] for a soul-set lane: the soul whose set lists this file
  # as a reader of the item.
  def owner!(name, spec, env)
    cfg = config!(name, spec, env)
    vault = SoulSecrets.lane_vault(spec[:op_lane].to_s, env)
    owner = SoulSecrets.reader_owner(cfg, vault, spec[:item], READER)
    unless owner
      raise Unresolved, "the #{name} lane's #{vault}/#{spec[:item]} is in no soul set with #{READER} as a reader " \
                        "(config/soul_secret_sets.yml); nothing was read"
    end
    [owner, vault, cfg]
  end

  # The vault an admin-tier lane reads besides the tier's own, or nil.
  def admin_vault(spec, env)
    return nil unless spec[:default_vault]

    named = env[spec[:vault_env]].to_s.strip
    named.empty? ? spec[:default_vault] : named
  end

  def read(name, spec, env, op_bin, fresh: false, program: $PROGRAM_NAME)
    senv = secret_env(env, op_bin)
    value = spec[:op_lane] == :deployer ? admin_read(name, spec, senv, fresh, program) : soul_read(name, spec, senv, fresh)
    value = value.to_s.strip
    raise Unresolved, "#{spec[:item]}/#{FIELD} read empty: the field is blank in 1Password." if value.empty?

    value
  rescue SoulSecrets::Admin::Refused, SoulSecrets::Refused, SoulSecrets::ConfigError, SecretCache::Unsafe => e
    raise Unresolved, "#{spec[:item]}/#{FIELD}: #{e.message}"
  rescue SoulSecrets::Unavailable, SystemCallError => e
    raise unavailable(name, spec, senv, e, op_bin)
  end

  def admin_read(name, spec, env, fresh, program)
    cfg = config!(name, spec, env)
    vault = admin_vault(spec, env)
    SoulSecrets::Admin.forget(spec[:item], FIELD, vault: vault) if fresh
    SoulSecrets::Admin.read(spec[:item], FIELD, cfg: cfg, env: env, program: program, vault: vault)
  end

  def soul_read(name, spec, env, fresh)
    owner, vault, cfg = owner!(name, spec, env)
    entry = SoulSecrets.manifest(owner, cfg)["items"].find { |e| e["vault"] == vault && e["item"] == spec[:item] }
    # No token to read with and no fresh copy to serve: refuse before any `op`.
    if lane_token_missing?(owner, cfg, spec, env) && (fresh || SoulSecrets.state(owner, entry, env: env).first != :fresh)
      raise Unresolved, missing_token(name, spec)
    end

    fields = if fresh
               SoulSecrets.refresh_locked(owner, spec[:item], entry, cfg: cfg, env: env)
             else
               SoulSecrets.read(owner, vault, spec[:item], cfg: cfg, env: env)
             end
    fields[FIELD]
  end

  # Neither the owning soul's own service-account token nor the lane's.
  def lane_token_missing?(owner, cfg, spec, env)
    own = SoulSecrets.manifest(owner, cfg).dig("service_account", "token_env").to_s
    lane_var = OpVaults.token_env(spec[:op_lane])
    [own, lane_var].reject(&:empty?).all? { |var| env[var].to_s.strip.empty? }
  end

  def missing_token(name, spec)
    "the #{name} lane reads #{spec[:item]} with #{OpVaults.token_env(spec[:op_lane])}, which is not set in this " \
      "shell. #{remedy(spec[:op_lane])}"
  end

  # The Unresolved for a read that failed. Never the value; `op` stderr was
  # discarded at the read.
  def unavailable(name, spec, env, error, op_bin)
    return Unresolved.new(missing_token(name, spec)) if error.message.include?("is not set")
    if error.is_a?(SystemCallError) || error.message.include?("1Password CLI is not at")
      bin = (op_bin || env["SECRET_OP_BIN"] || SoulSecrets.op_bin(env)).to_s
      return Unresolved.new("could not start the 1Password CLI (#{bin}): #{error.class}")
    end
    # Hung, not refused: OpMeter has printed the line with the fix; point at it
    # rather than list causes that did not happen (release-survives-1password-hang).
    if OpMeter.last_hung?
      return Unresolved.new("#{spec[:item]}/#{FIELD}: 1Password is not answering (the line above names the fix).")
    end

    Unresolved.new("#{spec[:item]}/#{FIELD} read empty: 1Password timed out, refused (rate limit, " \
                   "vault grant) or the field is blank. Try again, or check `op-reads`.")
  end

  def remedy(op_lane)
    profile = OpVaults.lane(op_lane)[:profile]
    "Run `source #{profile}` (without a pipe) and retry."
  end
end
