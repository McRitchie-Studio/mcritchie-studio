require "test_helper"

# [unit] THE SHEET REQUEST CARRIES EACH REFERENCE WITH ITS ROLE, IN A FIXED ORDER:
# face, then uniform photos, then the body archetype. Nothing reaches a vendor (the
# adapter is a recorder, the upload and the URL guard are stubbed). Synthetic people.
class Appearances::GenerateArtifactRolesTest < ActiveSupport::TestCase
  STORED = "https://assets.example.test/character-sheets/x/y.png".freeze
  HEADSHOT_KEY = "headshots/nfl/comets/quill-arcwright/original.png".freeze

  setup do
    Appearance.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    ImageGeneration::Registry.reload!
    @person = Person.create!(first_name: "Quill", last_name: "Arcwright")
    @athlete = Athlete.create!(person_slug: @person.slug, sport: "football", position: "QB")
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "original", s3_key: HEADSHOT_KEY,
                       content_type: "image/png")
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Comets home", jersey_number: 23)
  end

  teardown { ImageGeneration::Registry.reload! }

  class Recorder
    class << self
      attr_accessor :calls
      def new(_row) = instance
      def instance = @instance ||= allocate
    end

    def generate_and_wait(**kwargs)
      self.class.calls << kwargs
      ImageGeneration::Result.new(image_urls: ["data:image/png;base64,QUJD"], seed: nil, request_id: "r",
                                  generator_key: "openai_gpt5_sheet", version: "v", billable_units: 7_000)
    end
  end

  def build
    Recorder.calls = []
    ImageGeneration::Adapter.stub(:for, Recorder) do
      Appearances::StoreGeneratedImage.stub(:call, STORED) do
        Appearances::FetchableUrl.stub(:ok_for?, true) do
          with_env("OPENAI_API_KEY", "sk-test") { Appearances::GenerateArtifact.call(@look.reload) }
        end
      end
    end
  end

  def choose_uniform(count)
    count.times do |i|
      @look.uniform_photos.create!(image_url: "https://img.example.test/u#{i}.jpg", chosen: true,
                                   chosen_at: Time.current + i)
    end
  end

  test "without uniform photos or an archetype image the build runs as before, plus the number" do
    artifact = build
    call = Recorder.calls.sole

    assert_includes call[:reference_urls].first, HEADSHOT_KEY
    assert_equal [], call[:supporting_reference_urls]
    assert_includes artifact.prompt, "jersey number 23"
    assert_not_includes artifact.prompt, "wearing his helmet"
    assert_includes artifact.prompt, "  - Image 1: IDENTITY ANCHOR"
    assert_not_includes artifact.prompt, "Image 2"
  end

  test "uniform photos then the archetype ride after the face, and the prompt numbers them so" do
    choose_uniform(2)
    body_archetypes(:nfl_qb_skill).update!(image_url: "https://assets.example.test/body-archetypes/qb.png")

    artifact = build
    call = Recorder.calls.sole

    assert_equal ["https://img.example.test/u0.jpg", "https://img.example.test/u1.jpg",
                  "https://assets.example.test/body-archetypes/qb.png"], call[:supporting_reference_urls],
                 "uniform photos in the order chosen, then the body build, last"
    assert_includes artifact.prompt, "  - Image 1: IDENTITY ANCHOR"
    assert_includes artifact.prompt, "  - Images 2-3: UNIFORM REFERENCE"
    assert_includes artifact.prompt, "  - Image 4: BODY BUILD REFERENCE"
    assert_includes artifact.prompt, "copy them EXACTLY from the UNIFORM REFERENCE images"
    assert_equal call[:prompt], artifact.prompt, "the stamped prompt is the one that was sent"
  end

  test "the numbering counts only the faces the row's arity sends" do
    @look.update!(reference_url: "https://example.com/second-face.png")
    choose_uniform(1)

    artifact = build

    assert_operator Recorder.calls.sole[:reference_urls].length, :>, 1, "more faces are OFFERED"
    assert_includes artifact.prompt, "  - Image 2: UNIFORM REFERENCE",
                    "the sheet row sends one face, so the uniform photo is image 2"
  end

  test "a request over the image limit is refused before anything is claimed or spent" do
    choose_uniform(3)
    body_archetypes(:nfl_qb_skill).update!(image_url: "https://assets.example.test/body-archetypes/qb.png")

    Appearances::GenerateArtifact.stub(:max_request_images, 4) do
      Appearances::FetchableUrl.stub(:ok_for?, true) do
        with_env("OPENAI_API_KEY", "sk-test") do
          error = assert_raises(Appearances::GenerateArtifact::TooManyReferences) do
            Appearances::SheetBuild.start!(@look.reload)
          end
          assert_match(/would send 5 reference images, over the 4/, error.message)
        end
      end
    end
    assert_nil @look.reload.sheet_build_state, "nothing was claimed"
  end
end
