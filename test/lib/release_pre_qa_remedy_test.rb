# frozen_string_literal: true

# [unit] What the G3 pre-QA gate says when it CANNOT READ GitHub CI: pre_qa_ci_abort's
# :unreadable branch must not take CiStatus.unreadable_remedy's default cert_route: `true`,
# which offers `bin/full-suite-check <task>`. GitHub's verdict for origin/release's tip IS the
# gate, and `<task>` is unfillable: the subject is a release SHA carrying MANY tasks. A refusal
# naming the wrong remedy is worse than none, because the reader ACTS on it. Lives in its own
# file: the release CLI pre-QA gate tests are frozen in config/test_health.yml. `eval_helper` is
# re-implemented, not shared: see test/lib/release_auth_remedy_message_test.rb.
# History: task release-offers-retired-cert.
require "minitest/autorun"
require "open3"
require_relative "../support/session_env"
require_relative "../../bin/lib/ci_status"

class ReleasePreQaRemedyTest < Minitest::Test
  BIN = File.expand_path("../../bin/release.rb", __dir__)

  # The two halves of the contract, spelled ONCE. "no local cert stands in" is the
  # clause test/lib/dor_check_exempt_ci_test.rb reads to decide what a gate PROMISED,
  # so a denial must carry it verbatim rather than paraphrase it.
  DENIES_CERT = "no local cert stands in"
  OFFERS_CERT = "certify in full instead"

  # Every cause the remedy classifies, because the route is chosen INDEPENDENTLY of
  # the cause and a spot-check on one cause would not notice a branch that leaks the
  # offer back on the others.
  CAUSES = [:permissions, :credentials, :authentication, :rate_limit, :forbidden, nil].freeze

  # ── the G3 refusal itself ───────────────────────────────────────────────────

  def test_the_unreadable_g3_abort_denies_the_cert_route_on_every_cause
    CAUSES.each do |cause|
      message = abort_message(:unreadable, cause: cause)

      assert_includes message, DENIES_CERT,
                      "#{cause.inspect}: G3 retired the local-cert route, so the refusal must SAY a cert " \
                      "does not stand in:\n#{message}"
      refute_includes message, OFFERS_CERT,
                      "#{cause.inspect}: this is the defect — offering a certification on a gate that " \
                      "advances on a GREEN CI and nothing else:\n#{message}"
      refute_includes message, "bin/full-suite-check",
                      "#{cause.inspect}: naming the cert command is the offer wearing different words"
    end
  end

  # THE SECOND HALF, and it is not cosmetic: `<task>` asks the reader for a value this
  # gate has no way of having. G3 is release-grain, so the command it names must be
  # the one an operator can actually run — spelled as the sibling abort branches in
  # pre_qa_ci_abort spell it.
  def test_the_unreadable_g3_abort_names_a_runnable_command_not_a_placeholder
    CAUSES.each do |cause|
      message = abort_message(:unreadable, cause: cause)

      refute_includes message, "<task>",
                      "#{cause.inspect}: a release-grain gate cannot name a task slug — the placeholder " \
                      "was unfillable, not merely ugly:\n#{message}"
      assert_includes message, "re-run `bin/release prepare`",
                      "#{cause.inspect}: the reader is blocked; the one instruction they get must be a " \
                      "command that exists and applies here"
    end
  end

  # ADVICE IS A FAILURE-PATH ARTIFACT — read only by someone already blocked — so a
  # command it names that does not exist wastes the one instruction they get. The
  # property, not a spelling: the same guard ci_status_test.rb runs over the DEFAULT
  # route, run here over the retired one, which that test never reaches.
  def test_every_command_the_retired_route_names_actually_exists
    root = File.expand_path("../..", __dir__)

    CAUSES.each do |cause|
      text = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: cause, release_grain: true)

      text.scan(%r{\bbin/[a-z0-9][a-z0-9._-]*}).uniq.each do |rel|
        path = File.join(root, rel)
        assert File.exist?(path), "retired route for #{cause.inspect} names #{rel}, which does not exist"
        assert File.executable?(path), "retired route for #{cause.inspect} names #{rel}, which is not executable"
      end
    end
  end

  # ── the premise, pinned ─────────────────────────────────────────────────────
  # THE DENIAL IS ONLY HONEST IF IT IS TRUE, and that is a property of bin/release.rb: nothing
  # replaced the DEMOTED pre-QA suite, so there is no certification to consult. Asserted against
  # the SOURCE with comments stripped, since the fix's own comments name bin/full-suite-check. If
  # G3 gets a real cert path, this fails and sends the author back to the sentence.
  # History: task release-offers-retired-cert.
  def test_the_release_gate_holds_no_certification_the_remedy_could_have_named
    code = File.readlines(BIN).reject { |line| line.strip.start_with?("#") }.join

    %w[full-suite-check fast-check full_cert fast_cert].each do |mechanism|
      refute_includes code, mechanism,
                      "bin/release.rb now names #{mechanism} in CODE — if a local certification can reach " \
                      "the G3 verdict, the retired-route denial above has stopped being true and must be " \
                      "re-decided, not left standing"
    end
  end

  # THE CONTROL FOR THE FIXTURE, in both directions. A run that quietly took some
  # OTHER branch of pre_qa_ci_abort would make every assertion above pass while
  # testing nothing — so prove :unreadable reaches the credential remedy, and that the
  # branches on either side of it do NOT (a red CI is a regression, not a token
  # fault, and prescribing a credential fix for it would be the mirror defect).
  def test_only_the_unreadable_branch_carries_the_credential_remedy
    unreadable = abort_message(:unreadable, cause: :permissions)
    assert_includes unreadable, "CREDENTIAL fault or API limit",
                    "the :unreadable fixture must actually reach the shared remedy, or these tests " \
                    "assert nothing:\n#{unreadable}"

    red = abort_message(:red, cause: nil, extra: ", failing: [\"rails\"]")
    assert_includes red, "regression is riding", "the :red branch is the eject/revert recovery"
    refute_includes red, "CREDENTIAL fault", "a red CI is not a token fault"
    refute_includes red, DENIES_CERT
    refute_includes red, OFFERS_CERT

    held = abort_message(:pending, cause: nil)
    assert_includes held, "poll timed out", "the else branch is the HELD, poll-exhausted verdict"
    refute_includes held, "CREDENTIAL fault", "a pending CI is not a token fault"
    refute_includes held, OFFERS_CERT,
                    "no G3 branch may offer a certification — the route is retired for the whole gate"
  end

  # ── the route is a SECOND one, not a reuse ──────────────────────────────────
  #
  # The task grain (`release_grain: false`, the default) denies too — since
  # /tasks/dor-reads-settled-ci-verdict they print ONE denial, resting on "a settled
  # green CI for the PR's head is the only suite evidence the gate credits". That
  # premise is about a TASK's PR; a release SHA has no PR and nobody exempted it, so
  # G3 keeps its own sentence rather than borrowing that one. This is the assertion
  # that fails if someone collapses the two.
  def test_the_retired_route_denies_for_its_own_reason_not_the_task_grain_one
    retired = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: :permissions,
                                                                             release_grain: true)
    exempt  = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: :permissions,
                                                                             release_grain: false)
    gated   = CiStatus.unreadable_remedy("McRitchie-Studio/mcritchie-studio", cause: :permissions)

    assert_includes retired, DENIES_CERT
    refute_includes retired, "the PR's current head",
                    "a release SHA has no PR — borrowing the task-grain sentence would state a " \
                    "false premise:\n#{retired}"
    refute_includes retired, "already waived",
                    "nothing was waived at G3; the route was RETIRED, which is a different fact"
    assert_includes retired, "RELEASE-grain", "the denial must say WHY it denies, not merely that it does"

    assert_equal exempt, gated, "the default and false are one task-grain denial — neither offers a cert"
    assert_includes gated, DENIES_CERT
    refute_includes gated, OFFERS_CERT, "the old gated offer is retired with the receipts it named"

    refute_equal retired, exempt, "two routes that print the same string are one route with two names"
  end

  private

  # Builds a G3 abort message by loading bin/release.rb standalone, exactly as
  # test/lib/release_auth_remedy_message_test.rb does for the ship lane's auth text.
  def abort_message(state, cause:, extra: "")
    ci = "{ state: #{state.inspect}, cause: #{cause.inspect}, reason: \"403 refused\"#{extra} }"
    eval_helper(%(pre_qa_ci_abort("mcritchie-studio", "a" * 40, #{ci})))
  end

  def eval_helper(expr)
    out, err, status = Open3.capture3(
      SessionEnv.neutralized({}), "ruby", "-e", %(load #{BIN.inspect}; print(#{expr}))
    )
    assert_predicate status, :success?, "bin/release must load standalone: #{err}"
    out
  end
end
