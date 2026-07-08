require "test_helper"
# Object#stub — the best-effort capture tests force failures standalone (mock
# isn't required globally; matches the repo's per-file convention).
require "minitest/mock"

class AgentActionTest < ActiveSupport::TestCase
  # ---- [unit] defaults -------------------------------------------------------

  test "[unit] a new record carries the column defaults" do
    action = AgentAction.new

    assert_equal 0, action.seq
    assert_equal AgentAction::PENDING, action.outcome
    assert_equal AgentAction::AGENT, action.actor
    assert_equal 0, action.tokens_in
    assert_equal 0, action.tokens_out
    assert_equal 0, action.cache_read_tokens
    assert_equal 0.to_d, action.cost
    assert_equal false, action.feedback_anchor
  end

  # ---- [unit] validations ----------------------------------------------------

  test "[unit] valid with the required attributes present" do
    action = AgentAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current)

    assert action.valid?, action.errors.full_messages.to_sentence
  end

  test "[unit] session_id is required" do
    action = AgentAction.new(kind: "read", occurred_at: Time.current)

    assert_not action.valid?
    assert_includes action.errors[:session_id], "can't be blank"
  end

  test "[unit] kind is required" do
    action = AgentAction.new(session_id: "sess-1", occurred_at: Time.current)

    assert_not action.valid?
    assert_includes action.errors[:kind], "can't be blank"
  end

  test "[unit] occurred_at is required" do
    action = AgentAction.new(session_id: "sess-1", kind: "read")

    assert_not action.valid?
    assert_includes action.errors[:occurred_at], "can't be blank"
  end

  test "[unit] seq must be a non-negative integer" do
    action = AgentAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, seq: -1)

    assert_not action.valid?
    assert_includes action.errors[:seq], "must be greater than or equal to 0"
  end

  # ---- [unit] outcome enum ---------------------------------------------------

  test "[unit] outcome accepts ok error and pending" do
    AgentAction::OUTCOMES.each do |outcome|
      action = AgentAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, outcome: outcome)
      assert action.valid?, "#{outcome} should be a valid outcome"
    end
  end

  test "[unit] outcome rejects an unknown value" do
    action = AgentAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, outcome: "maybe")

    assert_not action.valid?
    assert_includes action.errors[:outcome], "is not included in the list"
  end

  # ---- [unit] actor enum -----------------------------------------------------

  test "[unit] actor accepts harness agent board and human" do
    AgentAction::ACTORS.each do |actor|
      action = AgentAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, actor: actor)
      assert action.valid?, "#{actor} should be a valid actor"
    end
  end

  test "[unit] actor rejects an unknown value" do
    action = AgentAction.new(session_id: "sess-1", kind: "read", occurred_at: Time.current, actor: "robot")

    assert_not action.valid?
    assert_includes action.errors[:actor], "is not included in the list"
  end

  # ---- [unit] helpers + scopes ----------------------------------------------

  test "[unit] tokens_total sums the two sides" do
    action = AgentAction.new(tokens_in: 1200, tokens_out: 3400)

    assert_equal 4600, action.tokens_total
  end

  # ---- [unit] cost derivation from the model rate map ------------------------

  test "[unit] cost_for prices tokens from the model rate map" do
    # claude-opus-4-8 = $5/1M in, $25/1M out.
    # 1_000_000 in + 200_000 out => $5.00 + $5.00 = $10.00.
    cost = AgentAction.cost_for("claude-opus-4-8", 1_000_000, 200_000)

    assert_equal "10.0".to_d, cost
  end

  test "[unit] cost_for is nil when the model has no known rate (never fabricated)" do
    assert_nil AgentAction.cost_for("gpt-5-codex", 1000, 2000), "an unknown model must NOT get a fabricated price"
    assert_nil AgentAction.cost_for(nil, 1000, 2000)
    assert_nil AgentAction.cost_for("", 1000, 2000)
  end

  test "[unit] cost_for strips a [tier] suffix so the 1M-context id still prices" do
    plain  = AgentAction.cost_for("claude-opus-4-8", 100_000, 20_000)
    tiered = AgentAction.cost_for("claude-opus-4-8[1m]", 100_000, 20_000)

    assert_equal plain, tiered
    assert_operator tiered, :>, 0
  end

  test "[unit] cost_for zero usage on a known model is zero, not nil" do
    assert_equal 0.to_d, AgentAction.cost_for("claude-opus-4-8", 0, 0)
  end

  test "[unit] cost_for prices cache_read at 10% of the input rate" do
    # claude-opus-4-8 = $5/1M in. 1_000_000 cache_read tokens => $5.00 * 0.10 = $0.50.
    assert_equal "0.5".to_d, AgentAction.cost_for("claude-opus-4-8", 0, 0, 1_000_000)
  end

  test "[unit] cost_for sums fresh tokens at full rate and cache_read at the cache tier" do
    # 1M fresh in ($5.00) + 200K out ($5.00) + 1M cache_read ($0.50) = $10.50.
    cost = AgentAction.cost_for("claude-opus-4-8", 1_000_000, 200_000, 1_000_000)

    assert_equal "10.5".to_d, cost
  end

  test "[unit] cost_for on a long-session shaped turn reads cents, not dollars" do
    # The overstatement bug: a huge cache_read once priced at the full input rate.
    # 5K fresh in + 250 out + 304K cache_read on opus should be ~cents, not ~$1.58.
    cost = AgentAction.cost_for("claude-opus-4-8", 5_000, 250, 304_000)

    assert_operator cost, :<, "0.25".to_d, "cache_read at 0.1x keeps a long turn in cents"
    assert_operator cost, :>, 0
  end

  test "[unit] cost_for cache_read on a model with no known rate is still nil" do
    assert_nil AgentAction.cost_for("gpt-5-codex", 0, 0, 1_000_000),
               "no rate means no price, even for pure cache_read"
  end

  # ---- [integration] one usage, priced identically by both surfaces ----------

  test "[integration] the per-action and per-session paths price a usage identically" do
    # Both AgentAction.cost_for and AgentSessionUsage.price route through the shared
    # UsagePricing SoT, so the SAME (input, output, cache_read) usage yields the same
    # dollars regardless of which surface prices it. (The action path folds
    # cache_creation into tokens_in, so this parity is asserted with cache_creation=0,
    # the shared surface both paths agree on.)
    input = 120_000
    output = 45_000
    cache_read = 900_000

    action_cost  = AgentAction.cost_for("claude-opus-4-8", input, output, cache_read)
    session_cost = AgentSessionUsage.price(
      { "input" => input, "output" => output, "cache_creation" => 0, "cache_read" => cache_read },
      "claude-opus-4-8"
    )

    refute_nil action_cost
    assert_equal action_cost, session_cost.to_d,
                 "both usage surfaces must agree once they share one pricing table"
    assert_equal UsagePricing.price(
      { "input" => input, "output" => output, "cache_creation" => 0, "cache_read" => cache_read },
      "claude-opus-4-8"
    ), action_cost
  end

  test "[unit] outcome predicates reflect the stored value" do
    assert AgentAction.new(outcome: "ok").ok?
    assert AgentAction.new(outcome: "error").error?
    assert AgentAction.new(outcome: "pending").pending?
    assert AgentAction.new(feedback_anchor: true).anchor?
    assert_not AgentAction.new(feedback_anchor: false).anchor?
  end

  test "[unit] scopes filter by session anchors and errored outcome" do
    ok      = AgentAction.capture(session_id: "scope-sess", kind: "read", outcome: "ok")
    errored = AgentAction.capture(session_id: "scope-sess", kind: "bash", outcome: "error")
    anchor  = AgentAction.capture(session_id: "scope-sess", kind: "edit", feedback_anchor: true)
    AgentAction.capture(session_id: "other-sess", kind: "read", outcome: "ok")

    assert_equal 3, AgentAction.for_session("scope-sess").count
    assert_equal [errored.id], AgentAction.for_session("scope-sess").errored.pluck(:id)
    assert_equal [anchor.id], AgentAction.for_session("scope-sess").anchors.pluck(:id)
    assert_equal [ok.id, errored.id, anchor.id], AgentAction.for_session("scope-sess").chronological.pluck(:id)
  end

  # ---- [integration] capture writes one forward record -----------------------

  test "[integration] capture persists one record with the given fields" do
    occurred = Time.zone.local(2026, 6, 30, 9, 0, 0)

    action = assert_difference -> { AgentAction.count }, 1 do
      AgentAction.capture(
        session_id:      "cap-sess",
        task_slug:       nil,
        mascot:          "rotom",
        kind:            "edit",
        event_slug:      "implement-atomic-action-model",
        result_slug:     "migration-and-model-written",
        input:           "write app/models/agent_action.rb",
        output:          "file created",
        outcome:         "ok",
        model:           "claude-opus-4-8",
        tokens_in:       6800,
        tokens_out:      2400,
        cost:            "0.28".to_d,
        stage:           "building",
        actor:           "agent",
        feedback_anchor: true,
        occurred_at:     occurred,
        duration_ms:     1234
      )
    end

    assert action.persisted?
    assert_equal "cap-sess", action.session_id
    assert_equal "rotom", action.mascot
    assert_equal "edit", action.kind
    assert_equal "implement-atomic-action-model", action.event_slug
    assert_equal "migration-and-model-written", action.result_slug
    assert_equal "ok", action.outcome
    assert_equal "claude-opus-4-8", action.model
    assert_equal 9200, action.tokens_total
    assert_equal "0.28".to_d, action.cost
    assert_equal "building", action.stage
    assert_equal "agent", action.actor
    assert action.feedback_anchor
    assert_equal occurred, action.occurred_at
    assert_equal 1234, action.duration_ms
  end

  test "[integration] capture defaults outcome and actor and auto-derives seq per session" do
    first  = AgentAction.capture(session_id: "seq-sess", kind: "read")
    second = AgentAction.capture(session_id: "seq-sess", kind: "bash")
    other  = AgentAction.capture(session_id: "fresh-sess", kind: "read")

    assert_equal AgentAction::PENDING, first.outcome
    assert_equal AgentAction::AGENT, first.actor
    assert_equal 0, first.seq, "the first action in a session is position 0"
    assert_equal 1, second.seq, "the next action increments within the session"
    assert_equal 0, other.seq, "a different session starts its own trajectory"
  end

  test "[integration] capture honours an explicit seq" do
    action = AgentAction.capture(session_id: "explicit-seq", kind: "read", seq: 42)

    assert_equal 42, action.seq
  end

  test "[integration] capture pulls usage from Current when not given (the TaskEvent seam)" do
    Current.task_event_model = "claude-opus-4-8"
    Current.task_event_tokens_in = 1200
    Current.task_event_tokens_out = 3400
    Current.task_event_cost = "0.42".to_d

    action = AgentAction.capture(session_id: "usage-sess", kind: "read")

    assert_equal "claude-opus-4-8", action.model
    assert_equal 1200, action.tokens_in
    assert_equal 3400, action.tokens_out
    assert_equal "0.42".to_d, action.cost
  ensure
    Current.reset
  end

  test "[integration] explicit usage attrs win over Current" do
    Current.task_event_model = "from-current"
    Current.task_event_tokens_in = 999

    action = AgentAction.capture(session_id: "override-sess", kind: "read",
                                  model: "claude-opus-4-8", tokens_in: 50)

    assert_equal "claude-opus-4-8", action.model
    assert_equal 50, action.tokens_in
  ensure
    Current.reset
  end

  test "[integration] capture DERIVES cost from model + tokens when no cost is given" do
    # The live-capture hook carries model + tokens but no cost; capture prices it.
    action = AgentAction.capture(session_id: "cost-sess", kind: "read",
                                  model: "claude-opus-4-8", tokens_in: 1_000_000, tokens_out: 200_000)

    assert_equal "10.0".to_d, action.cost
  end

  test "[integration] capture leaves cost NULL for a model with no known rate" do
    action = AgentAction.capture(session_id: "norate-sess", kind: "bash",
                                  model: "gpt-5-codex", tokens_in: 1000, tokens_out: 2000)

    assert_nil action.cost, "an unknown model must record NULL cost, never a fabricated $0"
    assert_equal 1000, action.tokens_in
    assert_equal 2000, action.tokens_out
  end

  test "[integration] an explicit cost still wins over derivation" do
    action = AgentAction.capture(session_id: "explicit-cost", kind: "read",
                                  model: "claude-opus-4-8", tokens_in: 1_000_000, cost: "0.03".to_d)

    assert_equal "0.03".to_d, action.cost
  end

  test "[integration] capture stores cache_read_tokens apart from the fresh tokens" do
    action = AgentAction.capture(session_id: "cr-sess", kind: "read",
                                  model: "claude-opus-4-8",
                                  tokens_in: 5_000, tokens_out: 250, cache_read_tokens: 304_000)

    assert_equal 5_000, action.tokens_in
    assert_equal 250, action.tokens_out
    assert_equal 304_000, action.cache_read_tokens
    assert_equal 5_250, action.tokens_total, "the DISPLAY total is the fresh tokens only"
  end

  test "[integration] capture prices cache_read into the derived cost at the cache tier" do
    # 5K fresh in ($0.025) + 250 out ($0.00625) + 304K cache_read ($0.152) = $0.18325,
    # which the decimal(10,4) cost column stores as $0.1833.
    action = AgentAction.capture(session_id: "cr-cost-sess", kind: "read",
                                  model: "claude-opus-4-8",
                                  tokens_in: 5_000, tokens_out: 250, cache_read_tokens: 304_000)

    assert_equal "0.1833".to_d, action.cost
    assert_operator action.cost, :<, "0.25".to_d, "not the ~$1.58 the lumped path overstated"
  end

  test "[integration] capture defaults cache_read_tokens to zero when the caller omits it" do
    action = AgentAction.capture(session_id: "cr-default-sess", kind: "read",
                                  model: "claude-opus-4-8", tokens_in: 1_000_000, tokens_out: 200_000)

    assert_equal 0, action.cache_read_tokens
    assert_equal "10.0".to_d, action.cost, "no cache_read means the fresh-only price is unchanged"
  end

  test "[integration] capture stores the source_turn_uuid the usage came from" do
    action = AgentAction.capture(session_id: "turn-sess", kind: "read",
                                  model: "claude-opus-4-8", tokens_in: 500,
                                  source_turn_uuid: "turn-abc-123")

    assert_equal "turn-abc-123", action.source_turn_uuid
  end

  test "[integration] capture with string keys works" do
    action = AgentAction.capture("session_id" => "str-sess", "kind" => "verify", "outcome" => "ok")

    assert action.persisted?
    assert_equal "verify", action.kind
    assert_equal "ok", action.outcome
  end

  test "[integration] capture links to a task via the slug FK" do
    task = Task.create!(title: "atomic capture sample task", stage: "building")

    action = AgentAction.capture(session_id: "fk-sess", task_slug: task.slug, kind: "edit")

    assert_equal task.slug, action.task_slug
    assert_equal task, action.task
    assert_includes task.agent_actions, action
  end

  # ---- [integration] idempotency: a re-read must not double a row ------------
  # CI ingestion (bin/ci-scope-capture) re-reads a PR's checks when dor-check /
  # preflight run twice; a stable idempotency_key (ci:<pr>:<sha>:<job>) makes the
  # second capture a no-op that returns the SAME persisted row.

  test "[unit] capture dedupes on idempotency_key — same key twice yields one row" do
    key = "ci:42:abc123:test"
    first = second = nil

    assert_difference -> { AgentAction.where(idempotency_key: key).count }, 1 do
      first = AgentAction.capture(session_id: "idem-sess", kind: "test_scope",
                                  event_slug: "ci_test", result_slug: "pass", idempotency_key: key)
      second = AgentAction.capture(session_id: "idem-sess", kind: "test_scope",
                                   event_slug: "ci_test", result_slug: "pass", idempotency_key: key)
    end

    assert first.persisted?
    assert_equal first.id, second.id, "the second capture returns the FIRST row, not a duplicate"
  end

  test "[unit] a distinct idempotency_key writes a distinct row" do
    a = AgentAction.capture(session_id: "idem-sess", kind: "test_scope",
                            event_slug: "ci_test", result_slug: "pass", idempotency_key: "ci:42:sha1:test")
    b = AgentAction.capture(session_id: "idem-sess", kind: "test_scope",
                            event_slug: "ci_test", result_slug: "pass", idempotency_key: "ci:42:sha2:test")

    refute_equal a.id, b.id, "a new sha (distinct key) is a distinct verdict row"
  end

  test "[unit] a blank idempotency_key never dedupes (the ordinary path)" do
    a = AgentAction.capture(session_id: "plain-sess", kind: "read")
    b = AgentAction.capture(session_id: "plain-sess", kind: "read")

    refute_equal a.id, b.id, "keyless actions are always distinct rows"
    assert_nil a.idempotency_key
  end

  # ---- [integration] best-effort: a capture failure never breaks the caller --

  test "[integration] a capture error is swallowed logged and returns nil" do
    result = nil
    assert_difference -> { ErrorLog.count }, 1 do
      AgentAction.stub(:create!, ->(*) { raise "boom" }) do
        assert_nothing_raised do
          result = AgentAction.capture(session_id: "err-sess", kind: "read")
        end
      end
    end

    assert_nil result, "capture returns nil on failure — never re-raises"
    assert_equal "boom", ErrorLog.order(:id).last.message
  end

  test "[integration] capture survives even when error logging also fails" do
    result = nil
    AgentAction.stub(:create!, ->(*) { raise "boom" }) do
      ErrorLog.stub(:capture!, ->(*) { raise "logging is down" }) do
        assert_nothing_raised do
          result = AgentAction.capture(session_id: "double-fail", kind: "read")
        end
      end
    end

    assert_nil result, "a double failure is still swallowed — the action is never broken"
  end

  test "[integration] next_seq_for is zero for a blank or unseen session" do
    assert_equal 0, AgentAction.next_seq_for(nil)
    assert_equal 0, AgentAction.next_seq_for("never-seen")
  end

  # ---- [integration] SPAN attribution (agent_activity_id) ----------------------

  test "[integration] capture attributes an action to the session's open span" do
    event = AgentActivity.open_event!(session_id: "attr-sess", category: "Explore", reason_slug: "look")

    action = AgentAction.capture(session_id: "attr-sess", kind: "read")

    assert_equal event.id, action.agent_activity_id, "the action rolls up under the open span"
    assert_equal action, event.agent_actions.first
  end

  test "[integration] capture attributes to the LATEST open span" do
    AgentActivity.open_event!(session_id: "latest-attr", category: "Explore", reason_slug: "one")
    second = AgentActivity.open_event!(session_id: "latest-attr", category: "Edit", reason_slug: "two")

    action = AgentAction.capture(session_id: "latest-attr", kind: "edit")

    assert_equal second.id, action.agent_activity_id, "opening a new span moves attribution to it"
  end

  test "[integration] an action with no open span carries a null agent_activity_id" do
    action = AgentAction.capture(session_id: "no-span-sess", kind: "read")

    assert_nil action.agent_activity_id
  end

  test "[integration] a closed span stops receiving new actions" do
    AgentActivity.open_event!(session_id: "closed-attr", category: "Verify", reason_slug: "test")
    AgentActivity.close_event!(session_id: "closed-attr", outcome_slug: "green")

    action = AgentAction.capture(session_id: "closed-attr", kind: "read")

    assert_nil action.agent_activity_id, "once the span closes, actions attribute to nothing"
  end

  test "[integration] an explicit agent_activity_id wins over the derived one" do
    open = AgentActivity.open_event!(session_id: "pin-sess", category: "Explore", reason_slug: "open")
    other = AgentActivity.create!(session_id: "pin-sess", category: "Edit", reason_slug: "pinned",
                                seq: 9, opened_at: Time.current, closed_at: Time.current)

    action = AgentAction.capture(session_id: "pin-sess", kind: "edit", agent_activity_id: other.id)

    assert_equal other.id, action.agent_activity_id
    assert_not_equal open.id, action.agent_activity_id
  end

  test "[integration] an attribution lookup failure is swallowed and the action still writes" do
    action = nil
    AgentActivity.stub(:for_session, ->(*) { raise "attribution is down" }) do
      assert_nothing_raised do
        action = AgentAction.capture(session_id: "attr-fail", kind: "read")
      end
    end

    assert action&.persisted?, "capture still writes the action when attribution fails"
    assert_nil action.agent_activity_id, "a failed attribution degrades to a null span"
  end

  # ---- summary + key_method (the action's goal slug and load-bearing call) ---

  test "[integration] capture persists summary, key_method, and an explicit lang" do
    action = AgentAction.capture(session_id: "km-sess", kind: "bash",
                                  summary: "list board tasks to find slugs",
                                  key_method: "bin/task list 2>/dev/null | head -60",
                                  key_method_lang: "bash")

    assert_equal "list board tasks to find slugs", action.summary
    assert_equal "bin/task list 2>/dev/null | head -60", action.key_method
    assert_equal "bash", action.key_method_lang
  end

  test "[unit] a blank lang is inferred and an overlong summary is capped, never rejected" do
    action = AgentAction.capture(session_id: "km-sess", kind: "bash",
                                  summary: "g" * 400,
                                  key_method: "Task.find_by(slug: 'x')")

    assert_equal "ruby", action.key_method_lang
    assert_equal AgentAction::MAX_SUMMARY_LENGTH, action.summary.length
    assert_nil AgentAction.capture(session_id: "km-sess", kind: "read").summary,
               "fields stay optional — a plain capture carries neither"
  end
end
