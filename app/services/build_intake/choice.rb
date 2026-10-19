module BuildIntake
  # The visitor's TAP on an intake card: the only thing that writes an intake
  # field. Every value is checked again here, on the server, whatever the card
  # said: a palette or an idea is taken from the stored card (by message and
  # index, never from posted JSON), a name or a domain from the post, held to
  # the same rules the card was.
  #
  #   idea       message_id            → answers (title, features, idea)
  #   idea_else  message_id            → nothing set; the idea this card set is cleared
  #   palette    message_id, index     → palette (the visitor reads "theme")
  #   cto        name or custom_name, portrait → cto_name, cto_avatar
  #   address    subdomain             → subdomain (claimed only at Build)
  #
  # Listed in the order Ray asks (BuildIntake::STEPS). No tap checks that the
  # step before it is set: the order is Ray's to ask, and a draft started under
  # the old order (CTO before theme) still takes its theme tap.
  #
  # EVERY TAP ALSO SPEAKS (.agents/epics/build-with-ray-v2.md, 2-5: "It wasn't
  # intuitive that I had to send another message after confirming"). Once the
  # field is saved, the tap posts the visitor's own turn into the request's
  # thread, a line written HERE from the saved value (RELAYS), never from the
  # post. It goes through BuildIntake::Ingest like a typed message, so the
  # dispatcher answers it with the next step within BuildIntake::Caps, and at a
  # cap the visitor reads the cap line instead. The write and the turn commit
  # together: a refused tap posts nothing, and so does a theme or domain tap on
  # the answer already saved (UNCHANGED_IS_A_NO_OP; #relay is then nil).
  class Choice
    class Refused < StandardError; end

    FIELDS = %w[idea idea_else palette cto address].freeze

    # The visitor's line for each tap, from the value just saved.
    RELAYS = {
      "idea" => ->(r) { "Let's build #{r.answers['title'].presence || r.answers['idea']}." },
      "idea_else" => ->(_r) { "I'd like to build something else." },
      "palette" => ->(r) { "Let's go with the #{r.palette['name']} theme." },
      "cto" => ->(r) { "My CTO is #{r.cto_name}." },
      "address" => ->(r) { "Let's use #{r.host}." }
    }.freeze

    # The taps that do nothing when they would save the value already saved.
    UNCHANGED_IS_A_NO_OP = %w[palette address].freeze

    attr_reader :relay

    def initialize(request, user: nil, ip: nil, ingest: nil)
      @request = request
      @ingest = ingest || Ingest.new(request: request, user: user, ip: ip)
    end

    # The request, saved, with #relay the visitor turn the tap posted. Raises
    # Refused with a message for the visitor.
    def apply!(field, params)
      raise Refused, "This request is already in the build queue." unless @request.draft?
      raise Refused, "Unknown choice." unless FIELDS.include?(field.to_s)

      AppRequest.transaction do
        send(:"choose_#{field}", params)
        # Choose Theme or Use Domain on the answer already saved: nothing to
        # write and nothing to tell Ray, so no turn is spent (the card also
        # disables its button while the pick is the saved one).
        unchanged = UNCHANGED_IS_A_NO_OP.include?(field.to_s) && !@request.changed?
        unless unchanged
          @request.save!
          @relay = @ingest.call(RELAYS.fetch(field.to_s).call(@request), client_id: params[:client_id])
        end
      end
      @request
    rescue ActiveRecord::RecordInvalid => e
      raise Refused, e.record.errors.full_messages.to_sentence.presence || "That choice could not be saved."
    rescue Ingest::Refused => e
      raise Refused, e.message
    end

    private

    def choose_idea(params)
      card = card_for(params[:message_id], "idea")
      @request.answers = { "title" => card["title"], "features" => card["features"],
                           "idea" => card["idea"].presence || card["title"] }.compact
    end

    # "Build something else": nothing to set. If this card's idea was the one
    # locked in, it is unlocked, so the checklist and Ray agree it is open.
    def choose_idea_else(params)
      card = card_for(params[:message_id], "idea")
      @request.answers = {} if @request.answers.is_a?(Hash) && @request.answers["title"].present? &&
                               @request.answers["title"] == card["title"]
    end

    def choose_cto(params)
      # A typed name wins over the picked one.
      name = Card.cto_name(params[:custom_name].to_s.presence || params[:name].to_s)
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
      raise Refused, "Pick one of the themes." unless chosen

      verdict = Card.palette(chosen)
      raise Refused, "That theme cannot be used: #{verdict.reason}." unless verdict.ok?

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
