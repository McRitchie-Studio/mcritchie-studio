# frozen_string_literal: true

require "test_helper"

# [component] The /build views in isolation: the agent shell (Ray's portrait,
# the heading or the status card, the thread, the chat box), the opening
# composer (the first message to Ray, bot-shielded, answered in place), the
# draft page (the same shell, signed in or out; an admin also gets the name
# step), and the status page once queued.
class BuildViewTest < ActionView::TestCase
  include ApplicationHelper

  def signed_in(user)
    view.define_singleton_method(:logged_in?) { !user.nil? }
    view.define_singleton_method(:current_user) { user }
  end

  test "the composer is the first message to Ray: a Turbo post answered in place, with the bot shield" do
    signed_in(nil)
    @examples = []
    render template: "build/new"

    assert_select "#build-chat-page form#build-first-form[data-test='build-form'][action='/build'][method='post']"
    assert_select "[data-test='build-form'][data-turbo='false']", 0, "Turbo posts it, so the answer streams into this page"
    assert_select "[data-test='build-form'] input[name='app_request[client_id]']"
    assert_select "[data-test='build-honeypot'][name='app_request[leave_blank]'][tabindex='-1']"
    proof = css_select("[data-test='build-proof']").first
    assert proof["data-proof"].present?, "the signed render time rides in a data attribute"
    assert proof.attributes.key?("data-build-proof"), "only the page's script writes it in, reversed, at send (build_shell.js)"
    assert_nil proof["value"], "the server never fills it"
    assert_select "[data-test='build-form'] [x-data], [data-test='build-form'][x-data]", 0, "no inline Alpine: the behaviour is build_shell.js"
    assert_select "[data-test='build-send'][disabled]", 1, "send waits for text"
    refute_includes rendered, "Alpine.store('modals').open('auth'", "sign-in waits for Build my app"
  end

  test "the gallery lists live examples under the prompt" do
    signed_in(nil)
    @draft = nil
    @examples = [ BuildGallery::Example.new(name: "Cyvasse", url: "https://cyvasse.xyz", emoji: "🐉", blurb: "Hex strategy.") ]
    render template: "build/new"

    assert_select "[data-test='build-gallery'] h2", text: "Built with McRitchie Studio"
    assert_select "[data-test='build-example'][href='https://cyvasse.xyz'][target='_blank']", text: /Cyvasse/
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
    # The row scrolls sideways, so its overflow clips anything drawn outside a
    # card: the focus ring is drawn inside instead.
    ring = css_select("[data-test='build-example']").first["class"].split
    assert_includes ring, "focus-visible:-outline-offset-2"
    refute_includes ring, "focus-visible:outline-offset-2"
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

    # Alex 2026-10-18: the domain smaller, the description much smaller, the
    # name kept at body size so it still leads.
    name = card.at_css("[data-test='build-example-name']")["class"].split
    refute(name.any? { |c| c.start_with?("text-") && c =~ /text-(xs|sm|\[)/ }, "the name keeps its size")
    host = card.at_css("[data-test='build-example-host']")["class"].split
    assert_includes host, "text-2xs", "the domain is smaller than text-xs (text-2xs is 11px)"
    refute_includes host, "text-xs"
    assert_includes host, "truncate"

    blurb = card.at_css("[data-test='build-example-blurb']")
    assert_includes blurb["class"].split, "text-2xs", "the description is much smaller than text-sm"
    assert_includes blurb["class"].split, "text-muted", "and quieter than the name"
    refute_includes blurb["class"].split, "text-sm"
    assert_includes blurb["class"].split, "truncate", "one line, ending in an ellipsis"
    refute_includes blurb["class"], "line-clamp"
    assert_equal long.strip, blurb["title"], "the whole description is still there on hover"
  end

  test "a card with a motion loop carries a silent, lazy, reduced-motion-safe video over its still" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Cyvasse", image: "build_gallery/cyvasse.webp", motion: "build_gallery/cyvasse.mp4") ]
    render template: "build/new"

    video = css_select("[data-test='build-example-motion']").first
    assert video, "the loop rides over the still"
    assert_match %r{build_gallery/cyvasse.*\.mp4}, video["src"]
    assert_nil video["poster"], "no poster: it would fetch the still eagerly; the lazy still under the video shows until it plays"
    assert_equal "lazy", css_select("[data-test='build-example-image']").first["loading"]
    %w[muted loop playsinline].each { |attr| assert video.key?(attr), "the loop is #{attr}" }
    assert_equal "none", video["preload"], "nothing downloads until someone hovers"
    assert_equal "true", video["aria-hidden"], "decoration: the still's alt text names the app"
    assert_includes video["class"].split, "motion-reduce:hidden", "reduced motion keeps the still"
    assert_includes video["class"].split, "opacity-0", "hidden until it is actually playing"
    assert_includes video["class"].split, "data-[playing]:opacity-100", "app/javascript/gallery_motion.js marks it playing"
    assert video.key?("data-gallery-motion-video")

    card = css_select("[data-test='build-example']").first
    assert card.key?("data-gallery-motion"), "the card opts in to app/javascript/gallery_motion.js"
    assert_nil card["x-data"], "behaviour lives in app/javascript, not the template"
  end

  test "a card without a motion loop is a plain link with its still" do
    signed_in(nil)
    @draft = nil
    @examples = [ example("Rantly", image: "build_gallery/rantly.webp") ]
    render template: "build/new"

    assert_select "[data-test='build-example-image']", 1
    assert_select "[data-test='build-example-motion']", 0
    card = css_select("[data-test='build-example']").first
    refute card.key?("data-gallery-motion"), "no hover script without a loop to play"
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

  test "the composer: a labelled prompt, Enter-to-send, a round send button and a placeholder that types example ideas" do
    signed_in(nil)
    @examples = []
    render template: "build/new"

    box = css_select("[data-test='build-form'] textarea[name='app_request[prompt]'][maxlength='#{AppRequest::PROMPT_LIMIT}'][required]").sole
    assert_select "label.sr-only", text: "Tell Ray what you want to build"
    assert_select "[data-test='build-send'][aria-label='Send to Ray'].rounded-full"
    assert box.attributes.key?("data-build-first-input"), "Enter sends through build_shell.js"
    examples = JSON.parse(box["data-typing-placeholder"])
    assert_equal 4, examples.size, "the examples are typed into the placeholder (app/javascript/typing_placeholder.js)"
    assert_equal examples.first, box["placeholder"], "still, the first example reads (no script, or reduced motion)"
    assert_select "[data-test='build-examples']", 0, "no example chips"
    assert_select "[data-test='build-form'] p.sr-only[role='status'][aria-live='polite'][data-composer-status]", 1,
                  "the icon-only send has a status line a screen reader hears as Sending (build_shell.js)"
  end

  test "/build is the agent shell: Ray's portrait, the heading, then the chat box; no banner, no chips, no three steps" do
    signed_in(users(:viewer))
    AppRequest.create!(prompt: "An unfinished idea", user: users(:viewer))
    @intake_agent = nil
    @examples = []
    render template: "build/new"

    assert_select "[data-test='agent-shell'][data-shell='build']" do
      assert_select "[data-test='agent-chat-header'][data-agent-name='Ray'] [data-test='agent-portrait'][style*='view-transition-name: agent-portrait']"
      assert_select "#build-checklist[data-card='false'] [data-test='build-heading']" do
        assert_select "h1", text: "What do you want to build?"
        assert_select "p", text: "Let our agents build & host your website on the McRitchie Studio stack, free."
      end
      assert_select "[data-test='agent-shell-status'] + [data-test='agent-shell-chat'] > #build-chat-page [data-test='build-form']", 1, "the chat box sits under the heading"
    end
    assert_select "[data-test='resume-draft']", 0, "no unfinished-request banner"
    assert_select "[aria-label='How it works']", 0, "no three-step cards"
    assert_no_match(/Pick up where you left off|Tell Xan/, rendered)
  end

  def chat_assigns(request_row, started: request_row.intake_started?)
    @app_request = request_row
    @messages = BuildIntake.history(request_row.token)
    @intake_agent = nil
    @started = started
    view.define_singleton_method(:composer_locals) do |error: nil, text: ""|
      { url: "/build/#{request_row.token}/messages", scope: :build_chat, id: "build-chat-form", agent_name: "Ray", error: error, text: text }
    end
  end

  test "signed out, a new draft is the same shell: Ray, the heading until a first card, the thread and the chat box" do
    signed_in(nil)
    chat_assigns(AppRequest.create!(prompt: "A client portal"))
    render template: "build/show"

    assert_select "[data-test='agent-shell'][data-shell='draft']" do
      assert_select "[data-test='agent-chat-header'][data-agent-name='Ray']"
      assert_select "#build-checklist[data-card='false'] [data-test='build-heading']", 1
      assert_select "#build-chat-page[data-build-chat-poll-url='/build/#{@app_request.token}/turns']"
      assert_select "form#build-chat-form[action='/build/#{@app_request.token}/messages'][style*='agent-composer'] textarea[name='build_chat[text]']"
    end
    assert_select "[data-test='build-my-app']", 0, "no Build control in the shell: Ray's summary card carries it"
    assert_select "[data-test='build-claim']", 0, "no name step for a visitor"
    assert_select "[data-test='build-register']", 0, "no sign-in before Build"
  end

  test "once the intake is started, the status card shows the working title and three empty tiles, in the order Ray asks" do
    signed_in(nil)
    chat_assigns(AppRequest.create!(prompt: "A client portal", answers: { "idea" => "A client portal" }), started: true)
    render template: "build/show"

    assert_select "#build-checklist[data-card='true'] [data-test='build-status-card'][data-complete='false']" do
      assert_select "[data-test='build-status-title']", text: "Your app"
      # [component] Each empty tile reads its step's name, never "Not yet", and the
      # step Ray is on now (the theme, after the idea) is marked current (Alex, 2026-10-19).
      { "theme" => "Theme", "agent" => "Agent", "domain" => "Domain" }.each do |tile, name|
        assert_select "[data-test='build-tile-#{tile}'][data-done='false'] [data-test='build-tile-#{tile}-value']", text: /\A#{name}/
      end
      assert_select "[data-test='build-tile-theme'][data-current='true'][aria-current='step'].build-tile-current", 1
      assert_select "[data-test='build-tile-theme-value'].build-tile-current-name .sr-only", text: "(in progress)"
      assert_select "[data-current='true']", 1, "one step is in progress"
      assert_select "[data-test='build-tile-agent'][data-current='false']:not(.build-tile-current)"
    end
    refute_includes rendered, ">Not yet<"
    assert_select "[data-test='build-status-card'][data-build-status-card].build-status-card", 1, "build_status.js finds the card to pop"
    assert_equal %w[build-tile-theme build-tile-agent build-tile-domain],
                 css_select("[data-test='build-status-card'] li").map { |li| li["data-test"] }, "Theme · Agent · Domain, as BuildIntake::STEPS"
    assert_select "[data-test='build-heading']", 0
  end

  test "a complete intake fills every tile: the CTO's portrait and name, the palette, the address" do
    palette = { "name" => "Pitch",
                "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
                "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }
    row = AppRequest.create!(prompt: "A client portal", answers: { "idea" => "A portal" }, cto_name: "Nova",
                             cto_avatar: "harbor", palette: palette, subdomain: "client-portal")
    signed_in(nil)
    chat_assigns(row)
    render template: "build/show"

    assert_select "[data-test='build-status-card'][data-complete='true']" do
      assert_select "[data-test='build-status-title']", "Client Portal", "the claimed address in words until the idea card names it"
      assert_select "[data-test='build-tile-agent'][data-done='true'] [data-test='build-tile-agent-portrait'][src*='cto_portraits/harbor']"
      assert_select "[data-test='build-tile-agent-value']", text: /Nova/
      assert_select "[data-test='build-tile-theme'][data-done='true'] span[style*='#15803d']"
      assert_select "[data-test='build-tile-theme-value']", text: /Pitch/
      assert_select "[data-test='build-tile-domain-value']", text: /client-portal\.mcritchie\.app/
      %w[theme agent domain].each { |tile| assert_select "[data-test='build-tile-#{tile}-check']", 1 }
      assert_select "[data-current='true']", 0, "nothing in progress once every step is set"
    end
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
    assert_includes rendered, ".mcritchie.app"
    refute_includes rendered, ".mcritchie.studio'", "the visible suffix and preview are mcritchie.app (task app-domains-use-mcritchie-app)"
    assert_includes rendered, ".replace(/\\.mcritchie\\.(app|studio)$/, '')", "a pasted address loses either suffix, as normalize_subdomain does"
    AppRequest::EXAMPLE_NAMES.each { |example| assert_includes rendered, example }
    assert_includes rendered, ".slice(0, 3)", "three examples are sampled per visit"
    assert_includes rendered, "if (index === last) { this._typing = null; return }", "the motion stops on the third"
    assert_select "[data-test='build-register']", 0
  end

  test "queued, the page shows the reserved address and the first step done" do
    signed_in(users(:alex))
    @app_request = AppRequest.create!(prompt: "A client portal", user: users(:alex)).queue!("client-portal")
    render template: "build/show"

    assert_select "[data-test='agent-shell'][data-shell='request'] [data-test='agent-shell-status'] [data-test='build-status']", 1, "the same shell, the status in its card"
    assert_select "[data-test='build-host']", text: "client-portal.mcritchie.app"
    assert_select "[data-test='build-steps'] [data-step='queued'][data-done='true']"
    assert_select "[data-test='build-steps'] [data-step='live'][data-done='false']"
  end
end
