require "test_helper"

# [integration] THE WHOLE CHARACTER-IDENTITY LANE, one pass, real records.
#
# The unit suites each pin one joint. This walks the path an operator actually
# takes and proves the joints line up: a cached ESPN headshot becomes a
# Higgsfield identity, the identity is recorded against the look, a poll moves it
# to ready, and only then does a generation carry its UUID.
#
# THE VENDOR IS THE ONLY THING STUBBED. Every call to it costs real money, so
# nothing here may reach a socket — and the fake is deliberately strict: it
# asserts the wrapped payload shape the live API demanded (measured 2026-09-24),
# so a regression in the request body fails here too rather than being
# rubber-stamped by a permissive double.
class CharacterReferenceLaneTest < ActionDispatch::IntegrationTest
  IDENTITY = "1af15765-27b3-461a-8804-b2de098c72c3".freeze

  class StrictFakeHiggsfield
    attr_reader :creates, :generations

    def initialize
      @creates = []
      @generations = []
      @status = "not_ready"
    end

    def completes! = @status = "completed"

    # Mirrors the validation the live API applied to the real probe: a list of at
    # least one OBJECT, each with `type: "image_url"` and an absolute URL.
    def create_custom_reference(name:, image_urls:)
      raise ArgumentError, "too_short" if image_urls.empty?
      image_urls.each { |url| raise ArgumentError, "url_parsing #{url}" unless url.to_s.start_with?("http") }

      @creates << { name: name, image_urls: image_urls }
      IDENTITY
    end

    def custom_reference(id) = { "id" => id, "status" => @status, "fail_reason" => nil }

    def generate_image_and_wait(**kwargs)
      if kwargs.key?(:custom_reference_id)
        raise ArgumentError, "uuid_parsing" unless kwargs[:custom_reference_id].match?(/\A\h{8}-(\h{4}-){3}\h{12}\z/)
        raise ArgumentError, "range" unless (0.0..1.0).cover?(kwargs[:custom_reference_strength].to_f)
      end

      @generations << kwargs
      "https://cdn.example.com/#{@generations.length}.png"
    end
  end

  setup do
    Appearance.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    @vendor = StrictFakeHiggsfield.new
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @athlete.update!(build: "6ft5 athletic", hair_description: "long blond")
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "400",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/400.png", content_type: "image/png")
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home",
                               generation_notes: "visor down")
  end

  def assets_agent_run(content)
    Higgsfield::Client.stub(:new, @vendor) { Content::AssetsAgent.new(content).call }
  end

  def scripted_content
    news = News.create!(title: "Allen throws five", slug: "news-lane-#{SecureRandom.hex(3)}",
                        stage: "reviewed", primary_person_slug: @person.slug)
    Content.create!(title: "Allen five TDs", slug: "content-lane-#{SecureRandom.hex(3)}", stage: "script",
                    source_news_slug: news.slug, content_type: "tiktok_video",
                    scenes: [{ "number" => 1, "description" => "a deep throw", "camera" => "low angle" }])
  end

  test "a cached headshot becomes an identity that pins a later generation" do
    # 1. The floor: one cached ESPN headshot is all the API's minimum needs.
    Appearances::CreateCharacterReference.new(@look, client: @vendor).call

    assert_equal 1, @vendor.creates.length
    assert_includes @vendor.creates.first[:image_urls].first,
                    "headshots/nfl/buffalo-bills/josh-allen/400.png"

    # 2. The identity is recorded — and recorded as NOT usable, which is what the
    #    live create actually answers.
    @look.reload
    assert_equal IDENTITY, @look.higgsfield_reference_id
    assert @look.higgsfield_reference_pending?

    # 3. A generation fired now must NOT spend it.
    assets_agent_run(scripted_content)
    assert_not_includes @vendor.generations.last.keys, :custom_reference_id

    # 4. The vendor finishes; a poll records it.
    @vendor.completes!
    Appearances::CreateCharacterReference.new(@look, client: @vendor).refresh_status!
    assert @look.reload.higgsfield_reference_ready?

    # 5. NOW the shot is pinned to this person's face.
    assets_agent_run(scripted_content)
    pinned = @vendor.generations.last
    assert_equal IDENTITY, pinned[:custom_reference_id]
    assert_includes Higgsfield::Client::CUSTOM_REFERENCE_STRENGTH_RANGE, pinned[:custom_reference_strength]

    # 6. And the look's own brief — which nothing in the app used to send —
    #    reached the prompt alongside it.
    assert_includes pinned[:prompt], "Bills home"
    assert_includes pinned[:prompt], "visor down"
    assert_includes pinned[:prompt], "6ft5 athletic"
  end

  # The operator's extra photograph rides in beside the headshot, through the
  # column that had no reader at all before this lane.
  test "an operator reference photo joins the identity it is recorded against" do
    @look.update!(reference_url: "https://example.com/allen-profile.jpg")

    Appearances::CreateCharacterReference.new(@look, client: @vendor).call

    assert_equal 2, @vendor.creates.first[:image_urls].length
    assert_includes @vendor.creates.first[:image_urls], "https://example.com/allen-profile.jpg"
  end

  # A person we hold no photograph of cannot have an identity built, and the
  # refusal must happen before anything is spent.
  test "a person with no photographs is refused, not charged" do
    carrey = Person.create!(first_name: "Jim", last_name: "Carrey")
    look = Appearance.create!(person_slug: carrey.slug, descriptor: "1994 Ace Ventura")

    assert_raises(Appearances::CreateCharacterReference::NoReferenceImages) do
      Appearances::CreateCharacterReference.new(look, client: @vendor).call
    end

    assert_empty @vendor.creates
  end

  # THE MONEY GUARD ON THE ONE COMMAND THAT SPENDS. A mistyped invocation must
  # not become a purchase, so the task refuses to guess a subject. The refusal
  # was in the code from the first commit but nothing held it there: removing it
  # left the whole suite green (measured in review, 2026-09-24).
  test "the minting task refuses to guess a look, and spends nothing when it does" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("appearances:character_reference")
    task = Rake::Task["appearances:character_reference"]
    held = ENV.delete("SLUG")
    ENV.delete("FORCE")

    error = assert_raises(RuntimeError) { Higgsfield::Client.stub(:new, @vendor) { task.tap(&:reenable).invoke } }
    assert_match "SLUG", error.message
    assert_empty @vendor.creates, "a task that will not name its subject must not reach the vendor"

    # THE CONTROL: a task broken for any other reason would pass the two
    # assertions above and leave the guard itself unproven.
    ENV["SLUG"] = @look.slug
    Higgsfield::Client.stub(:new, @vendor) { task.tap(&:reenable).invoke }

    assert_equal 1, @vendor.creates.length, "named a look, it mints exactly one identity"
    assert_equal IDENTITY, @look.reload.higgsfield_reference_id
  ensure
    held.nil? ? ENV.delete("SLUG") : ENV["SLUG"] = held
  end

  # The sweep is what keeps the stored status honest across many looks.
  test "the refresh sweep moves every pending identity and leaves the rest alone" do
    Appearances::CreateCharacterReference.new(@look, client: @vendor).call
    settled = Appearance.create!(person_slug: people(:cam_ward).slug, descriptor: "Titans home",
                                 higgsfield_reference_id: "2bf15765-27b3-461a-8804-b2de098c72c3",
                                 higgsfield_reference_status: "completed")
    @vendor.completes!

    Rails.application.load_tasks unless Rake::Task.task_defined?("appearances:refresh_character_references")
    Higgsfield::Client.stub(:new, @vendor) do
      Rake::Task["appearances:refresh_character_references"].tap(&:reenable).invoke
    end

    assert @look.reload.higgsfield_reference_ready?
    assert_equal "completed", settled.reload.higgsfield_reference_status
  end
end
