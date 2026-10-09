# frozen_string_literal: true

class Release
  # WHO HOLDS THE RELEASE LANE, AND WHAT A PRODUCTION GRANT COVERS, in plain words.
  #
  # One source for every surface that says it: the Next Release card on
  # /deployments, `bin/release status`, `release-claim status`, and the stand-down a
  # second `bin/release prepare` or `ship` prints. Each reads the sentences built
  # here, so the card and the CLI cannot drift into two accounts of one lane.
  #
  # A sentence is a list of PARTS: plain strings and Stamp slots. The CLI renders a
  # Stamp in UTC (#to_s); the card renders the same slot as the reader's own clock
  # (ApplicationHelper#lane_lease_sentence). The words are identical either way.
  #
  # THE GRANT POLICY is one decision, recorded on the grant itself: a production
  # grant covers everything on the release at ship time. A member that joins after
  # the grant rides on it with no second approval, so the grant record keeps the
  # member set at the moment it was given (Release#record_event! stamps it) and
  # these sentences name every later joiner.
  #
  # WHAT IS SHOWN OF A HOLDER: its mascot, its soul, the last four characters of its
  # session id, and since when. Never the nonce and never the whole session id.
  module LaneLease
    POLICY = "release_at_ship"
    SCOPE_KEY = "scope"
    ROLE_VERBS = { "assembler" => "assembling", "deployer" => "shipping" }.freeze
    ROLE_TITLES = { "assembler" => "Assembling", "deployer" => "Shipping" }.freeze
    STAMP_FORMAT = "%b %-d, %H:%M UTC"
    SESSION_TAIL = 4

    # A time inside a sentence, with the word that leads it ("at", "since").
    Stamp = Struct.new(:time, :prefix) do
      def to_s
        [prefix, time.utc.strftime(STAMP_FORMAT)].compact.join(" ")
      end
    end

    # One sentence. `tone` is the status tone the card paints it in.
    Sentence = Struct.new(:parts, :tone) do
      def to_s
        parts.map(&:to_s).join
      end
    end

    # One holder, resolved for display. `live` is the lease's own verdict.
    Holder = Struct.new(:role, :release_slug, :mascot, :soul, :session_tail, :since, :live, keyword_init: true) do
      def held?
        session_tail.present?
      end
    end

    module_function

    # The scope a grant record carries: the policy and the member set at that moment.
    def scope_for(release)
      { "policy" => POLICY, "member_slugs" => release.tasks.order(:position, :slug).pluck(:slug) }
    end

    # --- holders ----------------------------------------------------------------

    # { "assembler" => Holder, "deployer" => Holder } for one release slug, in two
    # queries whatever the number of roles.
    def holders(release_slug)
      rows = ReleaseConductorClaim.where(release_slug: release_slug.to_s).index_by(&:role)
      mascots = session_mascots(rows.values.filter_map(&:claimed_session))
      ReleaseConductorClaim::ROLES.index_with do |role|
        holder_for(rows[role], role: role, release_slug: release_slug, session_mascot: mascots[rows[role]&.claimed_session])
      end
    end

    def holder(claim)
      holder_for(claim, role: claim.role, release_slug: claim.release_slug,
                        session_mascot: session_mascots([claim.claimed_session].compact)[claim.claimed_session])
    end

    def holder_for(claim, role:, release_slug:, session_mascot: nil, now: Time.current)
      session = claim&.claimed_session.to_s
      Holder.new(
        role: role.to_s, release_slug: release_slug.to_s,
        mascot: mascot_name(session_mascot) || claim&.holder_label.presence,
        soul: claim&.holder_soul.presence,
        session_tail: session.presence && session.last(SESSION_TAIL),
        since: claim&.acquired_at,
        live: claim ? claim.live?(now: now) : false
      )
    end

    # "Mawile ♂ (steffon, session …9b57) is assembling rel-x since Oct 8, 01:15 UTC."
    def holder_sentence(holder)
      verb = ROLE_VERBS.fetch(holder.role)
      target = release_name(holder.release_slug)
      return Sentence.new(["Nobody is #{verb} #{target}."], :muted) unless holder.held?

      since = holder.since ? [" ", Stamp.new(holder.since, "since")] : []
      if holder.live
        Sentence.new([holder_name(holder), " is #{verb} #{target}", *since, "."], :primary)
      else
        Sentence.new([holder_name(holder), " held the #{holder.role} claim on #{target}", *since,
                      "; its lease has lapsed, so the claim is free to take."], :warning)
      end
    end

    def holder_name(holder)
      detail = [holder.soul, "session …#{holder.session_tail}"].compact.join(", ")
      holder.mascot.present? ? "#{holder.mascot} (#{detail})" : detail.upcase_first
    end

    def release_name(release_slug)
      release_slug.to_s == ReleaseConductorClaim::FORMING_SLUG ? "the next release" : release_slug.to_s
    end

    # --- the production grant ---------------------------------------------------

    # The sentences that state the production grant on one release: who answered,
    # when, in which mode, and what the answer covers. An active release with no
    # request says so; a finished one with none says nothing.
    def grant_sentences(release, now: Time.current)
      request = release.ship_authorization_request
      return (release.active? ? [Sentence.new(["No production approval has been asked for."], :muted)] : []) unless request

      mode = request.metadata.to_h["mode"].presence || "unrecorded"
      answer = release.ship_authorization_grant || release.ship_authorization_lapse
      return [waiting_sentence(release, request, mode, now)] unless answer

      members = release.tasks.order(:position, :slug).pluck(:slug)
      [answer_sentence(answer, mode), *scope_sentences(answer, members, shipped: release.shipped?)]
    end

    def waiting_sentence(release, request, mode, now)
      window = release.ship_authorization_window
      if window.nil?
        Sentence.new(["Production approval is waiting at the conductor's prompt, #{mode} mode."], :warning)
      elsif window.lapsed?(now)
        Sentence.new(["The production window closed ", Stamp.new(window.ends_at, "at"), " with no answer."], :warning)
      else
        Sentence.new(["Production approval is waiting on the owner: the window closes ",
                      Stamp.new(window.ends_at, "at"), "."], :warning)
      end
    end

    def answer_sentence(answer, mode)
      at = Stamp.new(answer.occurred_at, "at")
      via = answer.metadata.to_h["granted_via"].presence || answer.source.to_s
      actor = actor_name(answer.actor)
      parts =
        case via
        when "web"          then ["Approved by #{actor} ", at, ", #{mode} mode."]
        when "confirm"      then ["Confirmed at the conductor's prompt by #{actor} ", at, ", #{mode} mode."]
        when "auto"         then ["Proceeded on green with no approval asked ", at, ", #{mode} mode."]
        when "window-lapse" then ["No approval was given: the window lapsed ", at, " and the ship proceeded on green, #{mode} mode."]
        else ["Authorized by #{actor} through #{via} ", at, ", #{mode} mode."]
        end
      Sentence.new(parts, via == "web" ? :success : :warning)
    end

    # What the answer covers, and every member that joined or left after it.
    def scope_sentences(answer, members, shipped:)
      via = answer.metadata.to_h["granted_via"].to_s
      moment = via == "web" ? "approval" : "authorization"
      recorded = recorded_members(answer)
      lead = shipped ? "Covered every task on this release when it shipped" : "Covers every task on this release when it ships"
      now_word = shipped ? "at ship" : "now"
      if recorded.nil?
        return [Sentence.new(["#{lead}: member set at #{moment} not recorded, #{members.size} #{now_word}."], :muted)]
      end

      joined = members - recorded
      left = recorded - members
      lines = [Sentence.new(["#{lead}: #{recorded.size} at #{moment}, #{members.size} #{now_word}."], joined.any? ? :warning : :muted)]
      lines << Sentence.new(["Joined after #{moment}: #{joined.join(', ')}."], :warning) if joined.any?
      lines << Sentence.new(["Left after #{moment}: #{left.join(', ')}."], :muted) if left.any?
      lines
    end

    # The member set a grant record carries, or nil when it predates the stamp.
    def recorded_members(answer)
      scope = answer.metadata.to_h[SCOPE_KEY]
      slugs = scope.is_a?(Hash) ? scope["member_slugs"] : nil
      slugs.is_a?(Array) ? slugs.map(&:to_s) : nil
    end

    # --- one read for a whole surface ---------------------------------------------

    # Every lane sentence for one release, in card order: assembler, deployer, grant.
    def sentences(release, now: Time.current)
      holders(release.slug).values.map { |holder| holder_sentence(holder) } + grant_sentences(release, now: now)
    end

    # The plain lines `bin/release status` prints. With no active release, the
    # forming claim (a prepare creating the next release) is the lane.
    def status_lines(release, now: Time.current)
      return sentences(release, now: now).map(&:to_s) if release

      forming = holders(ReleaseConductorClaim::FORMING_SLUG)["assembler"]
      forming.held? && forming.live ? [holder_sentence(forming).to_s] : []
    end

    def session_mascots(session_ids)
      return {} if session_ids.empty?

      SessionMascot.where(session_id: session_ids).index_by(&:session_id)
    end

    def mascot_name(session_mascot)
      session_mascot&.pokemon&.display_name(gender: session_mascot.gender).presence
    end

    # The operator's name for a web grant (the Approve records an email); any other
    # actor reads as recorded.
    def actor_name(actor)
      value = actor.to_s.strip
      return "the operator" if value.empty?
      return value unless value.include?("@")

      User.find_by(email: value)&.name.presence || value
    end
  end
end
