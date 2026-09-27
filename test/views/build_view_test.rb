# frozen_string_literal: true

require "test_helper"

# [component] The /build views in isolation: the chat-style composer, and the
# request page's three states — register (signed out), claim a name (signed in,
# draft), and the status page once queued.
class BuildViewTest < ActionView::TestCase
  include ApplicationHelper

  def signed_in(user)
    view.define_singleton_method(:logged_in?) { !user.nil? }
    view.define_singleton_method(:current_user) { user }
  end

  test "signed out, the composer opens the sign-in modal instead of leaving the page" do
    signed_in(nil)
    @draft = nil
    @examples = []
    render template: "build/new"

    assert_select "[data-test='build-form'][x-data='buildComposer(false)']"
    assert_includes rendered, "Alpine.store('modals').open('auth'"
  end

  test "the gallery lists live examples under the prompt" do
    signed_in(nil)
    @draft = nil
    @examples = [ BuildGallery::Example.new(name: "Cyvasse", url: "https://cyvasse.mcritchie.studio", emoji: "🐉", blurb: "Hex strategy.") ]
    render template: "build/new"

    assert_select "[data-test='build-gallery'] h2", text: "Built with McRitchie Studio"
    assert_select "[data-test='build-example'][href='https://cyvasse.mcritchie.studio'][target='_blank']", text: /Cyvasse/
  end

  def example(name, image: nil)
    BuildGallery::Example.new(name: name, url: "https://#{name.parameterize}.mcritchie.studio", emoji: "🧱", blurb: "An app.", image: image)
  end

  test "the gallery is a sideways row, about 3.3 cards wide, with a scroll-aware edge fade and centered card text" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.jpg"), example("Rantly"), example("Weekly Lock") ]
    render template: "build/new"

    row = css_select("[data-test='build-gallery-row']").first
    assert_includes row["class"], "overflow-x-auto"
    assert_includes row["class"], "snap-x"
    assert_includes row["@scroll.passive"], "measure", "the fade follows the scroll position"
    assert_includes row[":style"], "mask-image"
    assert_select "[data-test='build-gallery-item'][class*='sm:basis-[calc((100%-3rem)/3.3)]']", 3
    assert_select "[data-test='build-example'] > span.text-center", 6, "the title, and the host and blurb, are centered on every card"
  end

  test "a card reads title, then screenshot, then host and a two-line description" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.jpg") ]
    render template: "build/new"

    card = css_select("[data-test='build-example']").first
    order = card.css("[data-test]").map { |node| node["data-test"] }
    assert_equal %w[build-example-name build-example-image build-example-host build-example-blurb], order

    blurb = card.at_css("[data-test='build-example-blurb']")["class"].split
    assert_includes blurb, "line-clamp-2"
    refute_includes blurb, "block", "block overrides line-clamp's display, so the text would run past two lines"
  end

  test "a card shows its screenshot when there is one, and its emoji when not" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.jpg"), example("Rantly") ]
    render template: "build/new"

    assert_select "[data-test='build-example-image'][src*='build_gallery/cyvasse']", 1
    assert_select "[data-test='build-example-image']", 1, "no image tag for an app without a screenshot"
  end

  test "See all apps is for admins only" do
    @draft = nil
    @examples = [ example("Cyvasse") ]

    signed_in(nil)
    render template: "build/new"
    assert_select "[data-test='build-gallery-all']", 0

    signed_in(users(:alex))
    render template: "build/new"
    assert_select "[data-test='build-gallery-all'][href*='status=all']", 1
  end

  test "no gallery at all when there is nothing live to show" do
    signed_in(nil)
    @draft = nil
    @examples = []
    render template: "build/new"

    assert_select "[data-test='build-gallery']", 0
  end

  test "the composer reuses its draft on a repeat Enter" do
    signed_in(nil)
    @draft = nil
    @examples = []
    render template: "build/new"

    assert_includes rendered, "this.draft.prompt === this.prompt.trim()"
  end

  test "the composer: a labelled prompt, Enter-to-send, a send button and examples" do
    signed_in(nil)
    @draft = nil
    @examples = []
    render template: "build/new"

    assert_select "[data-test='build-form'] textarea[name='app_request[prompt]'][maxlength='#{AppRequest::PROMPT_LIMIT}'][required]"
    assert_select "label.sr-only", text: "Describe your app"
    assert_select "[data-test='build-send'][aria-label='Send']"
    assert_includes rendered, "@keydown.enter", "Enter must send the prompt"
    assert_select "[data-test='build-examples'] button", 4
  end

  test "signed out, a draft opens the standard sign-in modal and echoes their prompt" do
    signed_in(nil)
    @app_request = AppRequest.create!(prompt: "A client portal")
    render template: "build/show"

    assert_select "[data-test='build-echo']", text: "A client portal"
    register = css_select("[data-test='build-register']").first
    assert_includes register["x-init"], "$store.modals.open('auth'", "sign-in is the modal, not an inline form"
    assert_includes register["x-init"], build_request_path(@app_request.token), "the emailed link must return to this draft"
    assert_select "[data-test='build-register'] form", 0, "no inline sign-in form"
    assert_select "[data-test='build-open-auth']", 1
    assert_select "[data-test='build-claim']", 0
  end

  test "the auth modal card: Google, an email field, and returnTo passed to the magic link" do
    render partial: "modals/auth"

    assert_select "[data-test='auth-modal'] form[action='/auth/google_oauth2']"
    assert_select "[data-test='auth-email-form'] input#auth-email[type='email']"
    assert_includes rendered, "window.postMagicLink(this.email, this.props.returnTo)"
  end

  test "signed in, a draft asks for a name on the parent domain" do
    signed_in(users(:alex))
    @app_request = AppRequest.create!(prompt: "A client portal", user: users(:alex))
    render template: "build/show"

    field = css_select("[data-test='build-claim'] input[data-test='build-subdomain']").first
    assert_nil field && field["maxlength"], "no maxlength: it would cut a pasted full address before clean() strips it"
    assert_select "[data-test='build-address-preview']", 1, "phones see the whole address under the field"
    assert field, "no name field"
    assert_nil field["placeholder"], "no static placeholder: the examples are typed into it"
    assert_equal "placeholderText", field[":placeholder"]
    assert_equal "onInput($el)", field["@input"], "input is cleaned as it is typed"
    assert_equal "focusWhenClear($el)", field["x-effect"], "focus lands once the modals close"
    assert_includes rendered, ".mcritchie.studio"
    AppRequest::EXAMPLE_NAMES.each { |example| assert_includes rendered, example }
    assert_includes rendered, ".slice(0, 3)", "three examples are sampled per visit"
    assert_includes rendered, "if (index === last) { this._typing = null; return }", "the motion stops on the third"
    assert_select "[data-test='build-register']", 0
  end

  test "queued, the page shows the reserved address and the first step done" do
    signed_in(users(:alex))
    @app_request = AppRequest.create!(prompt: "A client portal", user: users(:alex)).queue!("client-portal")
    render template: "build/show"

    assert_select "[data-test='build-host']", text: "client-portal.mcritchie.studio"
    assert_select "[data-test='build-steps'] [data-step='queued'][data-done='true']"
    assert_select "[data-test='build-steps'] [data-step='live'][data-done='false']"
  end
end
