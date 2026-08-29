# frozen_string_literal: true

# OpVaults — the ONE place that knows which 1Password vault holds which
# credential, and which service-account token can read it.
#
# WHY THIS EXISTS (2026-08-28, measured — not hypothesised). The vault name was
# hardcoded as "agents" in ELEVEN places across SIX files. When the operator
# switched 1Password to a SERVICE_ACCOUNT — which can see only the vaults
# granted to it — every one of them broke at once: `bin/gh-auth-refresh`
# reported "the broker produced no agent token" and every lane 401'd as its
# ~1h installation token lapsed. Eleven string literals meant eleven ways to
# fix it wrong, and the two obvious ones (bin/gh-token, bin/gh-app-git-
# credential) would have left NINE call sites broken — including bin/task,
# which is how every lane writes to the board.
#
# THE TRAP THIS ENCODES, and the reason the mapping is per-IDENTITY rather than
# one global vault name. `agents-studio` holds github.mcritchie-agent but NOT
# github.mcritchie-deployer. A blind repoint of everything to the reachable
# vault turns the AGENT lane green immediately — builds, PRs, merges — and
# breaks PRODUCTION DEPLOYS hours later, with the cause far behind the symptom.
# The two identities are separated on purpose: agent builds and merges,
# deployer cannot touch PRs. Do not collapse them.
#
# ISOLATION IS THE POINT, not a side effect. The admin token is NOT exported
# into ordinary agent shells, so a build lane that reaches for an admin
# credential FAILS. That failure is the feature. `op` takes its credential from
# OP_SERVICE_ACCOUNT_TOKEN, so a caller reading an admin secret must run `op`
# with that variable set to the ADMIN token's value — which it can only do if
# the admin token is present in its environment at all.
module OpVaults
  # identity/purpose => { vault:, token_env: }
  #
  # `vault_env` lets a machine whose vaults are named differently override
  # without forking these scripts — the failure mode that produced this file.
  LANES = {
    agent: {
      vault_env: "MCR_OP_VAULT_AGENT",
      default_vault: "agents-studio",
      token_env: "OP_SERVICE_ACCOUNT_TOKEN"
    },
    deployer: {
      vault_env: "MCR_OP_VAULT_ADMIN",
      default_vault: "agents-admin",
      token_env: "OP_ADMIN_SERVICE_ACCOUNT_TOKEN"
    }
  }.freeze

  # Shared, non-privileged agent credentials (the board secret, app keys) live
  # with the AGENT lane: every lane needs them, and nothing about them is admin.
  DEFAULT_LANE = :agent

  module_function

  def lane(name = DEFAULT_LANE)
    LANES.fetch(name.to_sym) do
      raise ArgumentError, "unknown 1Password lane #{name.inspect} (known: #{LANES.keys.join(', ')})"
    end
  end

  def vault(name = DEFAULT_LANE)
    spec = lane(name)
    value = ENV[spec[:vault_env]].to_s.strip
    value.empty? ? spec[:default_vault] : value
  end

  # The op:// reference for one field, in the right vault for this lane.
  def ref(item, field, name = DEFAULT_LANE)
    "op://#{vault(name)}/#{item}/#{field}"
  end

  def token_env(name = DEFAULT_LANE)
    lane(name).fetch(:token_env)
  end

  # The token this lane authenticates with, or nil when it is absent — which is
  # the EXPECTED state for the admin lane inside an ordinary agent shell.
  def token(name = DEFAULT_LANE)
    value = ENV[token_env(name)].to_s.strip
    value.empty? ? nil : value
  end

  # The env a child `op` needs. For the default lane this is {} — the ambient
  # OP_SERVICE_ACCOUNT_TOKEN already applies. For any other lane it REPLACES
  # OP_SERVICE_ACCOUNT_TOKEN with that lane's token, because `op` reads only
  # that one variable.
  def op_env(name = DEFAULT_LANE)
    return {} if name.to_sym == DEFAULT_LANE

    value = token(name)
    return {} if value.nil?

    { "OP_SERVICE_ACCOUNT_TOKEN" => value }
  end

  # Why a read failed, in the operator's terms. Callers print this instead of a
  # bare "op read failed", because the two causes need opposite responses:
  # a MISSING token is a provisioning step, a WRONG vault is a config override.
  def diagnose(name = DEFAULT_LANE)
    spec = lane(name)
    if token(name).nil? && name.to_sym != DEFAULT_LANE
      "the #{name} lane needs #{spec[:token_env]} in the environment, and it is not set. " \
        "That is EXPECTED in an ordinary agent shell — admin credentials are deliberately " \
        "unreadable there. Run this from the admin lane, or install the token with " \
        "bin/setup-1pass-token --admin."
    else
      "reading vault #{vault(name).inspect} (override with #{spec[:vault_env]}). " \
        "If that vault is not visible, check `op vault list` — a service account sees " \
        "only the vaults granted to it."
    end
  end
end
