# ONE LOOK'S CHARACTER MODEL — the photographs that went in, and what came out.
#
# NESTED UNDER THE PERSON because a look has no meaning without one: the URL
# `/people/drew-lock/models/look-abc123` reads as the sentence it is, and the
# person page links every look row straight here. A flat `/appearances/:slug`
# would have been shorter and would have made the operator's route to the page a
# URL they had to know.
#
# TWO OF THE THREE ACTIONS SPEND MONEY, AND THE ADMIN GATE IS WHAT STOPS THE
# PUBLIC SPENDING IT. #show is free — it reads rows and renders. #search buys one
# image-search query PLUS up to GatherReferencePhotos::VISION_SHORTLIST vision
# classifications; #mint buys one character identity, per look, from a vendor that
# serves no list endpoint to recall it from.
#
# A SESSION IS NOT A COST CONTROL, and this comment used to claim it was. Hub
# signup is OPEN — both magic-link and Google are create-or-login — so "not
# reachable without a session" means "reachable by anyone willing to type an email
# address", which is not a control over a paid endpoint at all. `require_admin` is
# the gate that costs something to get through, and it matches contents_controller
# beside it. #show stays public, matching the person page it is reached from.
#
# Nothing here runs from a callback, a sweep or a page render either: the render
# path reads rows and asks `available?`, and neither question spends.
class AppearancesController < ApplicationController
  skip_before_action :require_authentication, only: [:show]
  # BEFORE set_appearance ON PURPOSE. A request that may not spend has no business
  # costing us two lookups on its way to being refused.
  before_action :require_admin, except: [:show]
  before_action :set_appearance

  # THE PAGE THE OPERATOR JUDGES THE PIPELINE BY: the reference photographs on one
  # side, the character model they produced on the other.
  #
  # `@gallery` is every candidate — chosen and rejected — because the question the
  # page answers is "is the search any good?", and a gallery of winners alone
  # cannot answer it. See Appearances::GatherReferencePhotos for why the rejects
  # are kept.
  def show
    set_gallery
  end

  # BUY ONE IMAGE-SEARCH QUERY and file every candidate it returns.
  #
  # The summary goes into the flash rather than onto the record: it describes THIS
  # search ("serper returned 20, we understood 20, chose 6"), and the durable
  # facts it mentions are already the rows themselves. The one number that exists
  # nowhere else is `unparsed` — results whose shape we could not read — and that
  # is exactly the number a silent empty gallery would otherwise hide.
  def search
    summary = Appearances::GatherReferencePhotos.call(@appearance)

    if !summary.configured?
      redirect_to appearance_path, alert: unconfigured_message
    elsif summary.returned.zero?
      redirect_to appearance_path,
                  alert: "#{summary.provider_name || 'The search'} returned nothing for " \
                         "\"#{summary.query}\". Nothing was filed and nothing changed."
    else
      redirect_to appearance_path, notice: search_message(summary)
    end
  end

  # BUY ONE CHARACTER IDENTITY, built from the chosen photographs.
  #
  # `references:` is Appearances::ReferenceSet — the composed list, floor first,
  # then the chosen search hits. That injection IS the seam the search plugs into:
  # Appearances::CreateCharacterReference is untouched by any of this work.
  #
  # NO `force:`. A rebuild orphans the previous identity beyond recall (there is no
  # list endpoint on the vendor's side) and it is a second purchase, so it stays on
  # the rake task where FORCE=1 has to be typed deliberately.
  #
  # THE FAILURE PATH IS AN ErrorLog ROW, NOT ONLY A FLASH. A flash lives for one
  # redirect and is then gone; the operator who has to work out WHY a mint refused
  # is reading /admin/error_logs a day later, and `target: @appearance` is what puts
  # the look's slug on the row so they can find the right one.
  #
  # `rescue_and_log` RE-RAISES by design — that is what lets the action keep its own
  # answer. It logs, re-raises, and the rescue below turns the exception into the
  # flash the operator actually sees.
  def mint
    rescue_and_log(target: @appearance) { mint_identity }
  rescue StandardError => e
    redirect_to appearance_path, alert: "Higgsfield refused the request: #{e.message}"
  end

  # ASK THE VENDOR WHERE THE IDENTITY GOT TO. A read — free — and the only thing
  # that stops the stored status being a permanent `not_ready`. Free does not mean
  # it cannot fail, and a credential failure here is exactly as invisible as one in
  # #mint, so it is logged the same way.
  def refresh
    rescue_and_log(target: @appearance) { poll_identity }
  rescue StandardError => e
    redirect_to appearance_path, alert: "Could not reach Higgsfield: #{e.message}"
  end

  private

  # THE MINT ITSELF, split out so the one EXPECTED refusal is handled INSIDE the
  # logged block and therefore never reaches the logger. "This look has no
  # photographs" is a state of the record, not a failure of ours — an ErrorLog row
  # for it is noise in the one place an operator goes to find real failures. Every
  # other exception falls out of here and gets its row.
  def mint_identity
    id = Appearances::CreateCharacterReference.new(@appearance, references: Appearances::ReferenceSet).call
    redirect_to appearance_path,
                notice: "Character model #{id} requested from #{@appearance.reference_photo_count} " \
                        "photo(s). It is not usable until it reads ready — refresh to poll it."
  rescue Appearances::CreateCharacterReference::NoReferenceImages => e
    redirect_to appearance_path, alert: e.message
  end

  # "NOTHING TO POLL YET" IS ALSO A STATE RATHER THAN A FAILURE, so it answers here
  # instead of raising into the logger.
  def poll_identity
    status = Appearances::CreateCharacterReference.new(@appearance).refresh_status!
    if status.blank?
      redirect_to appearance_path, alert: "No character model to poll yet."
    else
      redirect_to appearance_path, notice: "Higgsfield says: #{status}."
    end
  end

  def set_appearance
    @person = Person.find_by!(slug: params[:person_slug])
    @appearance = @person.appearances.find_by!(slug: params[:slug])
  end

  def appearance_path = person_appearance_path(@person.slug, @appearance.slug)

  def set_gallery
    set = Appearances::ReferenceSet.new(@appearance)
    @gallery = set.gallery
    @search_rows = set.persisted_rows
    @identity_urls = set.call
    @artifacts = Artifact.live
                         .joins(:subjects)
                         .where(artifact_subjects: { appearance_slug: @appearance.slug })
                         .order(created_at: :desc)
                         .distinct
    @search_available = Appearances::ImageSearch.available?
    @search_provider = Appearances::ImageSearch.provider_name
    @search_query = Appearances::GatherReferencePhotos.new(@appearance).query
    # WHETHER ANYTHING HAS ACTUALLY LOOKED AT THESE PHOTOGRAPHS. Read off the rows
    # rather than off the credential, because the two answer different questions:
    # a key that landed this morning does not mean last week's gallery was ranked
    # by face, and the operator is looking at last week's gallery.
    @face_ranked = @search_rows.any?(&:face_scored?)
    @face_ranking_available = Appearances::FaceVisibility.available?
  end

  # THE MESSAGE THE UNCONFIGURED PATH PRINTS, and it names the env var on purpose.
  # The operator reading it is the person who will go and add the credential, so
  # "not configured" without the variable's name is a message that sends them to
  # ask someone.
  def unconfigured_message
    "No image-search provider is configured, so nothing was searched and nothing " \
      "was spent. Set #{Appearances::ImageSearch::Serper::API_KEY_ENV} to turn it on."
  end

  def search_message(summary)
    parts = ["#{summary.provider_name} returned #{summary.returned} result(s)"]
    parts << "#{summary.unparsed} in a shape we could not read" if summary.unparsed.positive?
    parts << "#{summary.unfetchable} refused as unsafe to fetch" if summary.unfetchable.positive?
    # NAMES WHAT DID THE ORDERING. "6 chosen" reads the same whether a vision
    # classifier ranked them or nothing did, and those are the two outcomes the
    # operator most needs to tell apart right after clicking.
    parts << if summary.ranked_by_face?
      "#{summary.scored} scored for face visibility"
    else
      "ranked on shape and relevance only (no face classifier)"
    end
    parts << "#{summary.chosen} chosen for the model"
    "#{parts.join(' · ')}."
  end
end
