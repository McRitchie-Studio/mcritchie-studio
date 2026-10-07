class Content
  class ArtifactPlan
    # THE UPSTREAM HALF OF THE PLAN: the assets a character-model build consumes,
    # each answering BEFORE the build starts — reuse it, refresh it, or acquire it.
    #
    # The chain is anchor -> references -> identity / sheet. Staleness is causal,
    # never calendar: a built asset is stale when an input changed after it was
    # built, judged as one timestamp comparison per edge.
    #
    # Same rule as Slot: `occupant` is the row on file. There is no second member.
    class ModelInputs
      Asset = Struct.new(:kind, :label, :decision, :occupant, :url, :stale, :detail, keyword_init: true) do
        def reuse?   = decision == :reuse
        def refresh? = decision == :refresh
        def acquire? = decision == :acquire
        def stale?   = stale == true
      end

      # WHICH ASSETS EACH BUILD CANNOT START WITHOUT. References and identity are
      # advisory: the headshot alone builds a sheet, and a mint is what makes an
      # identity.
      REQUIRED = { sheet: %i[anchor], identity: %i[anchor] }.freeze

      def initialize(appearance)
        @appearance = appearance
      end

      def assets = [anchor, references, identity, sheet]

      # THE REFUSAL, or nil. A sentence naming what is missing and how to get it,
      # because every build past this line spends money.
      def refusal_for(build)
        missing = REQUIRED.fetch(build).map { |kind| public_send(kind) }.select(&:acquire?)
        return nil if missing.empty?

        "#{person_name} cannot be built: #{missing.map(&:detail).join('; ')}. " \
          "Nothing was generated and nothing was spent."
      end

      def anchor
        @anchor ||= if @appearance.music_video_look? then video_still_anchor
                    elsif @appearance.character_owned? then character_anchor
                    elsif athlete then headshot_anchor
                    else operator_anchor
                    end
      end

      def references
        @references ||= begin
          set = Appearances::ReferenceSet.new(@appearance)
          rows = set.persisted_rows
          decision, detail =
            if rows.empty?
              [:acquire, "no reference photos gathered — run the search on the look page (optional: " \
                         "the anchor alone can build)"]
            elsif set.refused_rows.any?
              [:refresh, "#{set.refused_rows.length} chosen photo(s) fail today's eligibility rule — re-judge them"]
            else
              [:reuse, "#{rows.count(&:chosen?)} of #{rows.length} gathered photo(s) chosen"]
            end
          Asset.new(kind: "references", label: "Reference photos", decision: decision,
                    occupant: rows, detail: detail)
        end
      end

      def identity
        @identity ||= begin
          id = @appearance.higgsfield_reference_id
          minted_at = @appearance.higgsfield_reference_minted_at
          stale = stale_since?(minted_at)
          decision, detail =
            if id.blank?
              [:acquire, "no character identity minted"]
            elsif stale
              [:refresh, "#{changed_inputs_since(minted_at).join(' and ')} changed after the identity was minted"]
            elsif minted_at.nil?
              [:reuse, "identity #{id} — mint time unrecorded, so its staleness cannot be judged"]
            elsif @appearance.higgsfield_reference_ready? || @appearance.higgsfield_reference_pending?
              [:reuse, "identity #{id} (#{@appearance.higgsfield_reference_status})"]
            else
              [:refresh, "identity #{id} ended #{@appearance.higgsfield_reference_status.inspect} — mint again"]
            end
          Asset.new(kind: "identity", label: "Character identity", decision: decision,
                    occupant: id.presence, stale: stale, detail: detail)
        end
      end

      def sheet
        @sheet ||= begin
          artifact = Artifact.live.where(kind: "character_sheet")
                             .joins(:subjects).where(artifact_subjects: { appearance_slug: @appearance.slug })
                             .order(created_at: :desc).first
          stale = artifact.present? && stale_since?(artifact.created_at)
          decision, detail =
            if artifact.nil?
              [:acquire, "no character sheet on file"]
            elsif stale
              [:refresh, "#{changed_inputs_since(artifact.created_at).join(' and ')} changed after the sheet was generated"]
            else
              [:reuse, "sheet #{artifact.slug} built after its inputs"]
            end
          Asset.new(kind: "sheet", label: "Character sheet", decision: decision,
                    occupant: artifact, url: artifact&.image_url, stale: stale, detail: detail)
        end
      end

      private

      def athlete = @athlete ||= @appearance.person&.athlete_profile

      def person_name = @appearance.owner_name

      # A CHARACTER IS ANCHORED BY ITS OWN REFERENCE ART: the look's reference URL or
      # its first chosen upload, in the order the sheet would send them. Never a
      # headshot or a search hit — a character has no face to find.
      def character_anchor
        url = Appearances::ReferenceSet.new(@appearance).generation_urls.first
        Asset.new(kind: "anchor", label: "Anchor art", decision: url ? :reuse : :acquire,
                  occupant: url, url: url,
                  detail: url ? "the look's reference art" : "no reference art — add an image to the look")
      end

      # AN ATHLETE IS ANCHORED BY THE CACHED HEADSHOT AND NOTHING ELSE. A typed URL
      # is free text, and a wide action shot was measured to fail at prepare.
      def headshot_anchor
        rows = athlete.image_caches.select { |c| c.purpose == Appearances::ReferenceImages::HEADSHOT_PURPOSE }
        row = Appearances::GenerateArtifact::IDENTITY_VARIANTS
              .filter_map { |v| rows.find { |c| c.variant == v } }.first
        source = athlete.espn_headshot_url
        decision, detail =
          if row.nil?
            [:acquire, headshot_remedy(source)]
          elsif source.present? && row.source_url.present? && row.source_url != source
            [:refresh, "cached headshot came from a source ESPN has since moved — re-cache it"]
          else
            [:reuse, "cached headshot (#{row.variant})"]
          end
        Asset.new(kind: "anchor", label: "Anchor headshot", decision: decision,
                  occupant: row, url: row&.url, detail: detail)
      end

      def headshot_remedy(source)
        if source.present?
          "no cached headshot — cache it with `bin/rails nfl:upload_headshots`"
        else
          "no cached headshot and no ESPN headshot source on file — re-validate the athlete from ESPN first"
        end
      end

      # A MUSIC-VIDEO LOOK IS ANCHORED BY ITS CLEAREST STILL from that video, not
      # by a headshot: the look is how they appear in this video.
      def video_still_anchor
        url = Appearances::VideoStills.urls(@appearance).first
        Asset.new(kind: "anchor", label: "Anchor still", decision: url ? :reuse : :acquire,
                  occupant: url, url: url,
                  detail: url ? "clearest still from the video" : "no reachable still of this performer from the video")
      end

      def operator_anchor
        url = @appearance.reference_url.presence
        ok = url.present? && Appearances::FetchableUrl.ok?(url)
        Asset.new(kind: "anchor", label: "Anchor photo", decision: ok ? :reuse : :acquire,
                  occupant: (url if ok), url: (url if ok),
                  detail: ok ? "operator reference photo" : "no reference photo — add one to the look")
      end

      # WHEN EACH INPUT LAST CHANGED. The headshot's bytes change only when its rows
      # are recreated (Studio::ImageCache.cache! never rewrites a variant), so
      # created_at; a re-key bumps updated_at without changing the face. Every
      # reference row counts, chosen or not, because un-choosing is a removal.
      def input_times
        @input_times ||= {
          "the anchor headshot" => (anchor.occupant.created_at if anchor.occupant.respond_to?(:created_at)),
          "the reference photos" => references.occupant.map(&:updated_at).max
        }.compact
      end

      def changed_inputs_since(time) = input_times.select { |_, at| at > time }.keys

      def stale_since?(time) = time.present? && changed_inputs_since(time).any?
    end
  end
end
