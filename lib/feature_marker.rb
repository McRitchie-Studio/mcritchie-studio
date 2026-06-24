# frozen_string_literal: true

# Pure resolution for the per-session active-feature marker bin/task writes and
# bin/statusline reads. It guards one piece of derived state: the session's
# Pokémon mascot.
#
# The board assigns the mascot lazily — Task#sync_session_mascot runs on create
# and re-derives on every build-phase transition — so any single API response
# can momentarily lack it. Writing the marker straight from that one response
# would drop bin/statusline from its "⊙ <Mascot> · app · feature" form to the
# no-mascot fallback ("app · feature · <url> [stage]") and flip-flop back once
# the mascot reappeared. So the mascot resolves through a fallback chain that can
# NEVER downgrade a known mascot to blank — the same guarantee
# bin/agent-worktree.resolve_mascot gives the worktree .agent-context.json.
module FeatureMarker
  module_function

  # First present source wins; nil only when every source is blank. Each source
  # is a value OR a 0-arg callable, resolved left-to-right and SHORT-CIRCUITED —
  # a later source (e.g. a board API read) is never evaluated once an earlier one
  # (the response, then the last-good on-disk value) is present.
  def mascot(*sources)
    sources.each do |source|
      value = source.respond_to?(:call) ? source.call : source
      return value if present?(value)
    end
    nil
  end

  def present?(value)
    !value.nil? && !value.to_s.strip.empty?
  end
end
