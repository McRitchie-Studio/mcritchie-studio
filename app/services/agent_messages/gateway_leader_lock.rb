require "digest"

module AgentMessages
  # Leader election for the Discord Gateway listener: exactly one connection per
  # bot token, across every worker process and across a dyno restart's overlap.
  #
  # It is a Postgres SESSION advisory lock, keyed by a digest of the token (the
  # token itself never leaves the process), taken on the ONE database connection
  # the listener thread holds for its whole life. The holder renews by holding
  # the session: the lock lives exactly as long as that backend does. A lost
  # connection loses the lock, and because Active Record reconnects silently,
  # `held?` asks Postgres whether THIS backend still holds it rather than
  # trusting a flag. A false `held?` makes the listener stand down.
  class GatewayLeaderLock
    NAMESPACE = "agent-messages:discord-gateway:".freeze

    attr_reader :key

    # A positive 63-bit key, stable for one token and unrelated across tokens.
    def self.key_for(token)
      Digest::SHA256.digest("#{NAMESPACE}#{token}").unpack1("Q>") & 0x7FFF_FFFF_FFFF_FFFF
    end

    def initialize(key:, connection:)
      @key = Integer(key)
      @connection = connection
      @held = false
    end

    # Try once, without waiting. True when this connection now holds the lock.
    def acquire
      @held = ActiveModel::Type::Boolean.new.cast(@connection.select_value("SELECT pg_try_advisory_lock(#{@key})")) || false
    rescue ActiveRecord::ActiveRecordError, PG::Error
      @held = false
    end

    # The predicate the listener re-checks while connected: does the backend
    # behind this connection hold the lock right now? A reconnected connection
    # is a new backend, so it answers false even though nothing was released.
    def held?
      return false unless @held

      @held = ActiveModel::Type::Boolean.new.cast(@connection.select_value(<<~SQL)) || false
        SELECT EXISTS (
          SELECT 1 FROM pg_locks
          WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid() AND objsubid = 1
            AND ((classid::bigint << 32) | objid::bigint) = #{@key}
        )
      SQL
    rescue ActiveRecord::ActiveRecordError, PG::Error
      @held = false
    end

    def release
      return unless @held

      @held = false
      @connection.select_value("SELECT pg_advisory_unlock(#{@key})")
    rescue ActiveRecord::ActiveRecordError, PG::Error
      nil
    end
  end
end
