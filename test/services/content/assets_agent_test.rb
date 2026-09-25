require "test_helper"

# [unit] THE PROMPT PATH — the only place in the app that asks Higgsfield for an
# image, and therefore the only place a character identity can be spent.
#
# Two things are proved here:
#
#   1. Appearance#generation_brief reaches the prompt. It had ZERO callers
#      anywhere in the app before this (measured 2026-09-24), while the prompt
#      built its own inferior copy of the same sentence from the Athlete record
#      alone — so the richer brief, which also carries the look's descriptor and
#      the operator's generation notes, was never sent to anyone.
#   2. A generation is pinned to the person's identity when, and only when, that
#      identity is ready.
#
# The client is replaced wholesale. Every call to the real one costs money.
class Content::AssetsAgentTest < ActiveSupport::TestCase
  # Records the keyword arguments a generation was asked for. Returns a URL so
  # the run completes.
  class FakeClient
    attr_reader :generations

    def initialize = @generations = []

    def generate_image_and_wait(**kwargs)
      @generations << kwargs
      "https://cdn.example.com/#{@generations.length}.png"
    end
  end

  setup do
    Appearance.delete_all
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @athlete.update!(build: "6ft5 athletic", skin_tone: "light", hair_description: "long blond")
    @news = News.create!(title: "Allen throws five", slug: "news-assets-1", stage: "reviewed",
                         primary_person_slug: @person.slug)
    @content = Content.create!(title: "Allen five TDs", slug: "content-assets-1", stage: "script",
                               source_news_slug: @news.slug, content_type: "tiktok_video",
                               scenes: [{ "number" => 1, "description" => "a deep throw", "camera" => "low angle" }])
    @client = FakeClient.new
  end

  def agent
    Higgsfield::Client.stub(:new, @client) { Content::AssetsAgent.new(@content) }
  end

  def prompt_for(agent_instance)
    agent_instance.send(:build_image_prompt, @content.scenes.first)
  end

  # --- the brief reaches the prompt ---------------------------------------

  test "the recorded look's brief reaches the prompt" do
    Appearance.create!(person_slug: @person.slug, descriptor: "Bills white away",
                       generation_notes: "visor down, sleeves cut")

    prompt = prompt_for(agent)

    assert_includes prompt, "Bills white away", "the descriptor is the part only the LOOK knows"
    assert_includes prompt, "visor down, sleeves cut", "the operator's notes were never sent before"
    assert_includes prompt, "6ft5 athletic", "the athlete fold must survive the move"
  end

  # A person with an Athlete record but no look on file is the ORDINARY state —
  # a look is filed only when someone attaches an image or names a colorway — so
  # dropping to nothing there would have deleted a description the prompt carries
  # today.
  test "a person with no look on file still gets their athlete description" do
    assert_nil @person.reload.default_appearance, "the control — no look, or this proves nothing"

    prompt = prompt_for(agent)

    assert_includes prompt, "6ft5 athletic"
    assert_includes prompt, "long blond"
  end

  # Neither Jim Carrey nor George Bush has an Athlete record, so the old
  # athlete-only block produced nothing at all for a cast member like them.
  test "someone with no athlete record is describable at last" do
    carrey = Person.create!(first_name: "Jim", last_name: "Carrey")
    Appearance.create!(person_slug: carrey.slug, descriptor: "1994 Ace Ventura",
                       generation_notes: "Hawaiian shirt, swept-up hair")
    @news.update!(primary_person_slug: carrey.slug)

    prompt = prompt_for(agent)

    assert_includes prompt, "1994 Ace Ventura"
    assert_includes prompt, "Hawaiian shirt"
  end

  test "a content with no subject still builds a prompt" do
    @news.update!(primary_person_slug: nil)

    assert_includes prompt_for(agent), "Cinematic sports photograph"
  end

  # --- pinning the identity ------------------------------------------------

  test "a ready identity pins every shot in the run" do
    Appearance.create!(person_slug: @person.slug, descriptor: "Bills home",
                       higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                       higgsfield_reference_status: "completed")

    agent.call

    assert_equal 1, @client.generations.length
    assert_equal "1af15765-27b3-461a-8804-b2de098c72c3",
                 @client.generations.first[:custom_reference_id]
    assert_equal Content::AssetsAgent::CHARACTER_REFERENCE_STRENGTH,
                 @client.generations.first[:custom_reference_strength]
  end

  # An identity is minted `not_ready` and takes about a minute to reach
  # `completed`. A shot fired in between would name a face nobody waited for.
  test "an identity still training is not spent" do
    %w[not_ready queued in_progress].each do |state|
      Appearance.delete_all
      # The run advances the content out of `script`, so each pass starts it over.
      @content.update!(stage: "script")
      Appearance.create!(person_slug: @person.slug, descriptor: "Bills home",
                         higgsfield_reference_id: "1af15765-27b3-461a-8804-b2de098c72c3",
                         higgsfield_reference_status: state)
      client = FakeClient.new
      Higgsfield::Client.stub(:new, client) { Content::AssetsAgent.new(@content).call }

      assert_not_includes client.generations.first.keys, :custom_reference_id,
                          "#{state} must not pin a generation"
    end
  end

  # Absent is not null: an unpinned generation must send neither key, so the
  # caller splats an empty hash rather than passing nils through.
  test "a person with no identity sends neither key" do
    Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")

    agent.call

    assert_not_includes @client.generations.first.keys, :custom_reference_id
    assert_not_includes @client.generations.first.keys, :custom_reference_strength
  end

  # The value is the API's, not ours: measured 2026-09-24, anything outside
  # 0.0..1.0 answers 422 (le 1.0 / ge 0.0).
  test "the strength we ship is one the API accepts" do
    assert_includes Higgsfield::Client::CUSTOM_REFERENCE_STRENGTH_RANGE,
                    Content::AssetsAgent::CHARACTER_REFERENCE_STRENGTH
  end
end
