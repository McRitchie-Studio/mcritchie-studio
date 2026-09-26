# ONE LOOK'S CHARACTER MODEL — the photographs that went in, and what came out.
#
# NESTED UNDER THE PERSON because a look has no meaning without one: the URL
# `/people/drew-lock/models/look-abc123` reads as the sentence it is, and the
# person page links every look row straight here. A flat `/appearances/:slug`
# would have been shorter and would have made the operator's route to the page a
# URL they had to know.
#
# TWO OF THE THREE ACTIONS SPEND MONEY. #show is free — it reads rows and renders.
# #search buys one image-search query. #mint buys one character identity. Neither
# is reachable without a session (only #show is public, matching the person page
# beside it), and neither runs from a callback, a sweep or a page render.
class AppearancesController < ApplicationController
  skip_before_action :require_authentication, only: [:show]
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
  def mint
    id = Appearances::CreateCharacterReference.new(@appearance, references: Appearances::ReferenceSet).call
    redirect_to appearance_path,
                notice: "Character model #{id} requested from #{@appearance.reference_photo_count} " \
                        "photo(s). It is not usable until it reads ready — refresh to poll it."
  rescue Appearances::CreateCharacterReference::NoReferenceImages => e
    redirect_to appearance_path, alert: e.message
  rescue StandardError => e
    redirect_to appearance_path, alert: "Higgsfield refused the request: #{e.message}"
  end

  # ASK THE VENDOR WHERE THE IDENTITY GOT TO. A read — free — and the only thing
  # that stops the stored status being a permanent `not_ready`.
  def refresh
    status = Appearances::CreateCharacterReference.new(@appearance).refresh_status!
    if status.blank?
      redirect_to appearance_path, alert: "No character model to poll yet."
    else
      redirect_to appearance_path, notice: "Higgsfield says: #{status}."
    end
  rescue StandardError => e
    redirect_to appearance_path, alert: "Could not reach Higgsfield: #{e.message}"
  end

  private

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
    parts << "#{summary.chosen} chosen for the model"
    "#{parts.join(' · ')}."
  end
end
