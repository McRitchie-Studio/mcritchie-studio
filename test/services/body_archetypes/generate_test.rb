require "test_helper"

# [unit] AN ARCHETYPE IMAGE IS ONE PAID IMAGE, BOUGHT ONLY ON A CLICK. Nothing here
# reaches a vendor: the adapter is a recorder and the upload is stubbed.
class BodyArchetypes::GenerateTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  STORED = "https://assets.example.test/body-archetypes/nfl-lineman/x.png".freeze

  setup do
    ImageGeneration::Registry.reload!
    @archetype = body_archetypes(:nfl_lineman)
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
                                  generator_key: "openai_gpt5_sheet", version: "v", billable_units: 5_000)
    end
  end

  def with_recorder(&block)
    Recorder.calls = []
    ImageGeneration::Adapter.stub(:for, Recorder) do
      Appearances::StoreGeneratedImage.stub(:call, STORED) do
        with_env("OPENAI_API_KEY", "sk-test", &block)
      end
    end
  end

  test "the prompt asks for a faceless, unbranded front-and-back body in practice gear" do
    prompt = BodyArchetypes::Generate.prompt_for(@archetype)

    assert_includes prompt, @archetype.description
    assert_includes prompt, "LEFT facing the camera, RIGHT facing away showing his back"
    assert_includes prompt, "plain padded football practice gear"
    assert_includes prompt, "NO face detail"
    assert_includes prompt, "NO team marks"
    assert_includes prompt, "neutral grey seamless studio background"
    assert_includes prompt, "team-photo-day lighting"
  end

  test "one call, text only, and the row records the stored image" do
    with_recorder { BodyArchetypes::Generate.new(@archetype).call }

    call = Recorder.calls.sole
    assert_equal [], call[:reference_urls]
    assert call[:text_only], "an archetype has no face to show the model"
    @archetype.reload
    assert_equal STORED, @archetype.image_url
    assert_equal 5_000, @archetype.billable_units
    assert_includes @archetype.image_prompt, "NO face detail"
  end

  test "start claims the row and enqueues, and a second press is refused without spending" do
    with_env("OPENAI_API_KEY", "sk-test") do
      assert_enqueued_jobs 1, only: BodyArchetypeGenerateJob do
        BodyArchetypes::Generate.start!(@archetype)
      end
      assert @archetype.reload.building?
      assert_raises(BodyArchetypes::Generate::Refused) { BodyArchetypes::Generate.start!(@archetype) }
    end
  end

  test "no credential refuses before claiming anything" do
    with_env("OPENAI_API_KEY", nil) do
      assert_raises(BodyArchetypes::Generate::Refused) { BodyArchetypes::Generate.start!(@archetype) }
    end
    assert_nil @archetype.reload.generation_state
  end

  test "the job's run spends once, and a re-run of the same claim spends nothing" do
    started = nil
    with_env("OPENAI_API_KEY", "sk-test") { started = BodyArchetypes::Generate.claim!(@archetype) }

    with_recorder do
      BodyArchetypes::Generate.run(@archetype, started_at: started)
      BodyArchetypes::Generate.run(@archetype, started_at: started)
    end

    assert_equal 1, Recorder.calls.length
    assert_equal BodyArchetype::DONE, @archetype.reload.generation_state
  end

  # THE STALE WINDOW COUNTS FROM WHEN THE PAID CALL STARTS (Carl): a job that sat in
  # the queue past STALE_AFTER must not be reclaimable while it spends.
  test "the run restamps the claim with now, not with the enqueue time" do
    started = nil
    with_env("OPENAI_API_KEY", "sk-test") { started = BodyArchetypes::Generate.claim!(@archetype) }
    seen = nil
    second_press = nil

    travel(BodyArchetype::STALE_AFTER + 5.minutes) do
      Recorder.calls = []
      spy = Recorder.instance
      archetype = @archetype
      spy.define_singleton_method(:generate_and_wait) do |**kwargs|
        seen = archetype.reload.generation_started_at
        second_press = begin
          BodyArchetypes::Generate.claim!(archetype)
          :claimed
        rescue BodyArchetypes::Generate::Refused
          :refused
        end
        Recorder.calls << kwargs
        ImageGeneration::Result.new(image_urls: ["data:image/png;base64,QUJD"], seed: nil, request_id: "r",
                                    generator_key: "openai_gpt5_sheet", version: "v", billable_units: 1)
      end
      ImageGeneration::Adapter.stub(:for, Recorder) do
        Appearances::StoreGeneratedImage.stub(:call, STORED) do
          with_env("OPENAI_API_KEY", "sk-test") { BodyArchetypes::Generate.run(@archetype, started_at: started) }
        end
      end
      assert_in_delta Time.current, seen, 1.second, "the claim is restamped at the take"
      assert_equal :refused, second_press, "a press during the paid call is refused, not taken as stale"
    end
    assert_equal BodyArchetype::DONE, @archetype.reload.generation_state
  ensure
    Recorder.instance.singleton_class.send(:remove_method, :generate_and_wait) if
      Recorder.instance.singleton_methods.include?(:generate_and_wait)
  end
end
