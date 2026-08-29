# frozen_string_literal: true

# [unit] OpVaults — the ONE place that maps a credential lane to its 1Password
# vault and service-account token.
#
# THE DEFECT THIS EXISTS TO PREVENT (2026-08-28). The vault name "agents" was
# hardcoded in eleven places across six files. When the operator switched to a
# 1Password SERVICE_ACCOUNT — which sees only the vaults granted to it — every
# lane lost GitHub auth at once, and the two obvious fixes would have left nine
# call sites broken, including bin/task.
#
# THE SHARPER DEFECT, and why `test_a_build_lane_cannot_reach_admin_credentials`
# is the most important test in this file: `agents-studio` holds the AGENT app
# item but not the DEPLOYER one. Repointing everything at the reachable vault
# turns the build lane green immediately and breaks PRODUCTION DEPLOYS hours
# later. The lanes must resolve to DIFFERENT vaults, and the admin lane must be
# unreadable without its own token.

require "bundler/setup"
require "minitest/autorun"
require_relative "../../bin/lib/op_vaults"

class OpVaultsTest < Minitest::Test
  def setup
    @saved = ENV.to_h.slice("MCR_OP_VAULT_AGENT", "MCR_OP_VAULT_ADMIN",
                            "OP_SERVICE_ACCOUNT_TOKEN", "OP_ADMIN_SERVICE_ACCOUNT_TOKEN")
    %w[MCR_OP_VAULT_AGENT MCR_OP_VAULT_ADMIN].each { |k| ENV.delete(k) }
  end

  def teardown
    %w[MCR_OP_VAULT_AGENT MCR_OP_VAULT_ADMIN
       OP_SERVICE_ACCOUNT_TOKEN OP_ADMIN_SERVICE_ACCOUNT_TOKEN].each { |k| ENV.delete(k) }
    @saved.each { |k, v| ENV[k] = v }
  end

  def test_the_two_lanes_resolve_to_different_vaults
    refute_equal OpVaults.vault(:agent), OpVaults.vault(:deployer),
                 "agent and deployer MUST NOT share a vault — agents-studio carries the " \
                 "agent app item and not the deployer's, so collapsing them turns the " \
                 "build lane green while breaking production deploys silently"
  end

  def test_each_lane_reads_its_own_token_variable
    refute_equal OpVaults.token_env(:agent), OpVaults.token_env(:deployer),
                 "a shared token variable would defeat the isolation entirely"
  end

  # THE ISOLATION ITSELF. `op` takes its credential from OP_SERVICE_ACCOUNT_TOKEN
  # and nothing else, so an admin read is only possible when op_env REPLACES it.
  # In an ordinary agent shell the admin token is absent, op_env is empty, and
  # the read proceeds with the agent token — which cannot see the admin vault.
  # That failure IS the feature.
  def test_a_build_lane_cannot_reach_admin_credentials
    ENV["OP_SERVICE_ACCOUNT_TOKEN"] = "ops_agent_token"
    ENV.delete("OP_ADMIN_SERVICE_ACCOUNT_TOKEN")

    assert_nil OpVaults.token(:deployer),
               "an agent shell must not carry the admin token"
    assert_empty OpVaults.op_env(:deployer),
                 "with no admin token, op_env must NOT override OP_SERVICE_ACCOUNT_TOKEN — " \
                 "silently substituting the agent token would hand a build lane the admin " \
                 "vault the moment that vault were ever granted to it"
  end

  def test_the_admin_token_replaces_the_op_credential_when_present
    ENV["OP_SERVICE_ACCOUNT_TOKEN"] = "ops_agent_token"
    ENV["OP_ADMIN_SERVICE_ACCOUNT_TOKEN"] = "ops_admin_token"

    assert_equal({ "OP_SERVICE_ACCOUNT_TOKEN" => "ops_admin_token" },
                 OpVaults.op_env(:deployer),
                 "op reads only OP_SERVICE_ACCOUNT_TOKEN, so the admin lane must replace it")
    assert_empty OpVaults.op_env(:agent),
                 "the default lane must not rewrite the ambient token"
  end

  def test_an_override_redirects_a_lane_without_forking_the_scripts
    ENV["MCR_OP_VAULT_AGENT"] = "some-other-vault"

    assert_equal "some-other-vault", OpVaults.vault(:agent)
    assert_equal "op://some-other-vault/Item/field", OpVaults.ref("Item", "field", :agent)
  end

  def test_an_unknown_lane_raises_rather_than_defaulting
    error = assert_raises(ArgumentError) { OpVaults.vault(:nope) }

    assert_match(/unknown 1Password lane/, error.message,
                 "a typo'd lane must fail loudly — quietly falling back to the agent " \
                 "vault is how an admin credential ends up read by a build lane")
  end

  def test_the_diagnosis_names_the_missing_token_not_a_bare_read_failure
    ENV.delete("OP_ADMIN_SERVICE_ACCOUNT_TOKEN")

    assert_match(/OP_ADMIN_SERVICE_ACCOUNT_TOKEN/, OpVaults.diagnose(:deployer),
                 "a missing token and a wrong vault need opposite responses, so the " \
                 "message must distinguish them")
  end
end
