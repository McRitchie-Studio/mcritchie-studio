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
# Test seam: HEROKU_TOKEN_OP_BIN replaces the `op` binary.
require_relative "op_vaults"
require_relative "op_meter"

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
  # still exported in its own shell cannot vouch for the 1Password item).
  # Raises Unresolved with an operator-facing reason; never returns "".
  def resolve(name, env: ENV, from_env: true, op_bin: nil)
    spec = lane(name)
    if from_env
      spec[:env].each do |var|
        value = env[var].to_s.strip
        return value unless value.empty?
      end
    end
    read(name, spec, env, op_bin || env["HEROKU_TOKEN_OP_BIN"].to_s.then { |b| b.empty? ? "op" : b })
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
    env["HEROKU_API_KEY"] = token
    token
  end

  def read(name, spec, env, op_bin)
    op_lane = spec[:op_lane]
    token_var = OpVaults.token_env(op_lane)
    if env[token_var].to_s.strip.empty?
      raise Unresolved, "the #{name} lane reads #{spec[:item]} with #{token_var}, which is not set in this " \
                        "shell. #{remedy(op_lane)}"
    end

    op_env = { "OP_SERVICE_ACCOUNT_TOKEN" => env[token_var].to_s.strip }.merge(OpMeter::CACHE_BYPASS)
    value =
      begin
        OpMeter.popen(op_env, [op_bin, "read", ref(name)], via: "heroku-token", env: env, err: File::NULL)
      rescue SystemCallError => e
        raise Unresolved, "could not start the 1Password CLI (#{op_bin}): #{e.class}"
      end
    value = value.to_s.strip
    return value unless value.empty?

    raise Unresolved, "#{spec[:item]}/#{FIELD} read empty: 1Password timed out, refused (rate limit, " \
                      "vault grant) or the field is blank. Try again, or check `op-reads`."
  end

  def remedy(op_lane)
    profile = OpVaults.lane(op_lane)[:profile]
    "Run `source #{profile}` (without a pipe) and retry."
  end
end
