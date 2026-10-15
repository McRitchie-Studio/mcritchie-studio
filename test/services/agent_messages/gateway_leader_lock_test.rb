require "test_helper"

# [unit] + [integration] AgentMessages::GatewayLeaderLock — one Gateway
# connection per bot token. Each "listener" here gets its OWN Postgres
# connection (not the test's pinned one), because a session advisory lock is
# per backend and re-entrant within one.
class AgentMessages::GatewayLeaderLockTest < ActiveSupport::TestCase
  Lock = AgentMessages::GatewayLeaderLock

  def dedicated_connection
    config = ActiveRecord::Base.connection_pool.db_config
    config.adapter_class.new(config.configuration_hash).tap { |c| (@connections ||= []) << c }
  end

  teardown { Array(@connections).each(&:disconnect!) }

  def key = Lock.key_for("lock-test-#{Process.pid}-#{name}")

  test "[unit] the key is a stable positive 63-bit digest of the token, distinct per token, never the token" do
    first = Lock.key_for("token-a")
    assert_equal first, Lock.key_for("token-a")
    refute_equal first, Lock.key_for("token-b")
    assert_operator first, :>, 0
    assert_operator first, :<, 2**63
    refute_includes first.to_s, "token-a"
  end

  test "[unit] held? is false before acquire, true after, false after release" do
    lock = Lock.new(key: key, connection: dedicated_connection)
    refute lock.held?
    assert lock.acquire
    assert lock.held?
    lock.release
    refute lock.held?
  end

  test "[unit] held? asks Postgres, so a reconnected backend (the lock gone with the old one) answers false" do
    connection = dedicated_connection
    lock = Lock.new(key: key, connection: connection)
    assert lock.acquire

    connection.reconnect!

    refute lock.held?, "the old backend's lock died with it; the listener must stand down"
  end

  test "[integration] a second listener cannot take the lock while the first holds it, and takes it once released" do
    shared_key = key
    first = Lock.new(key: shared_key, connection: dedicated_connection)
    second = Lock.new(key: shared_key, connection: dedicated_connection)

    assert first.acquire
    refute second.acquire, "one connection per bot token"
    refute second.held?

    first.release
    assert second.acquire
    assert second.held?
  end

  test "[integration] a lost holder frees the lock for the next listener" do
    shared_key = key
    holder_connection = dedicated_connection
    first = Lock.new(key: shared_key, connection: holder_connection)
    second = Lock.new(key: shared_key, connection: dedicated_connection)
    assert first.acquire
    refute second.acquire

    holder_connection.disconnect! # a dyno that died: its backend goes, and the lock with it

    # Postgres frees a closed session's locks once its backend exits, which is
    # asynchronous to the client's close; the listener retries, and so does this.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    acquired = false
    until (acquired = second.acquire) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    assert acquired, "the dead holder's lock was never freed"
  end
end
