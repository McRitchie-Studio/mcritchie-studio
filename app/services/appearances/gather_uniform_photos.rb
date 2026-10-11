# frozen_string_literal: true

module Appearances
  # FIND GAME-ACTION PHOTOS OF ONE LOOK'S UNIFORM and file every candidate, chosen by
  # nobody (task player-sheet-uniform-and-build; the operator, 2026-10-11: "you will
  # most likely want to pull these off of live game action").
  #
  # THE SAME MACHINERY AND THE SAME OPERATOR LOOP AS THE FACE PHOTOS: the search goes
  # through Appearances::ImageSearch (whichever provider is available), every result
  # is kept as a row, and a human picks. Unlike Appearances::GatherReferencePhotos it
  # ranks nothing and classifies nothing: no vision call is bought, because the
  # question "does this show the jersey's badges clearly?" is the operator's eye, and
  # he picks at most AppearanceUniformPhoto::CHOSEN_LIMIT.
  #
  # ⚠ ONE SEARCH PER PRESS (a paid query on the paid provider). Admin-gated at the
  # call site, never run from a callback or a render.
  class GatherUniformPhotos
    RESULT_LIMIT = 12

    Summary = Struct.new(:query, :provider_name, :returned, :filed, keyword_init: true) do
      def sentence
        "#{provider_name || 'The search'} returned #{returned} for \"#{query}\"; " \
          "#{filed} new candidate(s) filed. Pick up to #{AppearanceUniformPhoto::CHOSEN_LIMIT}."
      end
    end

    def self.call(appearance) = new(appearance).call

    def initialize(appearance)
      @appearance = appearance.uniform_source
    end

    # "<player> <team> <colourway> game action": the player because his own game
    # photos show his own patches (a captain's C), the team and colourway so the
    # jersey is the right one, "game action" so the results are worn uniforms under
    # stadium light rather than retail product shots.
    def query
      colourway = CharacterSheetPrompt.new(@appearance).colourway
      colourway = nil if colourway == "team"
      [@appearance.person&.full_name, GatherReferencePhotos.new(@appearance).team_name, colourway, "game action"]
        .compact_blank.join(" ")
    end

    def call
      answer = ImageSearch.search(query: query, limit: RESULT_LIMIT, target: @appearance)
      known = @appearance.uniform_photos.pluck(:image_url).to_set
      filed = 0
      answer.results.each_with_index do |result, index|
        next if result.image_url.blank? || known.include?(result.image_url)

        @appearance.uniform_photos.create!(
          image_url: result.image_url, thumb_url: result.thumb_url, page_url: result.page_url,
          title: result.title, width: result.width, height: result.height, query: query,
          provider: answer.provider_name, position: result.position || index
        )
        known << result.image_url
        filed += 1
      end
      Summary.new(query: query, provider_name: answer.provider_name, returned: answer.results.length, filed: filed)
    end
  end
end
