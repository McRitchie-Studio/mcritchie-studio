# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [component] The kit page's sections, rendered alone from the same
# instance variables the controller sets: references (YAML and uploaded, with
# what a round sends), the upload form and its likeness guard, the palette,
# font, style and never rules, approved headers and open briefs.
class EmailBrandKitsViewTest < ActionView::TestCase
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    EmailBrandReference.delete_all
  end

  def render_kit(key = "turf-monster", limit: 4)
    @kit = EmailImages::BrandKit.find!(key)
    @references = @kit.references
    @generator_row = ImageGeneration::Registry.find("openai_image_header")
    @reference_limit = limit
    @sent = @kit.generator_references(limit: limit)
    @archived = EmailBrandReference.archived.where(brand_kit: key).to_a
    briefs = EmailImageBrief.where(brand_kit: key).ordered.to_a
    @approved_headers = briefs.filter_map { |b| (a = b.approved_artifact) && [b, a] }
    @open_briefs = briefs.reject { |b| b.approved_artifact_slug.present? }
    @reference = EmailBrandReference.new(brand_kit: key, role: "mascot")
    render template: "email_brand_kits/show"
  end

  test "the YAML references show large, with role, source path, and the WebP served as is" do
    render_kit

    assert_select "[data-test='reference'][data-origin='yaml']", 2
    assert_select "[data-test='reference'][data-role='mascot'] img[src='/agents/turf-monster.webp']"
    assert_select "[data-test='reference-source']", "public/agents/turf-monster.webp"
    assert_select "[data-test='reference-source']", "public/email_brand/turf-monster-style-anchor.jpg"
    assert_select "[data-test='reference'][data-sent='true']", 2
  end

  test "an uploaded reference shows its label, note and archive button, and whether a round sends it" do
    brand_reference(label: "Gator wave", note: "use this pose")
    brand_reference(label: "Spare", role: "other", created_at: 1.day.ago)
    render_kit(limit: 3)

    assert_select "[data-test='reference'][data-origin='upload']", 2
    assert_select "[data-test='reference'][data-origin='upload'][data-sent='true']", 1 do
      assert_select "[data-test='reference-note']", /use this pose/
      assert_select "[data-test='sent-badge']", "sent #3"
      assert_select "[data-test='archive-form']"
    end
    assert_select "[data-test='reference'][data-origin='upload'][data-sent='false']", /Spare/,
                  "at a limit of three the mascot upload outranks the other-role one"
  end

  test "the upload form takes an image, role, label and note, and carries the likeness guard" do
    render_kit

    assert_select "[data-test='reference-form'][enctype='multipart/form-data']" do
      assert_select "input[type='file'][name='email_brand_reference[file]'][accept='image/png,image/jpeg,image/webp']"
      assert_select "select[name='email_brand_reference[role]'] option", EmailBrandReference::ROLES.size
      assert_select "input[name='email_brand_reference[label]']"
      assert_select "textarea[name='email_brand_reference[note]']"
    end
    assert_select "[data-test='likeness-guard']", /No photos of real people or athletes, and no team logos/
  end

  test "the palette, font, style and never rules are shown" do
    render_kit

    assert_select "[data-test='kit-palette'] [data-test='swatch']", 4
    assert_select "[data-test='kit-palette']", /#2E7D32/
    assert_select "[data-test='kit-style']", /Montserrat/
    assert_select "[data-test='kit-style-text']", /gator mascot/
    assert_select "[data-test='kit-never']", /No real people/
  end

  test "approved headers show app, email, variant, approver and date; open briefs show state and rounds" do
    approved = turf_brief
    art = Artifact.create!(kind: "email_header", brief_slug: approved.slug, image_url: "https://assets.example.test/a.jpg")
    approved.approve!(art, by: "alex")
    open = turf_brief(variant: "existing_player", headline: "Welcome back", rounds_used: 2, build_state: "done")
    turf_brief(email_key: "other_brand_email", brand_kit: "mcritchie-studio")
    render_kit

    assert_select "[data-test='approved-header'][data-slug='#{approved.slug}']" do
      assert_select "img[src='https://assets.example.test/a.jpg'][alt=?]", "You're In!"
      assert_select "p", /turf-monster · drop_signup_confirmation · new_player/
      assert_select "p", /Approved by alex on #{Date.current.to_fs(:long)}/
    end
    assert_select "[data-test='open-brief']", 1
    assert_select "[data-test='open-brief'][data-slug='#{open.slug}']", /done.*rounds 2\/4/m
  end

  test "a brand with nothing approved and nothing open says so" do
    render_kit("mcritchie-industries")

    assert_select "[data-test='approved-headers']", /No header is approved/
    assert_select "[data-test='open-briefs']", /No open brief/
  end
end
