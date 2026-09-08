# frozen_string_literal: true

# BlockRecipe — the copy-pasteable `bin/task block` commands the CLI PRINTS, held in
# ONE table so none of them can be printed without its acting soul.
#
# THE DEFECT THIS FILE EXISTS TO KILL (/tasks/breaker-remedy-omits-agent). When the
# two-bounce breaker trips, `bin/task block` refuses and prints two recipes — the
# operator ESCALATION and the mechanical BREAKER-ACK re-run. Neither carried
# `--agent`, and a bare block does NOT run as whoever pastes it:
# `resolved_block_actor` falls through an unset session persona to
# `default_block_actor`, which returns the LITERAL "avi" for rework-on-submitted and
# NIL for every other kind. Measured 2026-09-08 by executing both recipes verbatim:
#
#   the breaker-ack re-run, pasted by the reviewer it was printed for
#     → exit 11, ZERO writes. It resolves to "avi", which grades FOREIGN against the
#       reviewer's own live claim. The breaker hands the verdict owner a command the
#       verdict-owner gate then refuses him.
#   the same re-run with no live review claim
#     → exit 0, and it WRITES `by: "avi"` — a bounce recorded against a soul that did
#       nothing.
#   the escalation (`--kind dependency`)
#     → exit 0, and it WRITES `{"event":{"source":"cli"}}` — no `actor`, no `by`. THE
#       UNATTRIBUTED BLOCK. That entry lands in the task's AUTHOR SET, and
#       `bin/reviewer-select` then refuses to pick, because it cannot exclude a soul
#       it cannot name. The no-self-review property goes unverified for that review.
#
# WHY A TABLE AND NOT TWO METHODS. The escalation was a sibling of the filed defect,
# printed three lines above it by the same refusal, and it was the WORSE of the two —
# fixing only the coordinate on the ticket would have left the unattributed write in
# place. A recipe added as a bare string next year would arrive the same way. So the
# recipes are DATA, `TEMPLATES` is the whole set, and the unit guard enumerates the
# table rather than a hand-kept list: a row added here is covered the moment it exists.
#
# PURE. Nothing here reads the clock, the board, the environment, or the process tree —
# every fact arrives as an argument, so the whole table is exercisable at the unit tier.
module BlockRecipe
  # Printed in place of a soul the CLI genuinely could not resolve — `bin/task bounces`
  # run from a session carrying no persona marker, say. It is deliberately NOT a
  # runnable value: pasted into a shell unquoted, `<` is a redirection and the command
  # fails at the shell rather than recording a block against a soul named "<your-soul>".
  # A blank is what this whole file exists to prevent; a visible blank the reviewer
  # must fill is the honest form of one.
  UNKNOWN_SOUL = "<your-soul>"

  # `<slug>` and `<agent>` are substituted; every other `<…>` is a placeholder the
  # reader fills in, and is left exactly as written. The angle-bracket spelling is
  # deliberate — it is the shape test/docs/bounce_holder_rule_docs_test.rb's command
  # walk reads as an argument, so these recipes stay INSIDE that guard's sweep instead
  # of disappearing from it behind a `%<…>s` format token it cannot parse.
  TEMPLATES = {
    escalation: <<~CMD.chomp,
      bin/task block <slug> --kind dependency --agent <agent> \\
          --summary "Escalated: <4-6 word disagreement>" \\
          --feedback "<builder's position vs review's position, in brief>"
    CMD
    breaker_ack: 'bin/task block <slug> --kind rework ... --agent <agent> ' \
                 '--breaker-ack "red CI, mechanical"'
  }.freeze

  module_function

  # The soul to print — the caller's own when it resolved to one, else the visible
  # blank. `resolved_block_actor` returns "" when it cannot name anybody, and "" is
  # precisely the state in which a pasted block lands unattributed.
  def soul(agent)
    value = agent.to_s.strip
    value.empty? ? UNKNOWN_SOUL : value
  end

  def build(name, slug, agent: nil)
    TEMPLATES.fetch(name).gsub("<slug>", slug.to_s).gsub("<agent>", soul(agent))
  end

  def escalation(slug, agent: nil) = build(:escalation, slug, agent: agent)

  def breaker_ack(slug, agent: nil) = build(:breaker_ack, slug, agent: agent)

  # Every recipe in the table, built for one slug and soul. The guard enumerates THIS
  # rather than naming recipes one by one, so it cannot go stale against a new row.
  def all(slug, agent: nil)
    TEMPLATES.keys.map { |name| build(name, slug, agent: agent) }
  end
end
