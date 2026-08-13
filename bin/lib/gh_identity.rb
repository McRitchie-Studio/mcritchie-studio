# frozen_string_literal: true

# GhIdentity — the ONE mapping from "which lane is this session in" to "which
# GitHub App identity speaks for it".
#
# WHY IT IS ITS OWN FILE. Three places need this answer and each had its own idea
# of it: bin/gh-token hardcoded `agent`, GhAuthRetry hardcoded `agent`, and the
# SOPs/git credential helper drove the lane off `GH_APP_ITEM` — an env var the
# first two never read. So a ship session could export GH_APP_ITEM=deployer, watch
# `git push` correctly use the deployer App, and then have the very next `gh` call
# mint the AGENT App instead. The two Apps are scoped apart deliberately:
#
#   github.mcritchie-agent     build/review — contents, PULL REQUESTS, checks, actions, workflows
#   github.mcritchie-deployer  ship         — contents, actions, checks, secrets, and NO
#                                             pull_requests grant AT ALL, so a deployer
#                                             cannot open or merge a PR. By design.
#
# Handing a ship session the agent App therefore does not merely mislabel the audit
# trail — it grants `pull_requests: write` to the one lane the boundary exists to
# withhold it from. A boundary that any caller crosses by forgetting a flag is not a
# boundary, so the resolution lives in ONE place that all three callers share.
#
# PRECEDENCE: explicit > GH_APP_ITEM > agent. An explicit identity is a caller
# stating its lane outright (bin/ship genuinely needs the PR-writing App even when
# invoked from an odd shell), and that must still win over an ambient export.
module GhIdentity
  # identity => 1Password item name.
  IDENTITIES = {
    "agent" => "github.mcritchie-agent",
    "deployer" => "github.mcritchie-deployer"
  }.freeze

  # item name => identity. GH_APP_ITEM names the ITEM; --identity names the SHORT
  # name. Both spell the same lane, so both are understood.
  ITEMS = IDENTITIES.invert.freeze

  DEFAULT = "agent"

  module_function

  def known?(identity)
    IDENTITIES.key?(identity.to_s)
  end

  def item_for(identity)
    IDENTITIES[identity.to_s]
  end

  # The identity for this call, or nil when GH_APP_ITEM names something unknown.
  # nil is deliberately NOT coerced to the default: silently falling back to `agent`
  # on an unreadable instruction is the exact failure this module exists to end, so
  # the caller is made to decide (every one of them aborts).
  def resolve(explicit = nil, env: ENV)
    stated = explicit.to_s.strip
    return stated unless stated.empty?

    item = env["GH_APP_ITEM"].to_s.strip
    return DEFAULT if item.empty?

    ITEMS[item]
  end

  # Why a resolution failed, in the operator's words.
  def unknown_item_message(env: ENV)
    "GH_APP_ITEM=#{env['GH_APP_ITEM'].to_s.strip.inspect} names no known identity " \
      "(expected: #{ITEMS.keys.join(', ')})"
  end
end
