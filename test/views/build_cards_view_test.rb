# frozen_string_literal: true

require "test_helper"

# [component] The /build intake cards in isolation (app/views/build/cards/*,
# .agents/epics/build-with-ray-v2.md, 2-5): what each card shows and what each
# CTA posts. Every CTA is a PATCH to the request's intake path with the field,
# the card's message and a client id, so the tap both sets the field and relays
# one visitor turn (BuildIntake::Choice).
class BuildCardsViewTest < ActionView::TestCase
  include ApplicationHelper

  PALETTE = { "name" => "Pitch",
              "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
              "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }.freeze

  setup do
    @row = AppRequest.create!(prompt: "A league site")
    @message = AgentMessage.create!(channel: "web", external_id: "build:#{@row.token}:1", channel_ref: "build",
                                    thread_key: BuildIntake.thread_key(@row.token), soul_slug: "ray", content: "hi",
                                    status: "completed", response_text: "ok")
    signed_in(nil)
  end

  def signed_in(user)
    view.define_singleton_method(:logged_in?) { !user.nil? }
    view.define_singleton_method(:current_user) { user }
  end

  def card(kind, fields = {}) = render(partial: "build/cards/#{kind == 'theme' ? 'palette' : kind}",
                                       locals: { card: { "card" => kind }.merge(fields), message: @message, request_row: @row })

  def intake_form(field) = "form[action='/build/#{@row.token}/intake'][method='post']:has(input[name='field'][value='#{field}'])"

  test "the idea card: a title, its key features, Build App and a Build something else link" do
    card("idea", "title" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ])
    assert_select "[data-test='build-idea-title']", "League Standings Hub"
    assert_select "[data-test='build-idea-features'] li", 2
    assert_select "#{intake_form('idea')} input[name='message_id'][value='#{@message.id}']"
    assert_select "#{intake_form('idea')} input[name='client_id']"
    assert_select "#{intake_form('idea')} [data-test='build-choose-idea']:not([disabled])", "Build App"
    assert_select "#{intake_form('idea_else')} [data-test='build-idea-else']", "Build something else"
  end

  test "a locked idea reads as building, and a v1 card without a title still shows its sentence" do
    @row.update!(answers: { "title" => "League Standings Hub", "idea" => "League Standings Hub", "features" => %w[a b] })
    card("idea", "title" => "League Standings Hub", "features" => %w[a b])
    assert_select "[data-test='build-choose-idea'][disabled]", "Building this"

    card("idea", "idea" => "A league site with live standings")
    assert_select "[data-test='build-idea-title']", "A league site with live standings"
  end

  test "Meet your CTO: the portrait opens a picker, the name is prefilled, Build App saves both" do
    card("cto", "names" => %w[Marble Coach Scout], "portrait" => "harbor")
    assert_select "[data-test='build-card-cto'] p", text: "Meet your CTO"
    assert_select "[data-test='build-portrait-preview'][src*='cto_portraits/harbor']"
    assert_select "[data-test='build-portrait-open'][aria-haspopup='dialog']"
    assert_select "[data-test='build-portrait-new']", "New image"
    assert_select "dialog[data-test='build-portrait-dialog'] input[name='portrait'][type='radio']", BuildIntake::Portraits::KEYS.size
    assert_select "dialog input[name='portrait'][value='harbor'][checked]"
    assert_select "[data-test='build-cto-name-input'][name='custom_name'][value='Marble']"
    # Every one of Ray's names is a visible tap, not a datalist that filters the
    # others away while the first one is prefilled.
    assert_select "datalist", 0
    assert_equal %w[Marble Coach Scout], css_select("[data-test='build-cto-name-suggestion']").map { |b| b["data-build-cto-name"] }
    assert_select "[data-test='build-cto-name-suggestion'][type='button']", 3, "a tap fills the field; it never submits"
    assert_select "[data-test='build-cto-name-suggestion'][aria-pressed='true']", text: "Marble"
    assert_select "#{intake_form('cto')} [data-test='build-choose-cto']", "Build App"
  end

  test "the theme card: three columns, dark previews first behind a dark/light toggle, This Theme under each" do
    themes = %w[Pitch Field Court].map { |name| PALETTE.merge("name" => name) }
    card("theme", "palettes" => themes)
    assert_select "[data-test='build-card-palette'][data-mode='dark'] .sm\\:grid-cols-3"
    assert_select "[data-test='build-palette']", 3
    assert_select "[data-test='build-theme-toggle-dark'][aria-pressed='true']"
    assert_select "[data-test='build-theme-toggle-light'][aria-pressed='false']"
    assert_select "[data-build-theme-preview='dark']:not([hidden])[style*='#0b1220']", 3
    assert_select "[data-build-theme-preview='light'][hidden][style*='#ffffff']", 3
    assert_select "#{intake_form('palette')} [data-test='build-choose-palette']", text: "This Theme", count: 3
    assert_select "#{intake_form('palette')} input[name='index'][value='2']"
    assert_select "[data-test='build-more-like']", 0
    refute_includes rendered, "More like this"
  end

  test "the domain card: each suggestion is its own tap, and a field for a name of their own" do
    card("address", "names" => %w[league-hub standings])
    assert_select "[data-test='build-card-address'] p", text: "Pick a domain"
    assert_select "#{intake_form('address')}[data-build-domain-chip='/build/check'] input[name='subdomain'][value='league-hub']"
    assert_select "button[type='submit'][data-test='build-address-suggestion']", 2
    # A 30-character name must wrap inside a 360px card, never run off it (the e2e measures it).
    chip = css_select("[data-test='build-address-suggestion']").first
    %w[max-w-full break-all].each { |c| assert_includes chip["class"].split, c }
    assert_includes chip.ancestors("form").first["class"].to_s.split, "max-w-full"
    assert_select "form[data-build-address='/build/check'] [data-test='build-address-input'][name='subdomain']"
    assert_select "[data-test='build-choose-address']", "Use this domain"
    refute_match(/\bAddress\b/, rendered)
  end

  test "the summary card draws the request; Build My App signs in first, then posts the launch" do
    @row.update!(answers: { "title" => "League Standings Hub", "idea" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ] },
                 cto_name: "Marble", cto_avatar: "meadow", palette: PALETTE, subdomain: "league-hub")
    card("summary")
    assert_select "[data-test='build-card-summary'][data-ready='true']"
    assert_select "[data-test='build-summary-title']", "League Standings Hub"
    assert_select "[data-test='build-summary-features'] li", 2
    assert_select "[data-test='build-summary-cto'] img[src*='cto_portraits/meadow']"
    assert_select "[data-test='build-summary-cto']", /Marble/
    assert_select "[data-test='build-summary-theme']", /Pitch/
    assert_select "[data-test='build-summary-domain']", /league-hub\.mcritchie\.studio/
    # Valid list markup: the <dl> holds only <div>s, each holding exactly one <dt> then one <dd>.
    list = css_select("[data-test='build-card-summary'] dl").first
    assert_equal %w[div div div], list.element_children.map(&:name)
    list.element_children.each do |pair|
      assert_equal %w[dt dd], pair.element_children.map(&:name), pair["data-test"]
    end
    button = css_select("[data-test='build-summary-build']").first
    assert_equal "Build My App", button.text.strip
    assert_equal "/build/#{@row.token}", JSON.parse(button["data-build-sign-in"])["returnTo"]

    signed_in(User.create!(email: "m@example.com", name: "M", role: "viewer"))
    card("summary")
    assert_select "form[action='/build/#{@row.token}'] input[name='_method'][value='patch']"
    assert_select "form[action='/build/#{@row.token}'] input[name='app_request[subdomain]'][value='league-hub']"
    assert_select "form[action='/build/#{@row.token}'] [data-test='build-summary-build']", "Build My App"
  end

  test "[component] the summary card's refusal: the reason, then the next step for its kind; Build My App stays" do
    @row.update!(answers: { "title" => "League Standings Hub", "idea" => "x" }, cto_name: "Marble", cto_avatar: "meadow",
                 palette: PALETTE, subdomain: "league-hub")
    signed_in(users(:viewer))
    locals = { card: { "card" => "summary" }, message: @message, request_row: @row }

    render(partial: "build/cards/summary", locals: locals.merge(refusal: { reason: "Your Vibe plan includes 1 app, and you already have one.", plan_limit: true, existing_app: "/applications/pup/chat" }))
    assert_select "##{BuildController.summary_dom_id(@message)}[data-refused='true']"
    assert_select "[data-test='build-summary-refusal'][role='alert'] [data-test='build-summary-refusal-reason']", /Vibe plan includes 1 app/
    assert_select "a[data-test='build-summary-existing-app'][href='/applications/pup/chat']"
    assert_select "a[data-test='build-summary-upgrade'][href='/packages']"
    assert_select "form input[name='message_id'][value='#{@message.id}']"
    assert_select "[data-test='build-summary-build']", 1

    @rendered = +"" # each render below is read on its own
    render(partial: "build/cards/summary", locals: locals.merge(refusal: { reason: "Subdomain That name is taken.", domain: true }))
    assert_select "[data-test='build-summary-next']", /Ask Ray for another address/
    assert_select "[data-test='build-summary-existing-app']", 0

    @rendered = +""
    render(partial: "build/cards/summary", locals: locals)
    assert_select "[data-refused='false']"
    assert_select "[data-test='build-summary-refusal']", 0
  end

  test "a summary whose request is no longer complete offers no Build" do
    card("summary")
    assert_select "[data-test='build-card-summary'][data-ready='false']"
    assert_select "[data-test='build-summary-build']", 0
    assert_select "[data-test='build-summary-not-ready']"
  end
end
