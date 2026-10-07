# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [component] The candidate grid and the email-shell preview, rendered alone.
class EmailImagesViewTest < ActionView::TestCase
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    @brief = turf_brief
    @a = Artifact.create!(kind: "email_header", brief_slug: @brief.slug, image_url: "https://assets.example.test/a.jpg",
                          generator: "openai_image_header", generator_version: "gpt-5-2025-08-07@v1", billable_units: 6_100)
    @b = Artifact.create!(kind: "email_header", brief_slug: @brief.slug, image_url: "https://assets.example.test/b.jpg",
                          generator: "openai_image_header", generator_version: "gpt-5-2025-08-07@v1",
                          billable_units: 6_300, retired_at: Time.current)
  end

  def render_grid(preview: nil)
    render partial: "email_images/candidates",
           locals: { brief: @brief.reload, candidates: @brief.candidates.to_a, preview_artifact: preview }
  end

  test "the grid shows every candidate with provenance and an unpriced token cost" do
    render_grid

    assert_select "[data-test='candidate']", 2
    assert_select "[data-test='candidate'][data-slug='#{@a.slug}'] [data-test='candidate-provenance']",
                  /gpt-5-2025-08-07@v1/
    assert_select "[data-test='candidate'][data-slug='#{@a.slug}'] [data-test='candidate-provenance']",
                  /6,100 tokens · unpriced/
    assert_select "[data-test='candidate'] img[alt=?]", "You're In!"
  end

  test "the approved candidate is badged and offers no approve button" do
    @brief.approve!(@a, by: "alex")
    render_grid(preview: @a)

    assert_select "[data-test='candidate'][data-state='approved'][data-slug='#{@a.slug}'] [data-test='approved-badge']"
    assert_select "[data-test='candidate'][data-slug='#{@a.slug}'] [data-test='approve-form']", 0
    assert_select "[data-test='candidate'][data-slug='#{@a.slug}']", /in preview/
  end

  test "a retired candidate stays on record and cannot be retired twice" do
    render_grid
    assert_select "[data-test='candidate'][data-state='retired'][data-slug='#{@b.slug}'] [data-test='retire-form']", 0
    assert_select "[data-test='candidate'][data-state='retired'][data-slug='#{@b.slug}'] [data-test='approve-form']", 1
  end

  test "no candidates says so" do
    render partial: "email_images/candidates", locals: { brief: @brief, candidates: [], preview_artifact: nil }
    assert_select "[data-test='no-candidates']"
  end

  test "the preview shell wraps the engine's branded_mailer with the flat header" do
    # ActionView::TestCase hands the test's instance variables to the view.
    @preview_artifact = @a
    @banner_url = @a.image_url
    @banner_alt = @brief.effective_alt_text
    render template: "email_images/preview", layout: "layouts/email_images/preview_shell"

    assert_select "body[data-test='email-shell']"
    assert_select "table[width='600'] img[src='https://assets.example.test/a.jpg'][alt=?]", "You're In!"
    assert_includes rendered, "drop signup confirmation new player"
  end
end
