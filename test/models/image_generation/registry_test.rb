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
  test "an unconfigured capability answers nil rather than raising" do
    with_env("FAL_KEY" => nil) do
      assert_nil ImageGeneration::Registry.for(:zero_shot_identity),
                 "no credential means no generator, and that is a state the page renders"
    end
  end

  # THE TWO QUESTIONS THE PAGE ASKS, and collapsing them is what produces the
  # useless "generation is off". `preferred` names the model even when it cannot run.
  test "the preferred row is readable even when its credential is absent" do
    with_env("FAL_KEY" => nil) do
      row = ImageGeneration::Registry.preferred(:zero_shot_identity)

      assert_not_nil row, "the page must be able to name the generator that is switched off"
      assert_not row.available?
    end
  end

  test "the unconfigured message names the variable an operator must set" do
    with_env("FAL_KEY" => nil) do
      row = ImageGeneration::Registry.preferred(:zero_shot_identity)

      assert_includes row.unconfigured_message, row.credential_env,
                      "the person reading this is the person who will go and set it"
      assert_includes row.unconfigured_message, "nothing was spent"
    end
  end

  # ORDER IS THE PREFERENCE. The file leads with the row that claims full_body,
  # because a face-only adapter cannot answer the question the sheet is for.
  test "the first zero-shot row claims the capabilities a character sheet needs" do
    first = ImageGeneration::Registry.with_capability(:zero_shot_identity).first

    assert first.capable_of?(:full_body),
           "the leading identity generator must be able to do more than portraits"
    assert first.capable_of?(:back_view)
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
    assert_equal BigDecimal("0.75"), row.price_for(15), "a five-pose sheet"
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
