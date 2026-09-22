# frozen_string_literal: true

# THE REMEDY A REFUSAL PRINTS MUST BE ONE THE GATE WOULD ACCEPT.
#
# Standalone — no Rails; the integration tier shells bin/dor-check with --file
# fixtures:
#   ruby -Itest test/lib/dor_check_remedy_honoured_test.rb
#
# ==== THE DEFECT (/tasks/red-ci-offers-dead-remedy) ==========================
#
# bin/dor-check#suite_evidence_error ended two of its branches with a flat
# "; or certify locally in full: bin/full-suite-check <slug>." — unconditionally,
# on every CI state those branches could reach, RED among them. On a red CI the
# CI gate's own refusal is not cert-clearable, so performing that command returns
# a BYTE-IDENTICAL verdict: ready=false, exit 1. The gate asked a builder for a
# ~30-minute suite run and then refused the result of running it.
#
# It is the same shape as /tasks/exempt-refusal-prints-dead-remedy — closed on the
# EXEMPT path, alive on the RED one — and this instance is worse in one specific
# way: it is printed by the GATE ITSELF, which is strictly more authoritative than
# the prose surfaces PR #1522 spent a night correcting. A gate that prints a remedy
# it will not honour teaches the reader to skim gates, and a skimmed gate is how a
# genuinely red CI reaches production.
#
# ==== WHY THIS FILE IS THE GENERAL PROPERTY, NOT THE SPECIFIC STRING =========
#
# Pinning "does the red refusal mention full-suite-check" would pin this instance
# and nothing else — and this is the SECOND instance of one shape, which is the
# signal that the shape is what wants a guard. So the property asserted here is:
#
#   for every (evidence, CI state, role) cell that produces a suite refusal,
#   the refusal offers the local-full-cert escape IFF performing it would
#   actually produce a MET verdict for that same cell.
#
# BOTH DIRECTIONS, deliberately. An over-offering gate costs a suite run (the
# filed defect); an under-offering one blocks a reader with no route named, which
# is the mistake a correction of the first is most likely to make. A test that
# only refuted the over-offer would green a fix that withheld the escape
# everywhere.
#
# AND IT EXECUTES THE PROMISE rather than reasoning about it. Each refusal is
# re-driven through the SAME cell with DOR_CHECK_SUITE_EVIDENCE=ok — which is
# exactly what bin/full-suite-check produces (a fresh "[full-suite@<fp>]" +
# "[rubocop@<fp>]" pair, graded `ok` by FullSuiteGate) — and the verdict that
# comes back is the answer. The precedent is
# test/lib/dor_check_exempt_ci_test.rb's honour-the-remedy property, which closed
# the first instance of this shape the same way.
#
# ==== SCOPE — the refusals this property does NOT cover, and why ==============
#
# suite_evidence_error has two other branches that name bin/full-suite-check: the
# MISSING-cert branch at its foot and the STALE-deferral branch. Neither is in
# scope and neither is conditioned in bin/dor-check, because they are a different
# claim. They never read CI, and what they ask for is the gate's OWN missing or
# stale evidence — which the task owes whatever CI says, so the command is
# NECESSARY there even on a red CI, merely not sufficient. The two branches this
# file drives interpolate the CI STATE and then offer the escape as the
# alternative TO the CI guidance they just gave, which is a claim that it CLEARS
# the verdict. That claim is the one that can be false.

require "minitest/autorun"
require "json"
require "tmpdir"
require_relative "../support/session_env"
require_relative "../support/outbound_seams"
require_relative "../../bin/lib/ci_gate"
require_relative "../../bin/lib/ci_status"

class DorCheckRemedyHonouredTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)
  PR_URL = "https://github.com/McRitchie-Studio/myapp/pull/7"
  CODE_DIFF = "app/models/thing.rb"

  # The escape clause under measurement. `CiStatus.unreadable_remedy` says "certify
  # in full instead", NOT "certify LOCALLY in full", so this matches the clause
  # bin/dor-check#full_cert_escape emits and not the one a guidance arm embeds.
  ESCAPE = /certify locally in full/i
  # The sentence printed in its place when the route is closed. Matched separately
  # because SILENCE is not a denial — see the assertion that uses it.
  DENIAL = /no local-cert route out of this one/i

  # The two evidence states whose refusal NAMES the CI state and then offers the
  # escape — the branches this property covers (see the SCOPE note in the header).
  # The tokens are FullSuiteGate's injected-verdict vocabulary.
  EVIDENCE = { "fast cert" => "fast_fresh", "deferred receipt" => "deferred_fresh" }.freeze

  # ── the fixture ─────────────────────────────────────────────────────────────

  def devops(pr_url: PR_URL)
    {
      "kind" => "feature", "shape" => "backend", "pr_url" => pr_url,
      "acceptance" => ["The gate refuses an under-tested PR"],
      "repositories" => ["myapp"], "risk_tags" => ["agent-ops"],
      "test_plan" => ["[unit] a", "[integration] b"],
      "checks_run" => ["[unit] ran a", "[integration] ran b"],
      "post_deploy_cmd" => "none", "branch" => "feat/probe-task",
      "worktree_slug" => "probe-task"
    }
  end

  # Drives the REAL gate. DOR_CHECK_CI_STATUS injects at CiStatus.evaluate and
  # DOR_CHECK_SUITE_EVIDENCE at FullSuiteGate.evaluate — both replace a read, and
  # neither replaces the message under measurement.
  def drive(cert:, ci:, role:)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate("slug" => "probe-task", "title" => "T",
                                     "metadata" => { "devops" => devops }))
      env = OutboundSeams.env({
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => CODE_DIFF, "DOR_CHECK_PR_FILES" => CODE_DIFF,
        "DOR_CHECK_CI_STATUS" => ci, "DOR_CHECK_SUITE_EVIDENCE" => cert
      })
      out = IO.popen(env, "#{BIN} probe-task --file #{path} --json --gate-role #{role} 2>/dev/null", &:read)
      code = $?.exitstatus
      refute_empty out.to_s.strip, "the gate produced no JSON at all — nothing below read anything"
      [JSON.parse(out), code]
    end
  end

  # The suite gate's own refusal, picked out of the verdict's errors. Keyed on the
  # two opening clauses those branches are built from, so a CI refusal raised
  # beside it is never mistaken for it.
  def suite_refusal(verdict)
    Array(verdict["errors"]).find { |e| e =~ /fast-cert evidence is FRESH|cert was DEFERRED to GitHub CI/ }
  end

  # ── [unit] the predicate the escape is conditioned on ───────────────────────
  #
  # bin/dor-check hands `cert_route_open:` down from the CI gate's own two return
  # values (`ci_error.nil? || ci_error_cert_clears`), so THIS is the fact the
  # printed escape now rests on. Asserted here without spawning anything, because
  # a wrong answer here is wrong in every cell below at once.

  # MEASURED 2026-09-22 by driving bin/dor-check with DOR_CHECK_SUITE_EVIDENCE=ok
  # against this fixture, every state, both roles: true where the run came back
  # ready (exit 0), false where it came back NOT MET (exit 1).
  #
  # TWO CELLS ARE THE POINT. `red` is the filed defect, closed in BOTH roles.
  # `pending`/review is a CORRECTION to the card that filed it, which recorded
  # that a local full cert DOES satisfy review on a pending CI — it does not, and
  # the reason is structural: :pending is deliberately NOT a member of
  # CiGate::CI_NO_VERDICT_STATES ("the answer is COMING", not "the answer was
  # never GIVEN"), so review's allow-list refuses it with cert_clears false.
  FULL_CERT_ROUTE = {
    "green" => { builder: true,  review: true },
    "none" => { builder: true,  review: true },
    "unverified" => { builder: true,  review: true },
    "unreadable" => { builder: true,  review: true },
    "pending" => { builder: true,  review: false },
    "no_pr" => { builder: true,  review: false },
    "red" => { builder: false, review: false },
    "conflicted" => { builder: false, review: false },
    "ci_less" => { builder: false, review: false },
    "closed" => { builder: false, review: false },
    "merged" => { builder: false, review: false }
  }.freeze

  def route_open?(state, role)
    ci_error, cert_clears, = CiGate.verdict({ state: state.to_sym, failing: ["ci"], pending: ["ci"] },
                                            review_role: role == :review, pr_url: PR_URL, slug: "probe-task")
    ci_error.nil? || cert_clears
  end

  def test_unit_the_ci_gate_closes_the_full_cert_route_on_a_red_ci_in_both_roles
    %i[builder review].each do |role|
      refute route_open?("red", role),
             "CiGate says a FULL local cert clears a RED CI in the #{role} role. It does not — the :red arm " \
             "sets a refusal and marks it NOT cert-clearable, and a measured run returns ready=false, exit 1 " \
             "with the cert in place. If this ever becomes true on purpose, the escape in " \
             "bin/dor-check#full_cert_escape follows it automatically; what must not happen is this assertion " \
             "being relaxed to make a message read better."
    end
  end

  def test_unit_every_ci_state_the_reader_can_emit_has_a_measured_route
    CiStatus::TOKENS.each do |token|
      measured = FULL_CERT_ROUTE[token]

      refute_nil measured,
                 "bin/lib/ci_status.rb emits the CI state #{token.inspect} and this table does not record it. " \
                 "The escape is conditioned on the CI gate's own answer, so a new state is already handled " \
                 "correctly — what is missing is the RECORD that somebody checked which way it goes. Drive it: " \
                 "DOR_CHECK_SUITE_EVIDENCE=ok DOR_CHECK_CI_STATUS=state:#{token} bin/dor-check <slug> " \
                 "--file <task.json> --json --gate-role builder (then again with review), and add the row."

      %i[builder review].each do |role|
        assert_equal measured[role], route_open?(token, role),
                     "CiGate and this measured table disagree about #{token}/#{role}. The table was driven " \
                     "through the whole gate; CiGate.verdict is what bin/dor-check reads. One of them moved. " \
                     "Re-drive the cell before editing either — the refusal's wording is chosen from this answer."
      end
    end
  end

  # ── [integration] the printed remedy, executed ──────────────────────────────

  # Every cell that produces a suite refusal, with the verdict a FULL cert gets in
  # that same cell. Returns [label, refusal, met_with_full_cert, exit_with_full_cert].
  def refusal_cells
    cells = []
    EVIDENCE.each do |evidence_label, cert|
      CiStatus::TOKENS.each do |token|
        %w[builder review].each do |role|
          verdict, = drive(cert: cert, ci: "state:#{token}", role: role)
          refusal = suite_refusal(verdict)
          next unless refusal

          with_cert, code = drive(cert: "ok", ci: "state:#{token}", role: role)
          cells << ["#{evidence_label} + #{token} CI, #{role}", refusal, with_cert["ready"] == true, code]
        end
      end
    end
    cells
  end

  def test_integration_every_printed_escape_is_one_the_gate_would_accept
    cells = refusal_cells

    # NOT VACUOUS, proven rather than assumed: the property below is a biconditional,
    # so a run that inspected only offering cells (or only withholding ones) would
    # exercise half of it and report a pass for the whole.
    offered = cells.count { |_, refusal, _, _| refusal.match?(ESCAPE) }
    withheld = cells.size - offered
    assert_operator offered, :>, 0, "no refusal in the matrix offered the escape at all — this run proved nothing " \
                                    "about over-offering. Check the fixture still reaches suite_evidence_error."
    assert_operator withheld, :>, 0, "every refusal in the matrix offered the escape — either the conditioning was " \
                                     "removed, or the fixture no longer reaches a closed-route state. This run " \
                                     "proved nothing about the defect it exists for."

    cells.each do |label, refusal, met_with_full_cert, code|
      if refusal.match?(ESCAPE)
        assert met_with_full_cert,
               "#{label}: the refusal PRINTS `certify locally in full`, and performing it does NOT clear this " \
               "verdict — re-driven with a FULL cert (the evidence bin/full-suite-check records) the gate still " \
               "answers NOT MET, exit #{code}. That is a ~30-minute command offered as a fix for a state it " \
               "cannot fix, which is the whole subject of /tasks/red-ci-offers-dead-remedy. The fix is to let " \
               "bin/dor-check#full_cert_escape decide from `cert_route_open`, which is the CI gate's own answer " \
               "for this cell — do not special-case the state here.\n\n#{refusal}"
      else
        refute met_with_full_cert,
               "#{label}: the refusal WITHHOLDS the escape, but a FULL cert DOES clear this verdict here — " \
               "re-driven with one, the gate answers ready, exit #{code}. Withholding a live remedy is the " \
               "opposite error and costs a round trip: the reader is blocked with no route named. Same fix, " \
               "same place — `cert_route_open` already carries the right answer for this cell.\n\n#{refusal}"

        assert_match DENIAL, refusal,
                     "#{label}: the escape is correctly withheld, but nothing SAYS so. It was printed on this " \
                     "branch for months, so a reader who simply stops seeing it concludes the gate forgot and " \
                     "runs the suite anyway — the cost this change exists to remove, paid in silence. Say what " \
                     "does not work: CiGate's `cert_route: false` branch is the house precedent and the " \
                     "wording.\n\n#{refusal}"
      end
    end
  end

  # THE FILED CELL, named. The property above would hold if `red` never reached a
  # refusal at all, so this pins that the defect's own cell is still driven and
  # still lands on the closed side — in BOTH roles, which is where the card that
  # filed it and the first fix of its sibling each covered only one.
  def test_integration_a_red_ci_refusal_names_fixing_ci_and_not_a_local_cert
    EVIDENCE.each_value do |cert|
      %w[builder review].each do |role|
        verdict, code = drive(cert: cert, ci: "state:red", role: role)
        refusal = suite_refusal(verdict)

        refute_nil refusal,
                   "the #{cert}/red/#{role} cell produced no suite refusal, so every assertion below it is " \
                   "about a branch this run never reached.\n#{verdict["errors"].inspect}"
        assert_equal 1, code
        refute_match ESCAPE, refusal,
                     "the #{cert}/red/#{role} refusal still offers a local full cert. Measured: a FULL cert " \
                     "against a RED CI is NOT MET, exit 1 — red is cleared by fixing the failing checks (or " \
                     "re-running a flaky one) and pushing, in both roles.\n\n#{refusal}"
        assert_match(/\bRED\b/, refusal,
                     "the #{cert}/red/#{role} refusal no longer says what CI reported. Naming the state is what " \
                     "lets a reader tell this refusal from the evidence-shaped ones beside it.\n\n#{refusal}")

        # THE SECOND DEAD REMEDY IN THE SAME SENTENCE, and the one that hid the
        # first. Before the :red arm existed, red fell through to the role split at
        # the foot of the chain and the BUILDER was told to "push the branch and open
        # the PR, then re-run dor-check" — on a PR that is open and whose checks have
        # already reported, which is the only way this refusal can be reached at all.
        # It is the rolio bug one state over: an instruction whose precondition is
        # already satisfied, so following it changes nothing.
        refute_match(/open the PR/i, refusal,
                     "the #{cert}/red/#{role} refusal tells the reader to open the PR. A red CI is a REPORT " \
                     "from checks that ran on a PR that exists — this refusal is unreachable without one, so " \
                     "that instruction has already been carried out and cannot be carried out again. Say what " \
                     "is left to do, which is to fix the failing checks or re-run a flaky one, and " \
                     "push.\n\n#{refusal}")
      end
    end
  end
end
