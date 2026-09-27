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
      # THE SUMMARY CHOOSES THE FLASH KEY, because a blind face classifier is an
      # ALERT rather than a notice: the run "succeeded" -- candidates were filed and an
      # identity can be built from them -- so a green notice is exactly what let a
      # confidently wrong result read as a good one on 2026-09-26.
      redirect_to appearance_path, summary.flash_key => summary.sentence
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

  # BUY ONE GENERATED IMAGE, from ONE photograph, with no training step.
  #
  # THE OTHER PATH TO A PICTURE, and it does not touch #mint. #mint asks a vendor
  # to TRAIN an identity from a photo set and then pins generations to it; this
  # hands a zero-shot adapter a single headshot at generation time. They are
  # alternatives, not stages — a look needs no character model for this to work,
  # which is the entire point given four of six measured mints refused the photo
  # set outright.
  #
  # ADMIN-GATED BY `except: [:show]` ABOVE, like every other spending action here.
  def generate
    rescue_and_log(target: @appearance) { generate_artifact }
  rescue StandardError => e
    redirect_to appearance_path, alert: "Could not generate the image: #{e.message}"
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

  # THE GENERATION ITSELF, split out for the same reason #mint_identity is: the
  # two EXPECTED refusals are states of the record and of the machine, not
  # failures of ours, and an ErrorLog row for either is noise in the one place an
  # operator goes to find real ones. "No generator is configured" and "this person
  # has no headshot" both answer here. Everything else falls out and gets its row.
  def generate_artifact
    artifact = Appearances::GenerateArtifact.call(@appearance, number: params[:number].presence)
    redirect_to appearance_path, notice: generated_message(artifact)
  rescue Appearances::GenerateArtifact::NoGenerator,
         Appearances::GenerateArtifact::NoIdentityPhoto => e
    redirect_to appearance_path, alert: e.message
  end

  # NAMES WHAT MADE IT, in the flash as well as on the card. The operator is about
  # to judge a picture, and "which model produced this" is the first thing he needs
  # to know to judge it — especially while more than one generator is in play.
  #
  # THE UNIT IS PRINTED BESIDE THE COUNT because two generators count different
  # things: fal bills image units, OpenAI reports tokens. A bare number invites
  # comparing 3 with a four-figure token count — the measured sheets ran 6,724 to
  # 7,629 (config/image_generators.yml owns those figures).
  def generated_message(artifact)
    parts = ["#{artifact.generator_label} generated one character sheet"]
    parts << "seed #{artifact.seed}" if artifact.seed.present?
    parts << artifact.billing_summary if artifact.billing_summary.present?
    "#{parts.join(' · ')}. It is filed against this look below."
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
    set_generator
  end

  # WHAT THE OUTPUT PANEL NEEDS TO OFFER — OR TO REFUSE HONESTLY.
  #
  # TWO SEPARATE QUESTIONS, and collapsing them is what produces the useless
  # "generation is off". `@generator_row` is the row that WOULD serve, read
  # without regard to credentials, so the page can name the model; `@can_generate`
  # is whether it can run right now. Together they let the panel say
  # "GPT-5 image generation (Responses) is not configured, so nothing was generated
  # and nothing was spent. Set OPENAI_API_KEY to turn it on" instead of a shrug.
  #
  # ⚠ THAT EXAMPLE IS THE ONE THE PANEL CAN ACTUALLY PRINT, and it did not used to be.
  # It read "Ideogram V3 Character — set FAL_KEY to turn it on", which this path cannot
  # reach: `Appearances::GenerateArtifact::CAPABILITY` is `:character_sheet`, and
  # `openai_gpt5_sheet` is the ONLY row that claims it, so `preferred(:character_sheet)`
  # can return nothing else and the label and the env var were both wrong. The operator
  # most likely to read this comment is the one debugging "why is generation off", who
  # would then have gone looking for a fal credential the sheet path never asks for.
  # The literal string comes from `ImageGeneration::Registry::Row#unconfigured_message`,
  # so read that for the exact wording rather than trusting this paraphrase — and if
  # another row ever claims `character_sheet`, the example changes with the YAML order.
  #
  # `@identity_photo_url` IS READ EVEN WHEN GENERATION IS OFF, because "this
  # person has no headshot" is a fact about the record that an operator should see
  # before they go and buy a credential to discover it.
  def set_generator
    plan = Appearances::GenerateArtifact.new(@appearance)
    @generator_row = Appearances::GenerateArtifact.preferred_row
    @can_generate = Appearances::GenerateArtifact.available?
    @identity_photo_url = plan.identity_photo_url
  end

  # THE MESSAGE THE UNCONFIGURED PATH PRINTS, and it names the env var on purpose.
  # The operator reading it is the person who will go and add the credential, so
  # "not configured" without the variable's name is a message that sends them to
  # ask someone.
  def unconfigured_message
    "No image-search provider is configured, so nothing was searched and nothing " \
      "was spent. Set #{Appearances::ImageSearch::Serper::API_KEY_ENV} to turn it on."
  end
end
