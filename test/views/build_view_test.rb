# frozen_string_literal: true

require "test_helper"

# [component] The /build views in isolation: the opening composer (the first
# message to Xan, bot-shielded), the draft page (the chat with Xan and its
# checklist, the same signed in or out; an admin also gets the name step), the
# intake cards, and the status page once queued.
class BuildViewTest < ActionView::TestCase
  include ApplicationHelper

  def signed_in(user)
    view.define_singleton_method(:logged_in?) { !user.nil? }
    view.define_singleton_method(:current_user) { user }
  end

  test "the composer is the first message to Xan: a plain post, with the bot shield" do
    signed_in(nil)
    @draft = nil
    @examples = []
    render template: "build/new"

    assert_select "[data-test='build-form'][action='/build'][method='post']"
    assert_select "[data-test='build-form'] input[name='app_request[client_id]']"
    assert_select "[data-test='build-honeypot'][name='app_request[leave_blank]'][tabindex='-1']"
    proof = css_select("[data-test='build-proof']").first
    assert proof["data-proof"].present?, "the signed render time rides in a data attribute"
    assert_includes proof["x-init"], ".reverse()", "only the page's script writes it in, reversed"
    refute_includes rendered, "Alpine.store('modals').open('auth'", "sign-in waits for Build my app"
  end

  test "the gallery lists live examples under the prompt" do
    signed_in(nil)
    @draft = nil
    @examples = [ BuildGallery::Example.new(name: "Cyvasse", url: "https://cyvasse.mcritchie.studio", emoji: "🐉", blurb: "Hex strategy.") ]
    render template: "build/new"

    assert_select "[data-test='build-gallery'] h2", text: "Built with McRitchie Studio"
    assert_select "[data-test='build-example'][href='https://cyvasse.mcritchie.studio'][target='_blank']", text: /Cyvasse/
  end

  def example(name, image: nil, motion: nil, blurb: "An app.")
    BuildGallery::Example.new(name: name, url: "https://#{name.parameterize}.mcritchie.studio", emoji: "🧱", blurb: blurb,
                              image: image, motion: motion)
  end

  test "the gallery is a sideways row, about 3.3 cards wide, with a scroll-aware edge fade and centered card text" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.webp"), example("Rantly"), example("Weekly Lock") ]
    render template: "build/new"

    row = css_select("[data-test='build-gallery-row']").first
    assert_includes row["class"], "overflow-x-auto"
    assert_includes row["class"], "snap-x"
    assert_includes row["@scroll.passive"], "measure", "the fade follows the scroll position"
    assert_includes row[":style"], "mask-image"
    assert_select "[data-test='build-gallery-item'][class*='sm:basis-[calc((100%-3rem)/3.3)]']", 3
    assert_select "[data-test='build-example'] > span.text-center[data-test='build-example-body']", 3, "the card text is centered on every card"
  end

  test "a card reads image on top, then name, host and a one-line description" do
    signed_in(nil)
    @draft = nil
    long = "A long description that runs on well past what one line of a card can hold, " * 3
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.webp", motion: "build_gallery/cyvasse.mp4", blurb: long.strip) ]
    render template: "build/new"

    card = css_select("[data-test='build-example']").first
    order = card.css("[data-test]").map { |node| node["data-test"] }
    assert_equal %w[build-example-image build-example-motion build-example-body build-example-name build-example-host build-example-blurb], order,
                 "no title band above the image: the name sits in the bottom section"
    assert_equal "cyvasse.mcritchie.studio", card.at_css("[data-test='build-example-host']").text

    blurb = card.at_css("[data-test='build-example-blurb']")
    assert_includes blurb["class"].split, "truncate", "one line, ending in an ellipsis"
    refute_includes blurb["class"], "line-clamp"
    assert_equal long.strip, blurb["title"], "the whole description is still there on hover"
  end

  test "a card with a motion loop plays it on mouse hover or keyboard focus, never on touch or reduced motion" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.webp", motion: "build_gallery/cyvasse.mp4") ]
    render template: "build/new"

    video = css_select("[data-test='build-example-motion']").first
    assert video, "the loop rides over the still"
    assert_match %r{build_gallery/cyvasse.*\.mp4}, video["src"]
    assert_match %r{build_gallery/cyvasse.*\.webp}, video["poster"], "until it plays, the loop shows the still"
    %w[muted loop playsinline].each { |attr| assert video.key?(attr), "the loop is #{attr}" }
    assert_equal "none", video["preload"], "nothing downloads until someone hovers"
    assert_equal "true", video["aria-hidden"], "decoration: the still's alt text names the app"
    assert_includes video["class"].split, "motion-reduce:hidden", "reduced motion keeps the still"
    assert_includes video["class"].split, "opacity-0", "hidden until it is actually playing"
    assert_equal "playing = true", video["@playing"]

    card = css_select("[data-test='build-example']").first
    assert_equal "$event.pointerType === 'mouse' && play()", card["@pointerenter"], "a touch tap opens the app; it does not play"
    assert_includes card["@focus"], ":focus-visible", "keyboard focus plays it too"
    assert_equal "stop()", card["@pointerleave"]
    assert_equal "stop()", card["@blur"]
    assert_includes card["x-data"], "prefers-reduced-motion: reduce", "the script checks reduced motion as well as the CSS"
  end

  test "a card without a motion loop is a plain link with its still" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Rantly", image: "build_gallery/rantly.webp") ]
    render template: "build/new"

    assert_select "[data-test='build-example-image']", 1
    assert_select "[data-test='build-example-motion']", 0
    card = css_select("[data-test='build-example']").first
    assert_nil card["x-data"], "no hover script without a loop to play"
  end

  test "a card shows its screenshot when there is one, and its emoji when not" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.webp"), example("Rantly") ]
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

  test "the composer: a labelled prompt, Enter-to-send, a send button and examples" do
    signed_in(nil)
    @draft = nil
    @examples = []
    render template: "build/new"

    assert_select "[data-test='build-form'] textarea[name='app_request[prompt]'][maxlength='#{AppRequest::PROMPT_LIMIT}'][required]"
    assert_select "label.sr-only", text: "Tell Xan what you want to build"
    assert_select "[data-test='build-send'][aria-label='Send to Xan']"
    assert_includes rendered, "@keydown.enter", "Enter must send the prompt"
    assert_select "[data-test='build-examples'] button", 4
  end

  def chat_assigns(request_row)
    @app_request = request_row
    @messages = BuildIntake.history(request_row.token)
    @xan = nil
    view.define_singleton_method(:composer_locals) do |error: nil, text: ""|
      { url: "/build/#{request_row.token}/messages", scope: :build_chat, id: "build-chat-form", agent_name: "Xan", error: error, text: text }
    end
  end

  test "signed out, a draft is the chat with Xan and a checklist whose Build waits" do
    signed_in(nil)
    chat_assigns(AppRequest.create!(prompt: "A client portal"))
    render template: "build/show"

    assert_select "[data-test='build-chat-page'][data-build-chat-poll-url='/build/#{@app_request.token}/turns']"
    assert_select "[data-test='agent-chat-header'][data-agent-name='Xan']"
    assert_select "form#build-chat-form[action='/build/#{@app_request.token}/messages'] textarea[name='build_chat[text]']"
    %w[idea cto colors address].each { |step| assert_select "[data-test='build-check-#{step}'][data-done='false']" }
    assert_select "[data-test='build-my-app'][disabled][data-enabled='false']"
    assert_select "[data-test='build-claim']", 0, "no name step for a visitor"
    assert_select "[data-test='build-register']", 0, "no sign-in before Build"
  end

  test "a complete checklist lights Build: sign-in signed out, the claim form signed in" do
    palette = { "name" => "Pitch",
                "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
                "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }
    row = AppRequest.create!(prompt: "A client portal", answers: { "idea" => "A portal" }, cto_name: "Nova",
                             cto_avatar: "harbor", palette: palette, subdomain: "client-portal")
    signed_in(nil)
    chat_assigns(row)
    render template: "build/show"
    button = css_select("[data-test='build-my-app']").first
    assert_equal "true", button["data-enabled"]
    props = JSON.parse(button["data-build-sign-in"])
    assert_equal "/build/#{row.token}", props["returnTo"], "the sign-in modal's emailed link returns to this chat"
    assert_includes props["subtitle"], "client-portal.mcritchie.studio"
    assert_select "[data-test='build-check-cto-portrait'][src*='cto_portraits/harbor']"
    assert_select "[data-test='build-check-address-value']", text: "client-portal.mcritchie.studio"
  end

  test "the auth modal card: Google, an email field, and returnTo passed to the magic link" do
    render partial: "modals/auth"

    assert_select "[data-test='auth-modal'] form[action='/auth/google_oauth2']"
    assert_select "[data-test='auth-email-form'] input#auth-email[type='email']"
    assert_includes rendered, "window.postMagicLink(this.email, this.props.returnTo)"
  end

  test "an admin's draft also offers the name step, to queue a showcase without the checklist" do
    signed_in(users(:alex))
    chat_assigns(AppRequest.create!(prompt: "A client portal", user: users(:alex)))
    render template: "build/show"

    field = css_select("[data-test='build-claim'] input[data-test='build-subdomain']").first
    assert_nil field && field["maxlength"], "no maxlength: it would cut a pasted full address before clean() strips it"
    assert_select "[data-test='build-address-preview']", 1, "phones see the whole address under the field"
    assert field, "no name field"
    assert_nil field["placeholder"], "no static placeholder: the examples are typed into it"
    assert_equal "placeholderText", field[":placeholder"]
    assert_equal "onInput($el)", field["@input"], "input is cleaned as it is typed"
    assert_nil field["x-effect"], "the chat composer keeps the focus"
    assert_select "[data-test='build-admin-claim'] [data-test='build-claim']", 1
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
