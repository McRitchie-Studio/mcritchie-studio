require "test_helper"

# [integration] THE WORKED EXAMPLE IN A COMMENT IS THE ONE THE PAGE ACTUALLY PRINTS.
#
# WHY THIS IS AN INTEGRATION TEST AND NOT A UNIT ONE. The defect it pins spanned three
# layers and was invisible inside any one of them: a YAML row declares the capability, a
# module picks a row by capability, a controller reads that row, and a partial renders
# the row's refusal. `AppearancesController#set_generator` documented the panel saying
# "Ideogram V3 Character — set FAL_KEY to turn it on", and every layer was individually
# correct while that sentence was unreachable — `GenerateArtifact::CAPABILITY` is
# `:character_sheet`, no fal row claims it, so the panel could only ever name GPT-5 and
# OPENAI_API_KEY. Wrong generator AND wrong env var, in the example an operator debugging
# "why is generation off" reads first. Only a test that walks YAML → Registry → controller
# → rendered page can catch a comment that is false about the composition.
#
# This pins the BEHAVIOUR the prose describes, so the two cannot drift apart: if a
# second row ever claims `character_sheet` and wins the order, the assertions below change
# and whoever changes them has to revisit the comment.
#
# NOTHING HERE TOUCHES THE NETWORK. The unconfigured path is the whole subject, so there
# is no credential and nothing to spend; the suite-wide OPENAI_NO_LIVE_CALLS trap is the
# backstop.
class GeneratorWorkedExampleTest < ActionDispatch::IntegrationTest
  # The ops pages sit behind the admin wall (AdminWall); these tests read them as
  # the operator. A test about another viewer signs that session in itself.
  setup { log_in_as(users(:alex)) }

  CAPABILITY = Appearances::GenerateArtifact::CAPABILITY
  SHEET_ROW = "openai_gpt5_sheet".freeze

  setup do
    Appearance.delete_all
    ImageCache.where(purpose: "headshot").delete_all
    ImageGeneration::Registry.reload!
    @person = people(:josh_allen)
    @athlete = athletes(:allen_athlete)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
    ImageCache.create!(owner: @athlete, purpose: "headshot", variant: "original",
                       s3_key: "headshots/nfl/buffalo-bills/josh-allen/original.png",
                       content_type: "image/png")
  end

  teardown { ImageGeneration::Registry.reload! }

  def look_path = person_appearance_path(@person.slug, @look.slug)

  # `with_env` pins ONE key (test_helper.rb), so both credentials are cleared by nesting.
  # Both, not just OPENAI_API_KEY: a FAL_KEY on the machine turns the fal rows on, and
  # the panel's copy is then about a different row than the one under test.
  def without_credentials(&block)
    with_env("OPENAI_API_KEY", nil) { with_env("FAL_KEY", nil, &block) }
  end

  # ── The premise the comment rests on ───────────────────────────────────────────
  #
  # FROM THE REAL YAML ON DISK, not a built row. The whole defect was a claim about what
  # the shipped file resolves to, so a hand-built row would assert nothing about it.
  test "exactly one shipped row claims the sheet capability, so preferred cannot vary" do
    claimants = ImageGeneration::Registry.with_capability(CAPABILITY).map(&:key)

    assert_equal [SHEET_ROW], claimants,
                 "the controller's worked example names the row `preferred(#{CAPABILITY})` " \
                 "returns. While exactly one row claims it, that row is fixed and the example " \
                 "is checkable. If you are adding a second claimant, the comment in " \
                 "AppearancesController#set_generator needs rewriting in the same commit."
  end

  test "no fal row claims the sheet capability, which is why FAL_KEY was the wrong var" do
    fal_rows = ImageGeneration::Registry.all.select { |row| row.adapter == "fal" }

    refute_empty fal_rows, "with no fal rows loaded this case proves nothing"
    fal_rows.each do |row|
      assert_not row.capable_of?(CAPABILITY),
                 "#{row.key} claims #{CAPABILITY}; the old worked example would become " \
                 "reachable and this guard's reasoning would need redoing"
    end
  end

  # ── What the row actually says when it is switched off ─────────────────────────
  test "the preferred sheet row names OPENAI_API_KEY and never FAL_KEY" do
    row = Appearances::GenerateArtifact.preferred_row

    assert_equal SHEET_ROW, row.key
    assert_equal "OPENAI_API_KEY", row.credential_env
    assert_includes row.unconfigured_message, "OPENAI_API_KEY"
    assert_includes row.unconfigured_message, "GPT-5"
    assert_not_includes row.unconfigured_message, "FAL_KEY"
    assert_not_includes row.unconfigured_message, "Ideogram"
  end

  # THE TIE BETWEEN THE COMMENT AND THE CODE. The comment quotes the sentence; this
  # asserts the code produces that sentence. Either one drifting breaks this.
  test "the sentence quoted in the controller comment is the sentence the row produces" do
    quoted = Rails.root.join("app/controllers/appearances_controller.rb")
                  .read[/"(GPT-5 image generation \(Responses\) is not configured[^"]*?)"/m, 1]
                  .to_s
                  .gsub(/\s*#\s*/, " ")
                  .gsub(/\s+/, " ")
                  .strip

    refute_empty quoted,
                 "the controller comment no longer quotes a worked example starting " \
                 "\"GPT-5 image generation (Responses) is not configured\" — if the wording " \
                 "moved, move this pin with it rather than deleting it"
    assert_equal Appearances::GenerateArtifact.preferred_row.unconfigured_message,
                 quoted,
                 "the worked example in AppearancesController#set_generator is not what " \
                 "ImageGeneration::Registry::Row#unconfigured_message actually returns"
  end

  # ── Through the route, with no credential ──────────────────────────────────────
  #
  # THE PAGE IS PUBLIC TO READ, so no session is needed to see the refusal — which is the
  # state an operator debugging "why is generation off" is looking at.
  test "the look page with no credential names OPENAI_API_KEY to the operator" do
    without_credentials do
      ImageGeneration::Registry.reload!

      assert_not Appearances::GenerateArtifact.available?,
                 "this case needs generation to be OFF; a credential leaked into the env"

      get look_path

      assert_response :success
      assert_includes response.body, "OPENAI_API_KEY",
                      "the panel must name the variable the reader will go and set"
      assert_not_includes response.body, "FAL_KEY",
                          "naming FAL_KEY sends the operator after a credential the sheet " \
                          "path never asks for"
    end
  end

  # AND THE ROW IS STILL NAMED WHEN IT IS OFF, which is the distinction
  # `set_generator`'s comment exists to draw: @generator_row is read without regard to
  # credentials so the page says WHICH generator is off, not merely that one is.
  test "the page names the generator even though it cannot run" do
    without_credentials do
      ImageGeneration::Registry.reload!

      get look_path

      assert_response :success
      assert_includes response.body, "GPT-5 image generation",
                      "collapsing the two questions is what produces the useless " \
                      "'generation is off' the comment warns about"
    end
  end
end
