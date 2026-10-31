module Media
  # Exactly-once delivery for a chat medium whose send API has NO idempotency
  # key (Slack's chat.postMessage, the Bot Connector's activities), shared by
  # Media::Slack and Media::Teams (docs/agents/system/agent-message-loop.md,
  # "Slack" and "Teams"): the reply claim on the row, the outbound ledger
  # (SlackPost, scoped by `medium`) and the noise caps (Media::Limits).
  #
  # REPLY, ONCE, WITHOUT A NONCE. #deliver_once LOCKS THE ROW, writes a
  # `reply_sending` event, commits, and only then sends:
  #   sent         the medium's id is stored (reply_external_id): no job sends again.
  #   NotPosted    provably not sent, worth retrying (a 429): `reply_not_posted`
  #                is recorded and the error raised, so AgentMessageReplyJob's
  #                retry_on Media::Error tries again.
  #   Refused      provably not sent, a retry would be refused too: failed, not
  #                retried.
  #   Ambiguous    it may have been sent (a read timeout, a 5xx): failed, NOT
  #                retried; the timeline says to look in the channel.
  # A job that finds a `reply_sending` with no outcome after it either sees a
  # live attempt (younger than IN_FLIGHT, it leaves it alone) or a crashed one
  # (older: failed as ambiguous, never re-sent).
  #
  # The including adapter defines `key`, `actor`, `limits`, `configured?`, the
  # error classes NotPosted, Refused, Ambiguous and Suppressed (each a
  # Media::Error carrying `code`), and these hooks:
  #   reply_thread(message)  the thread id a reply goes in (the ledger's thread_ts)
  #   unconfigured_reason    why a reply is skipped when credentials are absent
  module OnceDelivery
    SENDING_EVENT = "reply_sending".freeze
    NOT_POSTED_EVENT = "reply_not_posted".freeze
    SUPPRESSED_EVENT = "reply_suppressed".freeze
    # How long a `reply_sending` may stand before it is taken for a crashed
    # attempt: well past every client's open + read timeouts.
    IN_FLIGHT = 2.minutes

    private

    # The reply skeleton: skip, cap, claim, then `yield` sends the one message
    # and answers the medium's id for it.
    def deliver_once(message)
      return skipped!(message) unless configured?

      return nil if message.reply_external_id.present? || %w[failed skipped].include?(message.reply_status)
      if (reason = reply_cap_refusal(message))
        return suppressed!(message, reason)
      end

      case claim_attempt!(message)
      when :done, :in_flight then return nil
      when :stale then return failed!(message, "an earlier post attempt ended with no outcome; it may have posted, " \
                                               "so it is not re-posted (look in the channel)", ambiguous: true)
      end

      posted_id = yield.to_s
      message.update!(reply_external_id: posted_id, reply_posted_at: Time.current, reply_status: "posted")
      SlackPost.create!(medium: key, channel_id: message.channel_ref, thread_ts: reply_thread(message), ts: posted_id,
                        soul_slug: message.soul_slug, kind: "reply", status: "posted", agent_message_id: message.id)
      message.record!("reply_posted", actor: actor, detail: { "reply_id" => posted_id, "url" => message.reply_url })
    rescue self.class::NotPosted => e
      message.record!(NOT_POSTED_EVENT, actor: actor, detail: { "error" => e.code.to_s, "retry_after" => e.retry_after }.compact)
      raise
    rescue self.class::Refused => e
      message.record!(NOT_POSTED_EVENT, actor: actor, detail: { "error" => e.code.to_s })
      failed!(message, e.message)
    rescue self.class::Ambiguous => e
      failed!(message, "#{e.message}; not retried (look in the channel)", ambiguous: true)
    end

    # Under the row's lock: :done (already posted, or already failed by an
    # earlier attempt), :in_flight (a live attempt holds it), :stale (a crashed
    # attempt), or :go (a `reply_sending` is now committed for this attempt).
    def claim_attempt!(message)
      message.with_lock do
        next :done if message.reply_external_id.present? || message.reply_status == "failed"

        sending = message.events.where(kind: SENDING_EVENT)
        pending = sending.count > message.events.where(kind: NOT_POSTED_EVENT).count
        if pending
          next sending.maximum(:created_at) > IN_FLIGHT.ago ? :in_flight : :stale
        end

        message.record!(SENDING_EVENT, actor: actor, detail: { "attempt" => sending.count + 1 })
        :go
      end
    end

    # One standalone message through the ledger: claim (or reuse) its row, check
    # the caps, send (`yield`, answering the medium's response Hash with its id
    # under "ts"), and stamp the outcome. Answers that Hash.
    def ledgered(channel_id, soul:, thread_ts:, kind:, key:, release_slug:, limits:)
      row = claim_row!(channel_id, soul: soul, thread_ts: thread_ts, kind: kind, key: key, release_slug: release_slug)
      return { "ok" => true, "ts" => row.ts, "channel" => channel_id, "already_posted" => true } if row.status == "posted"

      if (reason = (limits || self.limits).refusal(channel_id: channel_id, soul: soul, kind: kind, thread_ts: thread_ts))
        row.update!(status: "suppressed", reason: reason[0, 250])
        Rails.logger.warn("[#{self.key}] suppressed a #{kind} post by #{soul} in #{channel_id}: #{reason}")
        raise self.class::Suppressed.new(reason, code: "suppressed")
      end

      posted = yield
      row.update!(status: "posted", ts: posted["ts"].to_s, reason: nil)
      posted
    rescue self.class::NotPosted, self.class::Refused => e
      row&.update!(status: "failed", reason: "#{e.code}: #{e.message}"[0, 250])
      raise
    rescue self.class::Ambiguous => e
      row&.update!(status: "failed", reason: "#{SlackPost::AMBIGUOUS} #{e.message}"[0, 250])
      raise
    end

    # The row this attempt writes, `sending`. With a key: the posted row when
    # the key was already posted; raises when it must never be posted again.
    def claim_row!(channel_id, soul:, thread_ts:, kind:, key:, release_slug:)
      attrs = { medium: self.key, channel_id: channel_id.to_s, soul_slug: soul&.to_s, thread_ts: thread_ts,
                kind: kind.to_s, release_slug: release_slug, status: "sending" }
      return SlackPost.create!(attrs) if key.nil?

      SlackPost.transaction(requires_new: true) do
        row = SlackPost.lock.find_by(idempotency_key: key)
        if row.nil?
          SlackPost.create!(attrs.merge(idempotency_key: key))
        elsif row.status == "posted"
          row
        elsif row.final?
          raise (row.status == "suppressed" ? self.class::Suppressed : self.class::Ambiguous).new(
            "#{key} was #{row.status} before (#{row.reason.presence || 'an attempt with no outcome'}); not posted again",
            code: row.status
          )
        else
          row.update!(attrs)
          row
        end
      end
    rescue ActiveRecord::RecordNotUnique
      raise self.class::Ambiguous.new("#{key} is being posted by another attempt; not posted again", code: "in_flight")
    end

    def reply_cap_refusal(message)
      owner = limits.owner_user_id
      limits.refusal(channel_id: message.channel_ref, soul: message.soul_slug, kind: "reply",
                     thread_ts: reply_thread(message),
                     owner_reply: owner.present? && message.author_ref.to_s == owner)
    end

    # Over a cap: the row is marked (skipped, a reply_suppressed event naming the
    # cap) so the job never retries it, and the ledger records it.
    def suppressed!(message, reason)
      message.update_column(:reply_status, "skipped")
      message.record!(SUPPRESSED_EVENT, actor: actor, detail: { "reason" => reason[0, 300] })
      SlackPost.create!(medium: key, channel_id: message.channel_ref, thread_ts: reply_thread(message),
                        soul_slug: message.soul_slug, kind: "reply", status: "suppressed", reason: reason[0, 250],
                        agent_message_id: message.id)
      Rails.logger.warn("[#{key}] suppressed #{message.soul_slug}'s reply to message #{message.id}: #{reason}")
      nil
    end

    def failed!(message, error, ambiguous: false)
      message.update_column(:reply_status, "failed")
      message.record!("reply_failed", actor: actor, detail: { "error" => error.to_s[0, 300], "ambiguous" => ambiguous || nil }.compact)
      nil
    end

    def skipped!(message)
      message.update_column(:reply_status, "skipped")
      message.record!("reply_skipped", actor: actor, detail: { "reason" => unconfigured_reason })
      nil
    end
  end
end
