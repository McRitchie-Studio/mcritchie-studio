require "test_helper"

# [unit] AgentLoginRequest: the grant, the lapse, the refusals, the one-time code
# and the single collect.
class AgentLoginRequestTest < ActiveSupport::TestCase
  HARNESS = "harness-one".freeze

  def request(soul: "xan", harness: HARNESS, key: nil)
    AgentLoginRequest.request!(soul: soul, harness_session_id: harness, collect_key: key)
  end

  def refusal(kind)
    error = assert_raises(AgentLoginRequest::Refusal) { yield }
    assert_equal kind, error.kind
    error.message
  end

  test "grant issues unscoped 8h admin" do
    freeze_time do
      login = request
      session = login.approve!(by: "alex@test.com")

      assert session.admin?
      assert_nil session.task_slug
      assert_equal "xan", session.soul
      assert_equal "operator_grant", session.issued_by
      assert_equal HARNESS, session.harness_session_id
      assert_equal 8.hours.from_now, session.expires_at
      assert_equal %w[granted alex@test.com], [ login.status, login.decided_by ]
      assert_equal session.slug, login.agent_session_slug
    end
  end

  test "the code grants as launch_phrase with no approve tap" do
    login = request(soul: "steffon")
    session = login.grant_with_code!(code: login.display_code.downcase, collect_key: login.collect_key,
                                     harness_session_id: HARNESS)

    assert_equal %w[admin steffon launch_phrase], [ session.tier, session.soul, session.issued_by ]
    assert_equal "launch_phrase", login.decided_by
  end

  test "lapse mints nothing" do
    login = request
    travel 10.minutes + 1.second do
      assert_equal "lapsed", login.state
      assert_nil login.code
      assert_no_difference -> { AgentSession.count } do
        assert_match(/lapsed at .* nothing was minted/, refusal(:lapsed) { login.approve!(by: "alex@test.com") })
        refusal(:lapsed) { login.grant_with_code!(code: "X", collect_key: login.collect_key, harness_session_id: HARNESS) }
        refusal(:lapsed) { login.collect!(collect_key: login.collect_key, harness_session_id: HARNESS) }
      end
    end
    travel(9.minutes) { assert_equal "pending", login.state } # control: inside the window it is open
  end

  test "refusal says why" do
    login = request
    login.refuse!(by: "alex@test.com", reason: "declined by the operator")

    assert_no_difference -> { AgentSession.count } do
      assert_match(/was refused: declined by the operator/, refusal(:refused) { login.approve!(by: "alex@test.com") })
      message = refusal(:refused) { login.collect!(collect_key: login.collect_key, harness_session_id: HARNESS) }
      assert_match(/declined by the operator/, message)
    end
    assert_equal "declined by the operator", login.summary["reason"]
  end

  test "collect once" do
    login = request
    key = login.collect_key
    assert_match(/is pending/, refusal(:pending) { login.collect!(collect_key: key, harness_session_id: HARNESS) })

    granted = login.approve!(by: "alex@test.com")
    collected = login.collect!(collect_key: key, harness_session_id: HARNESS)
    assert_equal granted, collected
    assert_equal granted, AgentSession.from_token(collected.token)

    assert_match(/already collected/, refusal(:collected) { login.collect!(collect_key: key, harness_session_id: HARNESS) })
  end

  test "collect needs the requester's key and harness session" do
    login = request
    login.approve!(by: "alex@test.com")

    refusal(:forbidden) { login.collect!(collect_key: "guess", harness_session_id: HARNESS) }
    refusal(:forbidden) { login.collect!(collect_key: login.collect_key, harness_session_id: "another-harness") }
    assert_nil login.reload.collected_at
    assert login.collect!(collect_key: login.collect_key, harness_session_id: HARNESS) # control
  end

  test "a wrong code is counted and the request is refused at the cap" do
    login = request
    key = login.collect_key
    good = login.code

    assert_no_difference -> { AgentSession.count } do
      (AgentLoginRequest::CODE_ATTEMPTS - 1).times do |n|
        message = refusal(:wrong_code) { login.grant_with_code!(code: "WRONGWRG", collect_key: key, harness_session_id: HARNESS) }
        assert_match(/#{AgentLoginRequest::CODE_ATTEMPTS - n - 1} of 5 attempts left/, message)
      end
      assert_match(/refused after 5 wrong codes/,
                   refusal(:wrong_code) { login.grant_with_code!(code: "WRONGWRG", collect_key: key, harness_session_id: HARNESS) })
      refusal(:refused) { login.grant_with_code!(code: good, collect_key: key, harness_session_id: HARNESS) }
    end
    assert_equal [ "refused", 5, "5 wrong codes" ], [ login.status, login.code_attempts, login.refusal_reason ]
  end

  test "a wrong key posts no code attempt" do
    login = request

    refusal(:forbidden) { login.grant_with_code!(code: "WRONGWRG", collect_key: "guess", harness_session_id: HARNESS) }
    assert_equal 0, login.reload.code_attempts
  end

  test "a code is single use and bound to its request" do
    first = request(harness: "harness-a")
    second = request(harness: "harness-b")
    assert_not_equal first.code, second.code

    assert_no_difference -> { AgentSession.count } do
      refusal(:wrong_code) do
        second.grant_with_code!(code: first.code, collect_key: second.collect_key, harness_session_id: "harness-b")
      end
    end

    code = first.code
    first.grant_with_code!(code: code, collect_key: first.collect_key, harness_session_id: "harness-a")
    assert_nil first.code
    assert_no_difference -> { AgentSession.count } do
      message = refusal(:decided) { first.grant_with_code!(code: code, collect_key: first.collect_key, harness_session_id: "harness-a") }
      assert_match(/already granted .* its code is spent/, message)
    end
  end

  test "the table holds digests, never the code or the key" do
    login = request
    stored = login.reload.attributes.values.map(&:to_s)

    assert_not_includes stored, login.code
    assert_equal AgentLoginRequest.digest(login.code), login.phrase_digest
    assert_match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}\z/, login.display_code)
    assert_nil AgentLoginRequest.find(login.id).collect_key, "a loaded row carries no collect key"
    %w[code collect_key token phrase_digest collect_digest].each { |key| assert_not_includes login.summary.keys, key }
  end

  test "only an admin soul may ask, and alex is xan" do
    error = assert_raises(ActiveRecord::RecordInvalid) { request(soul: "carl") }
    assert_match(/holds no admin tier/, error.message)
    assert_raises(ActiveRecord::RecordInvalid) { request(soul: "nobody") }
    assert_equal "xan", request(soul: "alex").soul
  end

  test "a second post under the same harness id cannot refuse or replace the open request" do
    real = request(soul: "steffon")

    assert_no_difference -> { AgentLoginRequest.count } do
      message = refusal(:open) { request(soul: "steffon") }
      assert_match(/already open under this harness session id/, message)
      assert_not_includes message, real.slug
      refusal(:open) { request(soul: "steffon", key: "guess") }
    end
    assert_equal "pending", real.reload.status
    assert_equal [ real ], AgentLoginRequest.awaiting.to_a

    session = real.approve!(by: "alex@test.com")
    assert_equal session, real.collect!(collect_key: real.collect_key, harness_session_id: HARNESS)
  end

  test "the owner replaces its own open request with its collect key" do
    older = request
    newer = request(key: older.collect_key)

    assert_equal [ "refused", "superseded by its owner's newer request" ], [ older.reload.status, older.refusal_reason ]
    assert_equal [ newer ], AgentLoginRequest.awaiting.to_a
  end

  test "a lapsed request does not hold the harness id" do
    request
    travel(11.minutes) { assert request }
  end

  test "a soul gets three requests a window, and a re-create does not reset the bound" do
    first = request(harness: "harness-a")
    second = request(harness: "harness-a", key: first.collect_key)
    AgentLoginRequest::CODE_ATTEMPTS.times do
      refusal(:wrong_code) { second.grant_with_code!(code: "WRONGWRG", collect_key: second.collect_key, harness_session_id: "harness-a") }
    end
    request(harness: "harness-b")

    assert_match(/already has 3 admin login requests inside the 10-minute window/, refusal(:too_many) { request(harness: "harness-c") })
    assert request(soul: "steffon", harness: "harness-c"), "the bound is per soul"
    travel(11.minutes) { assert request(harness: "harness-c") } # control: the window frees the room
  end

  test "an operator's decline frees a slot" do
    held = Array.new(AgentLoginRequest::SOUL_REQUESTS) { |n| request(harness: "harness-#{n}") }
    refusal(:too_many) { request(harness: "harness-over") }

    held.first.refuse!(by: "alex@test.com", reason: "declined by the operator")
    assert request(harness: "harness-over")
  end
end
