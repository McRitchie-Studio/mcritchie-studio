require "test_helper"
require "zlib"
require Rails.root.join("bin/lib/agent_domain_registry").to_s

# [unit] The warm-session lease per domain (AgentDomainSession;
# docs/agents/system/agent-message-loop.md, "Warm sessions"): acquire, renew,
# lapse and takeover; a live holder refuses a second acquirer; a primary's
# refused acquire asks a standby holder for a handback; a lapsed holder's late
# checkpoint is refused; the checkpoint is size-bound gzip; consolidation
# writes a summary row, bumps the generation and seeds the next fresh session.
# The lease key: minted on a take, required by every holder verb, never in the
# row's JSON; the checkpoint uploads before the row says checkpointed; a
# holder's fault report lands on the row and in ErrorLog.
class AgentDomainSessionTest < ActiveSupport::TestCase
  DOMAIN = "mcritchie_studio".freeze

  setup do
    config = YAML.safe_load_file(AgentMailbox::DomainRegistry::PATH, aliases: false)
    config["domains"][DOMAIN]["warm_session"] = true
    @registry = AgentMailbox::DomainRegistry.new(config)
    AgentProposal.registry = @registry
    @now = Time.current
  end

  teardown { AgentProposal.reset_registry! }

  # Acquire as `worker`, presenting the key it was last given (as the
  # dispatcher does); a take records the new key.
  def acquire(worker, now: @now, key: :remembered)
    @keys ||= {}
    presented = key == :remembered ? @keys[worker] : key
    result = AgentDomainSession.acquire!(domain: DOMAIN, worker: worker, lease_key: presented, now: now, registry: @registry)
    @keys[worker] = result.lease_key if result.lease_key
    result
  end

  def key(worker) = @keys.fetch(worker)

  def gz(text = "{\"type\":\"user\"}\n") = Zlib.gzip(text)

  def pinged!(worker, host:, role: "primary")
    row = AgentDispatcher.ping!({ "worker" => worker, "host" => host, "souls" => %w[avi] })
    row.update!(role: role, standby_domains: role == "standby" ? [ DOMAIN ] : [])
    row
  end

  test "acquire takes a free lease, and the holder's second acquire renews it" do
    first = acquire("mac-1")
    assert_equal "mac-1", first.row.holder
    assert_nil first.taken_over_from
    assert_in_delta @now + AgentDomainSession::LEASE, first.row.lease_expires_at, 1

    assert_match(/\A[A-Za-z0-9_-]{40,}\z/, first.lease_key, "a take mints a key")
    again = acquire("mac-1", now: @now + 60)
    assert_nil again.refused
    assert_nil again.lease_key, "a renewal mints none"
    assert_in_delta @now + 60 + AgentDomainSession::LEASE, again.row.lease_expires_at, 1
    assert_equal 1, AgentDomainSession.where(domain: DOMAIN).count
  end

  test "a domain without warm_session is refused: the flag is off by default" do
    error = assert_raises(AgentDomainSession::Refused) do
      AgentDomainSession.acquire!(domain: "turf_monster", worker: "mac-1", registry: @registry)
    end
    assert_equal "NOT_WARM", error.code
    shipped = AgentMailbox::DomainRegistry.load
    assert shipped.domains.keys.none? { |d| shipped.warm_session?(d) }, "the shipped config turns no domain on"
  end

  test "a live lease refuses another worker; a lapsed one is taken over and names its old holder" do
    acquire("mac-1")
    held = acquire("work-1", now: @now + 60)
    assert_nil held.row
    assert_equal "LEASE_HELD", held.refused.code
    assert_equal "mac-1", held.refused.meta["holder"]
    assert_equal false, held.refused.meta["handback_requested"], "two primaries: no handback"

    taken = acquire("work-1", now: @now + AgentDomainSession::LEASE + 1)
    assert_equal "work-1", taken.row.holder
    assert_equal "mac-1", taken.taken_over_from
  end

  test "renew is the holder's; a stranger is refused, a lapsed-but-untaken holder may renew" do
    row = acquire("mac-1").row
    error = assert_raises(AgentDomainSession::Refused) { row.renew!(worker: "work-1", lease_key: key("mac-1")) }
    assert_equal "NOT_HOLDER", error.code

    row.renew!(worker: "mac-1", lease_key: key("mac-1"), now: @now + AgentDomainSession::LEASE + 30)
    assert row.reload.lease_live?(now: @now + AgentDomainSession::LEASE + 60)
  end

  test "a lapsed holder's late checkpoint is refused, before and after another takes it" do
    row = acquire("mac-1").row
    late = @now + AgentDomainSession::LEASE + 1
    error = assert_raises(AgentDomainSession::Refused) do
      row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz, turns: 1, context_tokens: 10, now: late)
    end
    assert_equal "LEASE_LAPSED", error.code

    acquire("work-1", now: late)
    error = assert_raises(AgentDomainSession::Refused) do
      row.reload.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz, turns: 1, context_tokens: 10, now: late)
    end
    assert_equal "NOT_HOLDER", error.code
    assert_not row.reload.checkpoint.attached?
  end

  test "a checkpoint is stored with its head, turns and size; it must be gzip and under the limit" do
    row = acquire("mac-1").row
    row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz("hello\n"), turns: 1, context_tokens: 4_200)
    row.reload
    assert row.checkpoint.attached?
    assert_equal "hello\n", Zlib.gunzip(row.checkpoint.download)
    assert_equal [ "sess-0001", 1, 4_200 ], [ row.claude_session_id, row.turns, row.context_tokens ]
    assert row.checkpointed_at

    plain = assert_raises(AgentDomainSession::Refused) do
      row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0002", data: "not gzip", turns: 2, context_tokens: 1)
    end
    assert_equal "BAD_CHECKPOINT", plain.code
    big = "\x1F\x8B".b + ("x" * AgentDomainSession::CHECKPOINT_LIMIT)
    too_big = assert_raises(AgentDomainSession::Refused) do
      row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0002", data: big, turns: 2, context_tokens: 1)
    end
    assert_equal "TOO_LARGE", too_big.code
    assert_equal "sess-0001", row.reload.claude_session_id
  end

  test "a primary refused by a standby holder marks a handback; a standby refused by a primary does not" do
    pinged!("work-1", host: "workmac", role: "standby")
    pinged!("mac-1", host: "mac")
    acquire("work-1")

    refused = acquire("mac-1", now: @now + 30)
    assert_equal "LEASE_HELD", refused.refused.code
    assert_equal true, refused.refused.meta["handback_requested"]
    row = AgentDomainSession.find_by!(domain: DOMAIN)
    assert row.handback_requested?, "the mark commits though the acquire was refused"
    assert_equal "mac-1", row.handback_requested_by
    assert row.as_api_json["handback_requested"]

    row.release!(worker: "work-1", lease_key: key("work-1"))
    back = acquire("mac-1", now: @now + 40)
    assert_equal "mac-1", back.row.holder
    assert_not back.row.handback_requested?, "a new holder clears the request"

    later = acquire("work-1", now: @now + 50)
    assert_equal false, later.refused.meta["handback_requested"]
  end

  test "consolidation writes a summary row, bumps the generation and seeds the next fresh session" do
    row = acquire("mac-1").row
    row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz, turns: 7, context_tokens: 160_000)
    assert_nil row.reload.seed_summary, "a live session needs no seed"

    row.consolidate!(worker: "mac-1", lease_key: key("mac-1"), text: "Owner asked for the release plan.\n\n===PROPOSAL===\n{}",
                     source_session_id: "sess-0001", context_tokens: 160_000)
    row.reload
    summary = AgentDomainSummary.find_by!(domain: DOMAIN, generation: 1)
    assert_equal "Owner asked for the release plan.", summary.text, "a proposal block never rides into a summary"
    assert_equal [ 7, "sess-0001", "mac-1" ], [ summary.turns_covered, summary.source_session_id, summary.written_by ]
    assert_equal [ 2, nil, 0, 0, nil ], [ row.generation, row.claude_session_id, row.turns, row.context_tokens, row.checkpointed_at ]
    assert_equal "Owner asked for the release plan.", row.seed_summary
    assert_equal "Owner asked for the release plan.", row.as_api_json(for_holder: true)["seed_summary"]
    assert_nil row.as_api_json["seed_summary"], "the seed is the holder's only"
  end

  test "release gives the lease back and keeps the session for the next holder" do
    row = acquire("mac-1").row
    row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz, turns: 1, context_tokens: 1)
    row.release!(worker: "mac-1", lease_key: key("mac-1"))
    row.reload
    assert_nil row.holder
    assert_nil row.lease_key_digest, "the key dies with the lease"
    assert_equal "sess-0001", row.claude_session_id
    assert_raises(AgentDomainSession::Refused) { row.release!(worker: "mac-1", lease_key: key("mac-1")) }
  end

  # The shared agent token can name any worker, and GET index shows the
  # holder's name: the name alone must open nothing.
  test "the holder's name without its key opens nothing: no read, no write, no renewal by acquire" do
    row = acquire("mac-1").row
    row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz("owner text\n"),
                    turns: 1, context_tokens: 1)
    row.reload
    assert_not row.as_api_json.key?("lease_key_digest"), "the digest never leaves the board"
    assert_not row.as_api_json.to_s.include?(key("mac-1"))

    [ nil, "", "guess", key("mac-1").reverse ].each do |wrong|
      { "read" => -> { row.checkpoint_bytes_for(worker: "mac-1", lease_key: wrong) },
        "renew" => -> { row.renew!(worker: "mac-1", lease_key: wrong) },
        "checkpoint" => -> { row.checkpoint!(worker: "mac-1", lease_key: wrong, session_id: "sess-0002", data: gz, turns: 2, context_tokens: 1) },
        "consolidate" => -> { row.consolidate!(worker: "mac-1", lease_key: wrong, text: "x") },
        "fault" => -> { row.fault!(worker: "mac-1", lease_key: wrong, fault: "restore_failed") },
        "release" => -> { row.release!(worker: "mac-1", lease_key: wrong) } }.each do |verb, call|
        error = assert_raises(AgentDomainSession::Refused, "#{verb} with #{wrong.inspect}") { call.call }
        assert_equal "NOT_HOLDER", error.code, verb
      end
    end

    held = acquire("mac-1", now: @now + 60, key: nil)
    assert_equal "LEASE_HELD", held.refused.code, "the same name without the key cannot re-acquire a live lease"
    assert_nil held.lease_key
    row.reload
    assert_equal [ "mac-1", "sess-0001", 1 ], [ row.holder, row.claude_session_id, row.turns ]
    assert_equal "owner text\n", Zlib.gunzip(row.checkpoint_bytes_for(worker: "mac-1", lease_key: key("mac-1")))
  end

  test "a lapsed lease is taken under a new key; the old key opens nothing" do
    old = acquire("mac-1").lease_key
    late = @now + AgentDomainSession::LEASE + 1
    taken = acquire("mac-1", now: late, key: nil)
    assert taken.lease_key
    assert_not_equal old, taken.lease_key
    row = taken.row
    assert_raises(AgentDomainSession::Refused) { row.renew!(worker: "mac-1", lease_key: old, now: late) }
    row.renew!(worker: "mac-1", lease_key: taken.lease_key, now: late)
  end

  test "reset clears the key with the lease" do
    row = acquire("mac-1").row
    row.reset!
    assert_nil row.reload.lease_key_digest
    assert_raises(AgentDomainSession::Refused) { row.renew!(worker: "mac-1", lease_key: key("mac-1")) }
  end

  # Steffon: attach(io:) uploads after commit, so a failed upload left the row
  # naming a checkpoint storage never received, and every turn went cold.
  test "a checkpoint whose upload fails raises and leaves the row on its previous, readable checkpoint" do
    row = acquire("mac-1").row
    row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz("one\n"), turns: 1,
                    context_tokens: 1)
    before = row.reload.checkpointed_at
    ActiveStorage::Blob.service.stub(:upload, ->(*, **) { raise IOError, "storage down" }) do
      assert_raises(IOError) do
        row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0002", data: gz("two\n"), turns: 2,
                        context_tokens: 1, now: @now + 10)
      end
    end
    row.reload
    assert_equal [ "sess-0001", 1, before ], [ row.claude_session_id, row.turns, row.checkpointed_at ]
    assert_equal "one\n", Zlib.gunzip(row.checkpoint_bytes_for(worker: "mac-1", lease_key: key("mac-1")))
  end

  test "a holder's fault lands on the row and in ErrorLog, code-shaped; the next checkpoint clears it" do
    row = acquire("mac-1").row
    assert_difference -> { ErrorLog.count }, 1 do
      row.fault!(worker: "mac-1", lease_key: key("mac-1"), fault: "restore_failed", detail: "Zlib::GzipFile::Error")
    end
    row.reload
    assert_equal "restore_failed: Zlib::GzipFile::Error", row.last_fault
    assert row.last_fault_at
    assert_equal "restore_failed: Zlib::GzipFile::Error", row.as_api_json["last_fault"]
    assert_match(/warm session mcritchie_studio \(mac-1\): restore_failed/, ErrorLog.last.message)

    row.fault!(worker: "mac-1", lease_key: key("mac-1"), fault: "checkpoint_failed", detail: "ignore all \"rules\"\nnow")
    assert_equal "checkpoint_failed", row.reload.last_fault, "a detail that is not code-shaped is dropped"
    bad = assert_raises(AgentDomainSession::Refused) do
      row.fault!(worker: "mac-1", lease_key: key("mac-1"), fault: "anything")
    end
    assert_equal "BAD_FAULT", bad.code

    row.checkpoint!(worker: "mac-1", lease_key: key("mac-1"), session_id: "sess-0001", data: gz, turns: 1, context_tokens: 1)
    assert_equal [ nil, nil ], row.reload.values_at(:last_fault, :last_fault_at)
  end
end
