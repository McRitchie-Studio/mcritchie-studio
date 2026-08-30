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
# ISOLATION IS THE POINT, not a side effect — and what is isolated is the
# 1PASSWORD READ, which is narrower than it sounds. The admin token is NOT
# exported into ordinary agent shells, so a build lane cannot MINT an admin
# credential: `op` takes its credential from OP_SERVICE_ACCOUNT_TOKEN, so a
# caller minting an admin secret must run `op` with that variable set to the
# ADMIN token's value, which it can only do if the admin token is present in
# its environment at all. That refusal is the feature.
#
# SAY ONLY THAT MUCH, and the reason is worth keeping. This comment claimed the
# stronger property — that such a shell can never come to HOLD a deployer token —
# until 2026-08-29, when it was false: bin/gh-token served an already-minted one
# from its cache before minting, so `bin/gh-token --identity deployer` exited 0 in
# a shell that had never sourced ~/.zprofile.admin. That window is now CLOSED
# (`never-cache-deployer-token`): CACHEABLE_IDENTITIES = %w[agent], the check runs
# BEFORE the cache read, and any deployer slot an older version left behind is
# purged rather than merely ignored.
#
# The narrow claim is still the one to make. "Cannot mint" is enforced HERE, by
# the token map; "does not hold" is enforced in bin/gh-token, by the cache rule.
# Two mechanisms, and only the first is this file's to promise — a boundary
# described as wider than it is gets trusted for things it does not cover.
# Guarded by test/lib/credential_isolation_claims_test.rb.
module OpVaults
  # identity/purpose => { vault:, token_env: }
  #
  # `vault_env` lets a machine whose vaults are named differently override
  # without forking these scripts — the failure mode that produced this file.
  # `profile` is the file that CARRIES this lane's token once the machine is
  # provisioned. It exists so #diagnose can tell "you have not sourced it" from
  # "this machine has never been given one" — two states that need OPPOSITE
  # responses, and conflating them cost a full session on 2026-08-30 (see below).
  LANES = {
    agent: {
      vault_env: "MCR_OP_VAULT_AGENT",
      default_vault: "agents-studio",
      token_env: "OP_SERVICE_ACCOUNT_TOKEN",
      profile: "~/.zprofile"
    },
    deployer: {
      vault_env: "MCR_OP_VAULT_ADMIN",
      default_vault: "agents-admin",
      token_env: "OP_ADMIN_SERVICE_ACCOUNT_TOKEN",
      profile: "~/.zprofile.admin"
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

  # Where a lane's token file lives, expanded. Nil for a lane that declares none.
  def profile_path(name = DEFAULT_LANE)
    raw = lane(name)[:profile]
    raw && File.expand_path(raw)
  end

  # Whether this machine has been PROVISIONED for a lane — i.e. its token file is
  # on disk, whether or not the current shell has sourced it.
  def provisioned?(name = DEFAULT_LANE)
    path = profile_path(name)
    !path.nil? && File.exist?(path)
  end

  # Why a read failed, in the operator's terms — and, above all, WHAT TO RUN.
  #
  # THREE OUTCOMES, NOT TWO, and the third is why this was rewritten. The old
  # message had ONE branch for a missing token: "Run this from the admin lane, or
  # install the token with bin/setup-1pass-token --admin." Both halves failed the
  # reader. "Run this from the admin lane" names no command — the answer is one
  # line, `source ~/.zprofile.admin`, and this file was the only one in the repo
  # that even mentioned that path. And the remedy it DID name is an INSTALL, which
  # prompts for a credential the operator must fetch by hand — the wrong errand
  # entirely on a machine already provisioned, which is the common case.
  #
  # MEASURED 2026-08-30: an agent read that refusal, concluded the deployer lane
  # was not self-service, and asked Mr. McRitchie to hand-mint deployer tokens from
  # a downloaded .pem — repeatedly, blocking a production deploy on him. The token
  # had been installed at ~/.zprofile.admin since 2026-08-28. Sourcing it worked on
  # the first try. A tool that prescribes a human step it does not need is worse
  # than one that says nothing: it converts a self-service fix into operator toil,
  # which is exactly what AGENTS.md forbids.
  #
  # Same shape as bin/ecosystem-build's vault guard, and for the same reason: a
  # single else-branch sends every cause to one confident, specific, wrong errand.
  def diagnose(name = DEFAULT_LANE)
    spec = lane(name)
    if token(name).nil? && name.to_sym != DEFAULT_LANE
      base = "the #{name} lane needs #{spec[:token_env]} in the environment, and it is not set. " \
             "That is EXPECTED in an ordinary agent shell — admin credentials are deliberately " \
             "unreadable there. "
      if provisioned?(name)
        # PROVISIONED: self-service, no human. Name the command, and name the
        # export ordering too — GH_APP_ITEM is read by the credential helper at
        # mint time, so setting it afterwards silently yields the AGENT token,
        # a wrong-identity SUCCESS that is harder to notice than this refusal.
        base + "This machine IS provisioned — source it into THIS shell and retry:\n" \
               "    source #{spec[:profile]}\n" \
               "(For a git/gh ship lane also `export GH_APP_ITEM=github.mcritchie-deployer` " \
               "BEFORE minting; the helper reads it at mint time.)"
      else
        # NOT PROVISIONED: genuinely the operator's, once per machine.
        base + "This machine has no #{spec[:profile]} — install the token once:\n" \
               "    bin/setup-1pass-token --admin"
      end
    else
      "reading vault #{vault(name).inspect} (override with #{spec[:vault_env]}). " \
        "If that vault is not visible, check `op vault list` — a service account sees " \
        "only the vaults granted to it."
    end
  end
end
