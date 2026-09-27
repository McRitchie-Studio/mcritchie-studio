require "test_helper"

# [unit] THE GENERATOR REGISTRY — the operator's "data driven" decision, tested
# at the seam that makes it true.
#
# The property under test is NOT "the YAML parses". It is that a caller can pick
# a generator by CAPABILITY without naming a vendor, so swapping which model
# serves identity is an edit to config/image_generators.yml and nothing else.
#
# NOTHING HERE TOUCHES THE NETWORK. Every question below is answered from the
# YAML and from ENV; no row is ever constructed into a client.
class ImageGeneration::RegistryTest < ActiveSupport::TestCase
  setup { ImageGeneration::Registry.reload! }
  teardown { ImageGeneration::Registry.reload! }

  test "the shipped registry parses and every row declares what a caller needs" do
    rows = ImageGeneration::Registry.all

    assert_predicate rows, :any?, "config/image_generators.yml should register generators"
    rows.each do |row|
      assert row.key.present?, "every row needs a key"
      assert row.label.present?, "#{row.key} needs a human label for the provenance stamp"
      assert row.adapter.present?, "#{row.key} needs an adapter to speak its protocol"
      assert row.endpoint.present?, "#{row.key} needs a pinned endpoint"
      assert_predicate row.capabilities, :any?, "#{row.key} claims no capabilities, so nothing can choose it"
    end
  end

  # THE WHOLE POINT OF THE FILE. A caller asks for what it needs done.
  test "a caller picks a generator by capability, never by vendor name" do
    with_env("FAL_KEY" => "key-id:key-secret") do
      row = ImageGeneration::Registry.for(:zero_shot_identity)

      assert_not_nil row, "a configured zero-shot generator should serve"
      assert row.capable_of?(:zero_shot_identity)
    end
  end

  # nil IS A NORMAL ANSWER, exactly as in Appearances::ImageSearch: with no
  # credential the page must still render and say so, not raise.
  #
  # CLEARS EVERY DECLARED CREDENTIAL, NOT ONE BY NAME. This test used to clear
  # `FAL_KEY` alone and passed — until a SECOND row claimed the same capability,
  # at which point it was asserting "unconfigured" against a registry that was
  # still configured. Naming credentials one at a time is a list that goes stale
  # the moment a row is added, and it goes stale silently.
  test "an unconfigured capability answers nil rather than raising" do
    with_no_credentials do
      assert_nil ImageGeneration::Registry.for(:zero_shot_identity),
                 "no credential means no generator, and that is a state the page renders"
      assert_nil ImageGeneration::Registry.for(:character_sheet)
      assert_empty ImageGeneration::Registry.available
    end
  end

  # THE TWO QUESTIONS THE PAGE ASKS, and collapsing them is what produces the
  # useless "generation is off". `preferred` names the model even when it cannot run.
  test "the preferred row is readable even when its credential is absent" do
    with_no_credentials do
      row = ImageGeneration::Registry.preferred(:zero_shot_identity)

      assert_not_nil row, "the page must be able to name the generator that is switched off"
      assert_not row.available?
    end
  end

  test "the unconfigured message names the variable an operator must set" do
    with_no_credentials do
      row = ImageGeneration::Registry.preferred(:zero_shot_identity)

      assert_includes row.unconfigured_message, row.credential_env,
                      "the person reading this is the person who will go and set it"
      assert_includes row.unconfigured_message, "nothing was spent"
    end
  end

  # ⚠ THIS TEST USED TO ASSERT THE OVERCLAIM. It read "the first zero-shot row
  # claims full_body and back_view" — and it passed, because the row DID claim
  # them and neither had ever been measured. A test that asserts a capability list
  # matches itself proves nothing; what matters is that the capability a caller
  # asks for is only claimed by a row measured to deliver it.
  #
  # THE PORTRAIT RESULT AND THE SHEET RESULT COME APART, which is the whole reason
  # they are separate capabilities: flux-pulid holds a single portrait and returns
  # SIX DIFFERENT MEN on a grid.
  test "character_sheet is claimed only by a row measured to hold a sheet" do
    sheet_rows = ImageGeneration::Registry.with_capability(:character_sheet)

    assert_equal ["openai_gpt5_sheet"], sheet_rows.map(&:key),
                 "only the Responses path has been measured to hold a likeness across a sheet"

    portrait_only = ImageGeneration::Registry.with_capability(:single_portrait)
                                             .reject { |r| r.capable_of?(:character_sheet) }
    assert_predicate portrait_only, :any?, "the fal rows are portrait-only and must stay so"
    portrait_only.each do |row|
      assert_not row.capable_of?(:character_sheet),
                 "#{row.key} holds a portrait; that is not evidence it holds a set"
    end
  end

  # EVERY CAPABILITY A ROW CLAIMS MUST HAVE A MEASUREMENT BEHIND IT. This is the
  # rule the file exists to enforce, and the one that was broken on day one.
  test "no row claims a capability without recording what was measured" do
    unmeasured = ImageGeneration::Registry.all.reject { |row| row.measured_result.present? }

    assert_empty unmeasured.map(&:key),
                 "these rows claim capabilities with no `measured:` block — a claim the code " \
                 "will act on that nobody checked"
  end

  # THE RETIRED CAPABILITIES ARE GONE, not merely unused. Leaving them listed on a
  # row is what made a caller able to ask for them.
  test "the withdrawn overclaim capabilities are absent everywhere" do
    known = ImageGeneration::Registry.known_capabilities

    %w[full_body back_view expressions].each do |withdrawn|
      assert_not_includes known, withdrawn,
                          "#{withdrawn} was claimed without measurement and was withdrawn"
    end
  end

  # HIGGSFIELD IS A ROW, NOT A DELETED BRANCH — and it must not be routed the
  # identity work that its training step kept refusing.
  test "higgsfield stays registered and keeps the video job it is good at" do
    rows = ImageGeneration::Registry.all.select { |r| r.adapter == "higgsfield" }

    assert_predicate rows, :any?, "Higgsfield is kept as a row rather than removed"
    assert rows.none? { |r| r.capable_of?(:zero_shot_identity) },
           "Higgsfield TRAINS an identity; claiming zero-shot would route it work it refuses"
    assert rows.any? { |r| r.capable_of?(:image_to_video) },
           "Content::AssembleAgent still calls Kling image-to-video and it has never failed"
  end

  # THE STAMP THAT GOES ON EVERY ARTIFACT. Endpoint plus contract version,
  # because neither alone identifies what ran.
  test "the provenance version pins both the endpoint and the contract" do
    row = ImageGeneration::Registry.find!("fal_ideogram_character")

    assert_includes row.provenance_version, row.endpoint
    assert_includes row.provenance_version, row.api_version
  end

  # COST IS DERIVED FROM A MEASURED QUANTITY, not copied off a price page. The
  # rate below reproduces fal's published BALANCED price exactly: 3 units x $0.05
  # = $0.15, which is what they list per image at the API default.
  test "a measured unit count prices out at the declared rate" do
    row = ImageGeneration::Registry.find!("fal_ideogram_character")

    assert_equal BigDecimal("0.15"), row.price_for(3), "one image at the API default"
    # FIVE IMAGES, NOT "a five-pose sheet". This label described a retired model: poses
    # were deleted with the five-call-per-sheet design (there is no POSES constant any
    # more), and `fal_ideogram_character` claims no `character_sheet` capability at all,
    # so it cannot produce a sheet of any panel count. What 15 units actually is, at
    # this row's measured 3 units per image, is five separate single images.
    assert_equal BigDecimal("0.75"), row.price_for(15), "five single images at 3 units each"
  end

  # nil MEANS "WE CANNOT PRICE THIS", never "free" — and the page renders the
  # absence rather than a zero.
  test "an unpriceable call answers nil rather than zero" do
    row = ImageGeneration::Registry.find!("fal_ideogram_character")

    assert_nil row.price_for(nil), "a vendor that billed silently is not a free call"
    assert_nil ImageGeneration::Registry.find!("higgsfield_soul").price_for(3),
               "a row with no declared rate cannot price anything"
  end

  test "find! names the missing key instead of failing three frames later" do
    error = assert_raises(KeyError) { ImageGeneration::Registry.find!("no_such_generator") }

    assert_includes error.message, "no_such_generator"
  end

  private

  # CLEAR EVERY CREDENTIAL THE SHIPPED REGISTRY DECLARES — derived from the rows
  # rather than listed here, so a new generator is covered the day its row lands
  # instead of quietly un-testing the unconfigured path.
  def with_no_credentials(&block)
    names = ImageGeneration::Registry.all.filter_map(&:credential_env).uniq
    assert_predicate names, :any?, "no row declares a credential; this helper would clear nothing"
    with_env(names.index_with { nil }, &block)
  end

  # ENV is process-global; restore whatever was there, including absence.
  def with_env(pairs)
    original = pairs.keys.index_with { |k| ENV[k] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    ImageGeneration::Registry.reload!
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    ImageGeneration::Registry.reload!
  end
end
