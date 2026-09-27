module Webhooks
  # POST /webhooks/resend/events — Resend's delivery and engagement webhooks
  # (svix-signed), the source of the email analytics' delivered, bounced and
  # complained numbers (task email-event-log-webhooks).
  #
  # Resend sends every event on the account here, sign-in and receipt emails
  # included. Only broadcast emails have a delivery row, found by the Resend id
  # the sender stored (BroadcastDelivery#provider_message_id); anything else is
  # acknowledged and dropped. A permanent bounce or a spam complaint takes the
  # contact off the list at once: mailing either again is what gets a sender
  # suspended.
  class ResendEventsController < ActionController::Base
    include Webhooks::SvixSignature
    skip_before_action :verify_authenticity_token

    KINDS = {
      "email.sent" => "sent",
      "email.delivered" => "delivered",
      "email.delivery_delayed" => "delivery_delayed",
      "email.bounced" => "bounced",
      "email.complained" => "complained",
      "email.opened" => "opened",
      "email.clicked" => "clicked"
    }.freeze

    def create
      return head :unauthorized unless valid_svix_signature?(ENV["RESEND_EVENTS_WEBHOOK_SECRET"])

      payload = JSON.parse(request.raw_post)
      kind = KINDS[payload["type"]]
      data = payload["data"].is_a?(Hash) ? payload["data"] : {}
      delivery = kind && data["email_id"].present? && BroadcastDelivery.find_by(provider_message_id: data["email_id"])
      record(delivery, kind, payload, data) if delivery
      head :ok
    rescue JSON::ParserError
      head :bad_request
    end

    private

    def record(delivery, kind, payload, data)
      details = event_details(kind, data)
      event = delivery.record_event!(
        kind: kind, source: "resend",
        at: parse_time(payload["created_at"]) || Time.current,
        provider_event_id: request.headers["svix-id"],
        link_key: nil,
        machine: machine?(kind, data, delivery),
        data: details
      )
      return unless event

      if kind == "complained"
        delivery.contact.unsubscribe!(reason: "complained")
      elsif kind == "bounced" && details["bounce_kind"] == "hard"
        delivery.contact.unsubscribe!(reason: "bounced")
      end
    end

    def event_details(kind, data)
      case kind
      when "bounced"
        bounce = data["bounce"].is_a?(Hash) ? data["bounce"] : {}
        permanent = bounce["type"].to_s.match?(/permanent|hard/i)
        { "bounce_kind" => permanent ? "hard" : "soft", "bounce_type" => bounce["type"],
          "bounce_subtype" => bounce["subType"], "message" => bounce["message"] }.compact
      when "clicked"
        click = data["click"].is_a?(Hash) ? data["click"] : {}
        { "link" => click["link"], "user_agent" => click["userAgent"] }.compact
      else
        {}
      end
    end

    def machine?(kind, data, delivery)
      return false unless kind == "clicked"

      EmailEvents::MachineDetector.machine?(user_agent: data.dig("click", "userAgent"), sent_at: delivery.sent_at,
                                            at: parse_time(data.dig("click", "timestamp")) || Time.current)
    end

    def parse_time(value)
      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
