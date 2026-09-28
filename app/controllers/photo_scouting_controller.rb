# PHOTO SCOUTING — the calibration surface for reference-photo search.
#
# WHAT THIS PAGE IS FOR, in the operator's words: *"a new page in the model. Where
# the AI goes out pulls images for the person (athlete) in this case and then picks
# the 5 best photos to be used in the model. In this way I should have a good idea
# of what the raw found images look like and which ones your taste is picking up to
# use into the model build."*
#
# So it is a CALIBRATION surface, not a debug view, and the difference shows in what
# it refuses to summarise. It answers two questions side by side — what did the
# search actually return, and why did these win — and then asks the operator for HIS
# answer to the second one so the two can be compared. A page that only reported
# would leave his taste in his head; #verdict is what gets it into a column.
#
# IT SHOWS THE PIPELINE'S OWN WORST RESULTS ON PURPOSE. Two measured defects live in
# this lane and `reference-photos-wrong-person` guarded both: a clear photograph of the
# WRONG MAN outranked a helmeted photograph of the right one, and the top-ranked
# photograph was one Higgsfield REFUSES to mint. The guards are a title check and a
# measured face-size floor, and BOTH HAVE STATED LIMITS the honesty panel still prints —
# a calibration page that replaced the warnings with a clean bill of health would be
# worse than no page, because the operator would calibrate against a picture of the
# system that was not true.
#
# ⚠ THE PAGE IS PUBLIC TO READ AND ADMIN-ONLY TO WRITE, and `require_admin` rather
# than a session is the gate for the same reason it is on AppearancesController: hub
# signup is OPEN — magic-link and Google are both create-or-login — so "needs a
# session" means "needs an email address" and is no control at all. #search buys one
# provider query plus up to GatherReferencePhotos::VISION_SHORTLIST vision
# classifications. #verdict spends nothing, and is gated anyway: it records the
# OPERATOR's taste as the reference the ranking will be measured against, and a
# stranger's opinion mixed into that column would corrupt the one signal this page
# exists to collect.
class PhotoScoutingController < ApplicationController
  skip_before_action :require_authentication, only: [:show]
  # BEFORE the record lookups, exactly as on AppearancesController: a request that
  # may not write has no business costing us three queries on its way to a redirect.
  before_action :require_admin, except: [:show]
  before_action :set_person
  before_action :set_appearance

  def show
    load_scouting
  end

  # BUY ONE QUERY PER VARIANT and re-file every candidate they return.
  #
  # This is the action the operator's "the AI goes out and pulls images" names, and
  # until Appearances::ImageSearch::WikimediaCommons shipped it could not run on any
  # machine: Serper was the only provider and `SERPER_API_KEY` exists nowhere. The
  # keyless provider is what makes this button real rather than decorative.
  #
  # ⚠ IT NOW COSTS FOUR QUERIES RATHER THAN ONE — one per
  # Appearances::GatherReferencePhotos::QUERY_VARIANTS entry, because providers bill per
  # query and the fan-out is four questions rather than a bigger answer to one. The
  # flash sentence names the count for that reason.
  def search
    if @appearance.nil?
      return redirect_to scouting_path,
                         alert: "#{@person.full_name} has no look to search against. " \
                                "Create one on the person page first."
    end

    summary = Appearances::GatherReferencePhotos.call(@appearance)

    if !summary.configured?
      redirect_to scouting_path, alert: unconfigured_message
    elsif summary.returned.zero?
      redirect_to scouting_path,
                  alert: "#{summary.provider_name || 'The search'} returned nothing for " \
                         "\"#{summary.query}\" or any of its " \
                         "#{summary.variant_count} variant(s). Nothing was filed and " \
                         "nothing changed."
    else
      # THE SUMMARY CHOOSES THE FLASH KEY, because a blind face classifier is an
      # ALERT rather than a notice: the run "succeeded" -- candidates were filed and an
      # identity can be built from them -- so a green notice is exactly what let a
      # confidently wrong result read as a good one on 2026-09-26.
      redirect_to scouting_path, summary.flash_key => summary.sentence
    end
  end

  # RECORD THE OPERATOR'S VERDICT ON ONE CANDIDATE.
  #
  # ANSWERS JSON WITH THE RECOMPUTED TALLY, and the page renders what comes back
  # rather than adding up its own. The client has every number it would need to
  # predict the new totals, and predicting them is exactly the bug: a click that
  # failed on the server would still move the counters, and the operator would be
  # reading a calibration figure that no row supports. The server is the only thing
  # that knows what was stored, so the server says what the tally now is.
  #
  # TOGGLES OFF when the same verdict is re-sent, because the fastest correction for
  # a misclick is the button you just pressed, and "no opinion" has to be reachable
  # or the first click on a tile is permanent.
  def verdict
    photo = AppearanceReferencePhoto.find_by(slug: params[:photo_slug],
                                            appearance_slug: @appearance&.slug)
    return render(json: { error: "no such candidate on this look" }, status: :not_found) if photo.nil?

    wanted = params[:verdict].to_s
    unless AppearanceReferencePhoto::VERDICTS.include?(wanted)
      return render json: { error: "verdict must be keep or drop" }, status: :unprocessable_entity
    end

    settled = photo.operator_verdict == wanted ? nil : wanted
    photo.update!(operator_verdict: settled,
                  operator_verdict_at: settled.nil? ? nil : Time.current)

    # RELOADED FROM THE DATABASE rather than patched in memory, so the tally counts
    # what was actually written — including the row this request just changed.
    load_scouting
    render json: {
      photo_slug: photo.slug,
      verdict: photo.operator_verdict,
      state: photo.calibration_state,
      tally: @tally.to_h
    }
  end

  private

  def set_person
    @person = Person.find_by!(slug: params[:person_slug])
  end

  # THE LOOK THE PHOTOGRAPHS ARE FILED AGAINST. nil is a REAL state — a person with
  # no looks yet — and the page renders an explanation rather than 404ing, because a
  # person page links here and a dead link would read as a broken feature.
  def set_appearance
    slug = @person.resolve_default_appearance!
    @appearance = slug.present? ? @person.appearances.find_by(slug: slug) : nil
  end

  def scouting_path = person_scouting_path(@person.slug)

  def load_scouting
    @candidates = candidates
    # THE SEARCH'S OWN OUTPUT, IN THE ARCHIVE'S OWN ORDER — the first question the
    # page answers. Floor rows are excluded here because they are INPUTS we control
    # (our mirrored headshot, a URL the operator typed) and were never returned by a
    # search; including them in the column that judges the search would credit it
    # with photographs it did not find.
    @found = @candidates.select(&:from_search?).sort_by { |p| [p.position || Float::INFINITY, p.id] }
    @chosen = @candidates.select(&:chosen?)
    @rejected = @candidates.reject(&:chosen?)
    # THE TALLY COVERS THE SEARCH ROWS ONLY, because they are the only rows a verdict
    # can be stored on: Appearances::ReferenceSet builds the floor in memory, so
    # those tiles have no persisted row to write to. That is the honest population
    # anyway — the ranking under calibration is the one applied to search results.
    @tally = Appearances::Calibration.for(@found)

    @search_available = Appearances::ImageSearch.available?
    @search_provider = Appearances::ImageSearch.provider_name
    # ALL FOUR QUERIES, NOT THE ONE. A search now buys one query per
    # Appearances::GatherReferencePhotos::QUERY_VARIANTS entry, and the operator cannot
    # judge a search whose questions he cannot see — nor calibrate a variant list he
    # cannot read. The page prints every query the button would buy.
    @search_queries = @appearance ? Appearances::GatherReferencePhotos.new(@appearance).queries : []
    # THE SUBJECT, which is what every variant is built from and what the per-variant
    # breakdown strips off each row's stored query to label it.
    @search_subject = @search_queries.first
    # WHAT EACH VARIANT ACTUALLY CONTRIBUTED, off the ROWS rather than off a summary.
    # The summary exists only inside the request that ran the search; the page is a GET
    # after a redirect and on every later visit, so the persisted `query` column is the
    # only source that can answer this at all — and it is the honest one, because it says
    # which variant found the photograph rather than which variant we hoped would.
    @variant_breakdown = variant_breakdown(@found)
    # READ OFF THE ROWS, NOT OFF THE CREDENTIAL. These answer different questions: a
    # key that landed this morning says nothing about how the gallery on screen was
    # ordered, and the gallery on screen is what the operator is judging.
    @face_ranked = @found.any?(&:face_scored?)
    # READ SEPARATELY FROM `@face_ranked`, because "something looked" and "something
    # measured how big the face is" are different states of this gallery and the second is
    # the one that decides what Higgsfield's trainer may be offered. A single flag would
    # print "ranked by face" over a gallery ordered on the weaker signal.
    @face_sized = @found.any?(&:face_sized?)
    @face_ranking_available = Appearances::FaceVisibility.available?
    @chosen_limit = Appearances::GatherReferencePhotos::CHOSEN_LIMIT
    @vision_shortlist = Appearances::GatherReferencePhotos::VISION_SHORTLIST
  end

  # ONE ROW PER VARIANT: what it found, and how much of it survived to the model.
  #
  # ⚠ EVERY VARIANT APPEARS, INCLUDING THE ONES THAT FOUND NOTHING, and that is the whole
  # reason this is built from `#queries` rather than by grouping the rows. A variant with
  # no row is the most useful line on the page — it is the query to drop — and grouping
  # rows alone would render it as absence, which reads as "not asked" rather than "asked
  # and came back empty".
  #
  # ROWS FILED BEFORE THE FAN-OUT LANDED CARRY THE OLD SINGLE QUERY, which matches the
  # bare-name variant's spelling exactly, so they group under it rather than into a
  # mystery bucket. Anything that matches no current variant is collected under a final
  # "an earlier search" row rather than dropped, because a candidate in the gallery that
  # appears in no breakdown row would make the counts disagree with the tiles.
  def variant_breakdown(found)
    by_query = found.group_by { |photo| photo.query.to_s }
    rows = @search_queries.map do |query|
      photos = by_query.delete(query) || []
      { query: query, found: photos.length, chosen: photos.count(&:chosen?) }
    end
    leftover = by_query.values.flatten
    return rows if leftover.empty?

    rows + [{ query: nil, found: leftover.length, chosen: leftover.count(&:chosen?) }]
  end

  def candidates
    return [] if @appearance.nil?

    Appearances::ReferenceSet.new(@appearance).gallery
  end

  # NAMES THE CREDENTIAL, because the reader of this message is whoever would set it.
  # Reachable only if every registered provider answers `available?` false, which the
  # keyless provider makes unlikely rather than impossible — a registry edit or a
  # stubbed provider still lands here, and a page that rendered a bare "off" would
  # send the operator to ask somebody.
  def unconfigured_message
    "No image-search provider is configured, so nothing was searched and nothing " \
      "was spent. Set #{Appearances::ImageSearch::Serper::API_KEY_ENV} to turn it on."
  end
end
