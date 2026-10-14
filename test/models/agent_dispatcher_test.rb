require "test_helper"

# [unit] AgentDispatcher: the row bin/dispatcher's minute ping upserts, the
# silent rule the floor alert reads, and the pruning that keeps the newest row.
class AgentDispatcherTest < ActiveSupport::TestCase
  def ping(worker, at: Time.current, **extra)
    AgentDispatcher.ping!({ "worker" => worker, "host" => "alex-mac", "souls" => %w[xan avi], "running" => 2,
                            "capacity" => 5, "state" => "running", "version" => "abc1234" }.merge(extra.transform_keys(&:to_s)),
                          now: at)
  end

  test "a ping upserts one row per worker and stamps last_seen_at" do
    t0 = Time.current
    ping("d-1", at: t0)
    row = ping("d-1", at: t0 + 1.minute, running: 0)

    assert_equal 1, AgentDispatcher.where(worker_id: "d-1").count
    assert_equal 0, row.running
    assert_equal %w[xan avi], row.souls
    assert_in_delta t0 + 1.minute, row.last_seen_at, 1
    assert_in_delta t0, row.started_at, 1, "started_at defaults to the first ping and is kept"
  end

  test "a ping without a worker is refused; unknown state and absurd values are dropped or clamped" do
    assert_raises(ArgumentError) { AgentDispatcher.ping!({ "worker" => " " }) }

    row = ping("d-2", state: "dancing", running: -4, host: "x" * 500)
    assert_nil row.state
    assert_equal 0, row.running
    assert_equal AgentDispatcher::FIELD_LIMIT, row.host.length
  end

  test "silent until a ping lands, live within SILENT_AFTER, silent after it" do
    now = Time.current
    assert AgentDispatcher.silent?(now: now)

    ping("d-3", at: now - AgentDispatcher::SILENT_AFTER + 30.seconds)
    refute AgentDispatcher.silent?(now: now)
    assert AgentDispatcher.silent?(now: now + 1.minute)
  end

  test "paused? reads paused_until against now" do
    now = Time.current
    row = ping("d-4", at: now, paused_until: (now + 10.minutes).iso8601, pause_reason: "usage_limit")
    assert row.paused?(now: now)
    refute row.paused?(now: now + 11.minutes)
  end

  test "prune deletes rows unheard-from for RETAIN but always keeps the newest" do
    now = Time.current
    ping("old-1", at: now - 9.days)
    ping("old-2", at: now - 8.days)

    AgentDispatcher.prune!(now: now)

    assert_equal %w[old-2], AgentDispatcher.pluck(:worker_id), "the newest row survives so its last ping stays readable"
    ping("fresh", at: now)
    AgentDispatcher.prune!(now: now)
    assert_equal %w[fresh], AgentDispatcher.pluck(:worker_id)
  end
end
