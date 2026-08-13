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

  # The identity for this call, or nil when the instruction cannot be read.
  # nil is deliberately NOT coerced to the default: silently falling back to `agent`
  # on an unreadable instruction is the exact failure this module exists to end, so
  # the caller is made to decide (every one of them aborts).
  #
  # AN OMISSION AND AN EMPTY STATEMENT ARE DIFFERENT INSTRUCTIONS, and this is the only
  # place that can tell them apart. `nil` means the caller said nothing about its lane,
  # so the env and the default answer for it. An empty STRING means the caller reached
  # for a lane and handed over nothing — `--identity "$VAR"` with VAR unset, which is
  # ordinary shell — and that is a CALLER ERROR, not an omission. Reading it as "no
  # preference" is how `bin/gh-token --identity` went from aborting with `unknown
  # identity ""` to silently minting the App that holds `pull_requests: write`.
  #
  # THE GUARD LIVES HERE, NOT IN THE ARG LOOPS. Both CLIs produce exactly this
  # distinction already (`identity = nil` until the flag is seen, `args.shift.to_s.strip`
  # once it is), and putting the check in each caller is the arrangement this module was
  # extracted to end: a boundary every caller has to remember is not a boundary. Callers
  # already abort on nil, so an empty explicit reuses a refusal path all three share.
  def resolve(explicit = nil, env: ENV)
    unless explicit.nil?
      stated = explicit.to_s.strip
      return stated unless stated.empty?

      return nil
    end

    item = env["GH_APP_ITEM"].to_s.strip
    return DEFAULT if item.empty?

    ITEMS[item]
  end

  # Why a resolution failed, in the operator's words. TWO different causes reach the
  # same nil and they are fixed at different knobs, so the caller passes back what it
  # gave us: telling someone who never set GH_APP_ITEM that GH_APP_ITEM is wrong sends
  # them looking in the wrong place while they are already blocked.
  def unresolved_reason(explicit = nil, env: ENV)
    return empty_identity_message if !explicit.nil? && explicit.to_s.strip.empty?

    unknown_item_message(env: env)
  end

  def empty_identity_message
    "an identity was named but its value is empty (expected: #{IDENTITIES.keys.join(', ')}). " \
      "Refusing rather than falling back to #{DEFAULT}: an empty value usually means a shell " \
      "variable that was never set, and defaulting there hands out the PR-writing App"
  end

  def unknown_item_message(env: ENV)
    "GH_APP_ITEM=#{env['GH_APP_ITEM'].to_s.strip.inspect} names no known identity " \
      "(expected: #{ITEMS.keys.join(', ')})"
  end
end
