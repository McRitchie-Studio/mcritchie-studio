require "test_helper"
require Rails.root.join("bin/lib/ci_gate").to_s

# /tasks/pending-ci-paints-check — the RENDER half, and the one that matters.
#
# THE DEFECT, MEASURED BY PAGE LOAD RATHER THAN BY READING. Before this task the card's
# chain was fail → ✗, `running` → ◌, NO_VERDICT_RESULTS → ⚠, DEFAULT → ✓. `CiGate`
# writes "pending" builder-side for a CI that is STILL RUNNING, which is in none of the
# first three — so it fell to the default and a real GateRun row rendered `✓`. Reproduced
# 2026-09-09 from a real row through a real request before the fix, exactly as the two
# prior reviews in this family insisted: a source scan cannot see a fall-through, only
# the rendered glyph can.
#
# THE TASK WAS THE DEFAULT, NOT THE MISSING ARM. `pending` was the FOURTH value to reach
# that `✓` by never having an arm. Adding a fifth arm fixes a fifth instance; moving the
# default is what stops the sixth. So `pass` is now explicit and the fall-through is `?`
# — the tests below pin BOTH halves, because the arm alone would leave the class open
# and the default alone would leave `pending` amber-by-accident rather than by decision.
class GatesCardPendingCiTest < ActionDispatch::IntegrationTest
  setup { @admin = users(:alex) }

  def card_for(slug, sops)
    task = Task.create!(title: "gate record probe", stage: "submitted", slug: slug, metadata: {})
    GateRun.create!(subject_type: "task", subject_slug: slug, key: "dor_review", attempt: 1,
                    started_at: 3.minutes.ago, finished_at: 1.minute.ago, success: false, sops: sops)
    task
  end

  def glyph_for(task, result)
    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    node = css_select("[data-result='#{result}'] [data-test='gate-sop-glyph']").first
    assert node, "the #{result.inspect} ci row must render — got " \
                 "#{css_select('[data-test=\'gate-sop-glyph\']').map(&:text).inspect}"
    node.text.strip
  end

  # EVERY in-flight value, ONE PAGE LOAD EACH, driven off the model's own set — not once
  # for the set, so removing a single member cannot hide behind its sibling. This is the
  # render-coverage-per-member property #1320 established, inherited free.
  test "[integration] the gates card never paints an IN-FLIGHT gate row with the pass glyph" do
    GateRun::IN_FLIGHT_RESULTS.each do |result|
      task = card_for("gates-card-inflight-#{result.tr('_', '-')}",
                      [{ "sop" => "ci", "result" => result, "at" => Time.current.iso8601 }])
      glyph = glyph_for(task, result)

      refute_equal "✓", glyph,
                   "#{result}: a CI that is still RUNNING is not a CI that passed — that is " \
                   "the inversion this arm exists to stop, and the direction nobody audits"
      refute_equal "✗", glyph, "#{result}: and it has not failed either; it has not finished"
      assert_equal "◌", glyph
    end
  end

  # THE DEFECT ITSELF, END TO END: the value the PRODUCER actually writes for the builder
  # role, rendered on the real page. The test above drives off the model's set, so it
  # would stay green if the producer drifted to some other word; this one closes that by
  # asking CiGate for the row instead of naming it.
  test "[integration] the row a builder-side pending CI actually produces renders in-flight" do
    row = CiGate.gate_row({ state: :pending }, review_role: false, review_refused: false)
    task = card_for("gates-card-pending-produced",
                    [{ "sop" => "ci", "result" => row, "at" => Time.current.iso8601 }])

    assert_equal "◌", glyph_for(task, row),
                 "this is the exact row bin/dor-check persists while CI is unsettled"
  end

  # ==== THE FLIPPED DEFAULT ====================================================
  #
  # THE CLASS FIX, AND THE POINT OF THE TASK. A result value this card has never heard
  # of must render as an UNKNOWN, not as a pass. Before this change the assertion below
  # read `✓` — four defects in this family were all one shape: a value added upstream,
  # no arm added here, a green rendered for something nobody classified.
  test "[integration] an UNRECOGNISED result value renders unknown, never as a pass" do
    task = card_for("gates-card-unknown-result",
                    [{ "sop" => "ci", "result" => "quantum_flux", "at" => Time.current.iso8601 }])
    glyph = glyph_for(task, "quantum_flux")

    refute_equal "✓", glyph,
                 "a value the card cannot classify is not a value that passed — this is the " \
                 "silent-green default /tasks/pending-ci-paints-check removed"
    assert_equal "?", glyph
  end

  # AN ABSENT RESULT IS THE SAME QUESTION. `nil.to_s` is "", which rode the ✓ default too
  # — the omission hazard bin/lib/ci_gate.rb's GATE_ROW_NO_PR comment names as the reason
  # a no-PR row is RECORDED rather than skipped. `bin/gate show` has always printed a nil
  # result as `-` rather than a pass; the card now agrees with it.
  test "[integration] a row with no result at all renders unknown, never as a pass" do
    task = card_for("gates-card-nil-result",
                    [{ "sop" => "ci", "result" => nil, "at" => Time.current.iso8601 }])
    log_in_as(@admin)
    get task_path(task)
    assert_response :success

    glyph = css_select("[data-result=''] [data-test='gate-sop-glyph']").first
    assert glyph, "the empty-result row must render"
    assert_equal "?", glyph.text.strip
  end

  # ==== CONTROLS ===============================================================
  #
  # THE CONTROL THAT MAKES THE FLIP HONEST. Moving the default is only safe if `pass`
  # still reaches ✓ on its own arm — otherwise the "fix" is to paint everything unknown,
  # which loses the same information in the opposite direction. This is the assertion
  # that would catch that.
  test "[integration] a genuinely passing sop row still paints the pass glyph" do
    task = card_for("gates-card-pending-pass",
                    [{ "sop" => "ci", "result" => "pass", "at" => Time.current.iso8601 }])

    assert_equal "✓", glyph_for(task, "pass")
  end

  # The second control: if the ✗ arm broke, the in-flight test would pass for the wrong
  # reason and a genuinely red CI would stop looking red.
  test "[integration] a genuinely failed ci row still paints the fail glyph" do
    task = card_for("gates-card-pending-red",
                    [{ "sop" => "ci", "result" => "fail", "at" => Time.current.iso8601 }])

    assert_equal "✗", glyph_for(task, "fail")
  end

  # The third control: the no-verdict family must keep its OWN glyph and not be swallowed
  # by the new in-flight arm or the new default. ⚠ and ◌ prescribe different moves — "go
  # find out why there is no answer" versus "wait for the answer that is coming".
  test "[integration] the no-verdict family still paints its own glyph, distinct from in-flight" do
    GateRun::NO_VERDICT_RESULTS.each do |result|
      task = card_for("gates-card-pend-nv-#{result.tr('_', '-')}",
                      [{ "sop" => "ci", "result" => result, "at" => Time.current.iso8601 }])

      assert_equal "⚠", glyph_for(task, result),
                   "#{result}: never given is not the same as not yet given"
    end
  end

  # THE PRODUCER AND THE RENDERER MUST AGREE ON THE WORD, and this is the one test that
  # can load both halves — bin/lib/ci_gate.rb cannot load a Rails model. Drift here means
  # the producer writes a word the card has no arm for; that is now a `?` rather than a
  # false green, but it is still a defect.
  test "[unit] the producer's pending value equals the one the card paints in-flight" do
    assert_equal GateRun::PENDING_RESULT, CiGate::GATE_ROW_PENDING
    assert_includes GateRun::IN_FLIGHT_RESULTS, CiGate::GATE_ROW_PENDING
  end
end
