module BuildIntake
  # The visitor's TAP on an intake card: the only thing that writes an intake
  # field. Every value is checked again here, on the server, whatever the card
  # said: a palette or an idea is taken from the stored card (by message and
  # index, never from posted JSON), a name or an address from the post, held to
  # the same rules the card was.
  #
  #   idea     message_id            → answers (idea, audience, day_one)
  #   cto      name, portrait        → cto_name, cto_avatar
  #   palette  message_id, index     → palette
  #   address  subdomain             → subdomain (claimed only at Build, by queue!)
  class Choice
    class Refused < StandardError; end

    FIELDS = %w[idea cto palette address].freeze

    def initialize(request)
      @request = request
    end

    # The request, saved. Raises Refused with a message for the visitor.
    def apply!(field, params)
      raise Refused, "This request is already in the build queue." unless @request.draft?
      raise Refused, "Unknown choice." unless FIELDS.include?(field.to_s)

      send(:"choose_#{field}", params)
      @request.save!
      @request
    rescue ActiveRecord::RecordInvalid => e
      raise Refused, e.record.errors.full_messages.to_sentence.presence || "That choice could not be saved."
    end

    private

    def choose_idea(params)
      card = card_for(params[:message_id], "idea")
      @request.answers = card.slice("idea", "audience", "day_one")
    end

    def choose_cto(params)
      name = Card.cto_name(params[:name].to_s)
      raise Refused, "Use 2 to 24 letters for your CTO's name." unless name

      portrait = params[:portrait].to_s
      raise Refused, "Pick a portrait." unless Portraits.key?(portrait)

      @request.cto_name = name
      @request.cto_avatar = portrait
    end

    def choose_palette(params)
      card = card_for(params[:message_id], "palette")
      index = params[:index].to_s
      chosen = index.match?(/\A\d\z/) ? Array(card["palettes"])[index.to_i] : nil
      raise Refused, "Pick one of the palettes." unless chosen

      verdict = Card.palette(chosen)
      raise Refused, "That palette cannot be used: #{verdict.reason}." unless verdict.ok?

      @request.palette = verdict.card
    end

    def choose_address(params)
      reason = AppRequest.unavailable_reason(params[:subdomain], except: @request)
      raise Refused, reason if reason

      @request.subdomain = AppRequest.normalize_subdomain(params[:subdomain])
    end

    # The stored, validated card a tap names, from THIS request's thread only.
    def card_for(message_id, kind)
      message = AgentMessage.find_by(id: message_id.to_s[/\A\d{1,18}\z/], channel: "web",
                                     thread_key: BuildIntake.thread_key(@request.token))
      card = message&.intake_card
      raise Refused, "That card is no longer available." unless card.is_a?(Hash) && card["card"] == kind

      card
    end
  end
end
