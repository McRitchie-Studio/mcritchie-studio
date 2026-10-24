# frozen_string_literal: true

require "test_helper"

# [component] The /build intake cards in isolation (app/views/build/cards/*,
# .agents/epics/build-with-ray-v2.md, 2-5): what each card shows and what each
# CTA posts. Every CTA is a PATCH to the request's intake path with the field,
# the card's message and a client id, so the tap both sets the field and relays
# one visitor turn (BuildIntake::Choice).
class BuildCardsViewTest < ActionView::TestCase
  include ApplicationHelper
  include CtaGlowHelper

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

  test "the idea card: a title, its key features, Start App and a Build something else link" do
    card("idea", "title" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ])
    assert_select "[data-test='build-idea-title']", "League Standings Hub"
    assert_select "[data-test='build-idea-features'] li", 2
    assert_select "#{intake_form('idea')} input[name='message_id'][value='#{@message.id}']"
    assert_select "#{intake_form('idea')} input[name='client_id']"
    assert_select "#{intake_form('idea')} [data-test='build-choose-idea']:not([disabled])", "Start App"
    refute_match(/Build App/, rendered)
    assert_select "#{intake_form('idea_else')} [data-test='build-idea-else']", "Build something else"
  end

  test "a locked idea reads as building, and a v1 card without a title still shows its sentence" do
    @row.update!(answers: { "title" => "League Standings Hub", "idea" => "League Standings Hub", "features" => %w[a b] })
    card("idea", "title" => "League Standings Hub", "features" => %w[a b])
    assert_select "[data-test='build-choose-idea'][disabled]", "Building this"

    card("idea", "idea" => "A league site with live standings")
    assert_select "[data-test='build-idea-title']", "A league site with live standings"
  end

  test "Customize your CTO: one stack of portrait, prefilled name, name ideas, then Wake Up your CTO" do
    card("cto", "names" => %w[Marble Coach Scout], "portrait" => "animal:fox")
    assert_select "[data-test='build-cto-heading']", "Customize your CTO"
    refute_match(/Meet your CTO/, rendered)
    assert_select "[data-test='build-portrait-preview'][data-avatar='animal:fox'] svg.cto-animal[data-animal='fox'][aria-label='Fox']"
    assert_select "[data-test='build-portrait-open'][aria-haspopup='dialog']"
    assert_select "[data-test='build-portrait-new']", "New image"
    assert_select "dialog[data-test='build-portrait-dialog'] input[name='portrait'][type='radio']", BuildIntake::Animals::SET_SIZE
    assert_select "dialog input[name='portrait'][value='animal:fox'][checked]"
    assert_select "[data-test='build-cto-name-input'][name='custom_name'][value='Marble']"
    # Every one of Ritch's names is a visible tap, not a datalist that filters the
    # others away while the first one is prefilled.
    assert_select "datalist", 0
    assert_equal %w[Marble Coach Scout], css_select("[data-test='build-cto-name-suggestion']").map { |b| b["data-build-cto-name"] }
    assert_select "[data-test='build-cto-name-suggestion'][type='button']", 3, "a tap fills the field; it never submits"
    assert_select "[data-test='build-cto-name-suggestion'][aria-pressed='true']", text: "Marble"
    # [component] Alex, 2026-10-19: the CTA reads Wake Up your CTO, and stands taller than a plain button.
    assert_select "#{intake_form('cto')} [data-test='build-choose-cto']", "Wake Up your CTO"
    refute_match(/Hatch CTO/, rendered)
    assert_includes css_select("[data-test='build-choose-cto']").first["class"].split, "min-h-14", "the CTO's CTA is taller"
    refute_match(/Build App/, rendered)

    # The stack, top to bottom: the portrait, the name, the name ideas, Wake Up your CTO, in one centred column.
    stack = css_select("[data-test='build-cto-stack']").first
    assert_includes stack["class"].split, "flex-col"
    order = stack.element_children.map { |el| el["data-test"] || el.at_css("[data-test]")&.[]("data-test") }
    assert_equal %w[build-cto-portrait build-cto-name-input build-cto-names build-cto-glow], order
    assert_includes css_select("[data-test='build-choose-cto']").first["class"].split, "w-full", "the CTA spans the card at the bottom"
  end

  test "a CTO already set keeps its name and saves again" do
    @row.update!(cto_name: "Coach", cto_avatar: "meadow")
    card("cto", "names" => %w[Marble Coach Scout], "portrait" => "harbor")
    assert_select "[data-test='build-cto-name-input'][value='Coach']"
    assert_select "dialog input[name='portrait'][value='meadow'][checked]"
    assert_select "[data-test='build-choose-cto']", "Save my CTO"
  end

  test "the theme card: three selectable columns, the middle one preselected, one Choose Theme; the dark/light toggle stays" do
    themes = %w[Pitch Field Court].map { |name| PALETTE.merge("name" => name) }
    card("theme", "palettes" => themes)
    assert_select "#{intake_form('palette')}[data-test='build-card-palette'][data-mode='dark'] .sm\\:grid-cols-3[role='radiogroup']"
    assert_select "[data-test='build-palette']", 3
    assert_select "[data-test='build-theme-toggle-dark'][type='button'][aria-pressed='true']"
    assert_select "[data-test='build-theme-toggle-light'][type='button'][aria-pressed='false']"
    assert_select "[data-build-theme-preview='dark']:not([hidden])[style*='#0b1220']", 3
    assert_select "[data-build-theme-preview='light'][hidden][style*='#ffffff']", 3
    # Options, not buttons: one radio per theme, named index, the middle one checked.
    radios = css_select("[data-test='build-palette'] input[type='radio'][name='index']")
    assert_equal %w[0 1 2], radios.map { |r| r["value"] }
    assert_equal %w[Pitch Field Court], radios.map { |r| r["aria-label"] }, "each option is named by its theme"
    assert_equal [ false, true, false ], radios.map { |r| r.key?("checked") }, "the middle theme is preselected"
    assert_select "[data-test='build-palette'] button", 0, "no This Theme under each column"
    refute_match(/This Theme/, rendered)
    # The selected one reads as selected: a ring and a check.
    label = css_select("[data-test='build-palette']").first["class"].split
    assert_includes label, "has-[:checked]:ring-2"
    assert_select "[data-test='build-palette-check'][aria-hidden='true']", 3
    # One CTA, at the bottom, submitting the selected index.
    assert_select "#{intake_form('palette')} button[type='submit']", 1
    assert_select "#{intake_form('palette')} > .cta-glow > button[type='submit'][data-test='build-choose-palette']", "Choose Theme"
    # [component] Alex, 2026-10-19: more room above Choose Theme, the moving orbit
    # glow (a clipped ring turning behind it), and under it a link asking Ritch for
    # three new themes through the chat box.
    glow = css_select("[data-test='build-palette-glow']").first
    assert_includes glow["class"].split, "cta-glow-orbit"
    assert_includes glow["class"].split, "mt-6", "more space above Choose Theme"
    assert_select "[data-test='build-palette-glow'] > span.cta-glow-ring[aria-hidden='true'] + button[data-test='build-choose-palette']", 1
    assert_select "#{intake_form('palette')} > .cta-glow + [data-test='build-theme-more']", 1, "the ask sits under Choose Theme"
    assert_select "[data-test='build-theme-more'] button[type='button'][data-test='build-theme-more-ask'][data-build-ask='Can you give me three new theme ideas?']",
                  text: "Pick three new themes"
    assert_select "[data-test='build-theme-more']", text: /Want different colors\?/
    assert_select "[data-test='build-more-like']", 0
    refute_includes rendered, "More like this"
  end

  test "the theme card preselects the theme already chosen, and the middle of two is the first" do
    themes = %w[Pitch Field Court].map { |name| PALETTE.merge("name" => name) }
    @row.update!(palette: themes.last)
    card("theme", "palettes" => themes)
    assert_equal [ false, false, true ], css_select("input[name='index']").map { |r| r.key?("checked") }
    assert_select "[data-test='build-palette'][data-chosen='true']", 1
    assert_select "[data-test='build-choose-palette'][disabled]", 1, "Choose Theme on the chosen theme cannot post (task build-flow-polish)"

    @rendered = +""
    @row.update!(palette: {})
    card("theme", "palettes" => themes.first(2))
    assert_equal [ true, false ], css_select("input[name='index']").map { |r| r.key?("checked") }
    assert_select "[data-test='build-choose-palette']:not([disabled])", 1, "nothing chosen yet: Choose Theme is live"
  end

  test "the domain card: one stack of bare-name chips, the name field with the suffix inside it, then Use Domain" do
    card("address", "names" => %w[poke-offense pokemon-lineup])
    assert_select "#{intake_form('address')}[data-test='build-card-address'][data-build-address='/build/check']"
    assert_equal %w[build-address-suggestions build-address-field build-address-availability build-address-glow],
                 css_select("[data-test='build-address-stack']").first.element_children.reject { |el| el["class"].to_s.split.include?("sr-only") }.map { |el| el["data-test"] || el.at_css("[data-test]")&.[]("data-test") },
                 "top to bottom: the chips, the field, the availability line, Use Domain"
    # Chips are bare names: the suffix lives only in the field.
    chips = css_select("[data-test='build-address-suggestion']")
    assert_equal %w[poke-offense pokemon-lineup], chips.map { |c| c.text.strip }
    assert(chips.all? { |c| c["type"] == "button" }, "a chip fills the field; it never submits")
    spoken = css_select(".sr-only").count { |node| node.text.include?(".mcritchie.app") }
    assert_equal 1, spoken, "a screen reader's description of the field names the suffix"
    assert_equal 1, rendered.scan(".mcritchie.app").size - spoken, "the suffix is seen once, inside the field"
    assert_select "label[data-test='build-address-field'].justify-center [data-test='build-address-input'] + [data-test='build-address-suffix']", ".mcritchie.app"
    assert_select "[data-test='build-address-input'][size='12']", 1, "sized to its name, so name and suffix centre as one group"
    # The first suggestion is preselected: it fills the field and glows.
    assert_select "[data-test='build-address-input'][name='subdomain'][value='poke-offense']"
    assert_equal %w[true false], chips.map { |c| c["aria-pressed"] }
    assert_select "button[type='submit'][data-test='build-choose-address'][data-build-glow='true']", "Use Domain"
    assert_select "#{intake_form('address')} button[type='submit']", 1, "one CTA"
    # A 30-character name must wrap inside a 360px card, never run off it (the e2e measures it).
    %w[max-w-full break-all].each { |c| assert_includes chips.first["class"].split, c }
    refute_match(/\bAddress\b|Use this domain|Or type your own/, rendered)
  end

  test "the domain card draws a taken suggestion disabled, preselects the first free one, and keeps a chosen domain" do
    AppRequest.create!(prompt: "theirs", status: "queued", subdomain: "poke-offense", user: users(:viewer))
    card("address", "names" => %w[poke-offense pokemon-lineup])
    assert_select "[data-test='build-address-suggestion'][disabled]", "poke-offense"
    assert_select "[data-test='build-address-input'][value='pokemon-lineup']"
    assert_select "[data-test='build-address-suggestion'][aria-pressed='true']", "pokemon-lineup"

    @rendered = +""
    @row.update!(subdomain: "my-own-name")
    card("address", "names" => %w[pokemon-lineup])
    assert_select "[data-test='build-address-input'][value='my-own-name']"
    assert_select "[data-test='build-address-suggestion'][aria-pressed='true']", 0, "a name of their own matches no chip"
    assert_select "[data-test='build-card-address'][data-chosen='true']"
    assert_select "[data-test='build-choose-address'][disabled]", 1, "Use Domain on the chosen domain cannot post (task build-flow-polish)"
  end

  test "[component] the domain card brings its availability with it, and says the suffix to a screen reader (task build-flow-polish)" do
    AppRequest.create!(prompt: "theirs", status: "queued", subdomain: "poke-offense", user: users(:viewer))
    card("address", "names" => %w[poke-offense pokemon-lineup])
    assert_select "[data-test='build-address-availability'][data-state='available']", "Available",
                  "the render's own check answers for the preselected name: the page asks nothing on arrival"
    assert_select "[data-test='build-choose-address']:not([disabled])", 1

    input = css_select("[data-test='build-address-input']").first
    assert_select "label[data-test='build-address-field'] .sr-only", { text: /mcritchie\.app/, count: 0 },
                  "the suffix is not part of the field's label, so it is read once, as its description"
    described = input["aria-describedby"].split.map { |id| css_select("##{id}").first&.text.to_s.strip }
    assert_equal "Ends in .mcritchie.app.", described.first, "the field's description names the suffix the eye sees beside it"
    assert_equal "Available", described.last, "then the live availability line"
  end

  test "[component] the CTA glow: studio colours on Start App, the selected theme behind Choose Theme, the chosen theme after" do
    glow_of = ->(selector) { css_select(selector).first["style"].to_s }
    card("idea", "title" => "League Standings Hub", "features" => %w[a b])
    assert_select ".cta-glow[data-test='build-idea-glow'] > [data-test='build-choose-idea']"
    assert_empty glow_of.("[data-test='build-idea-glow']"), "no theme yet: the studio's own primary and accent (the CSS fallback)"

    @rendered = +""
    themes = [ PALETTE.merge("name" => "Pitch"),
               PALETTE.merge("name" => "Field", "light" => PALETTE["light"].merge("primary" => "#1d4ed8", "accent" => "#b45309")) ]
    themes << PALETTE.merge("name" => "Court")
    card("theme", "palettes" => themes)
    assert_select ".cta-glow[data-build-theme-glow] > [data-test='build-choose-palette']"
    assert_equal "--glow-a: #1d4ed8; --glow-b: #b45309; --glow-c: #4ade80", glow_of.("[data-test='build-palette-glow']"),
                 "the middle (selected) theme's light primary, light accent, dark primary"
    options = css_select("input[name='index']")
    assert_equal %w[#15803d #1d4ed8 #15803d], options.map { |o| o["data-glow-a"] }, "every option carries its colours for the swap"
    assert_equal %w[#4ade80 #4ade80 #4ade80], options.map { |o| o["data-glow-c"] }

    @rendered = +""
    @row.update!(palette: themes[1])
    card("cto", "names" => %w[Marble], "portrait" => "harbor")
    assert_includes glow_of.("[data-test='build-cto-glow']"), "--glow-a: #1d4ed8", "the chosen theme carries on to Wake Up your CTO"
    @rendered = +""
    card("address", "names" => %w[poke-offense])
    assert_select ".cta-glow[data-test='build-address-glow'] > [data-test='build-choose-address']"
    assert_includes glow_of.("[data-test='build-address-glow']"), "--glow-b: #b45309"
  end

  test "[component] a spent CTA draws no glow: the CTO once set, the theme already chosen" do
    @row.update!(palette: PALETTE, cto_name: "Coach", cto_avatar: "meadow")
    card("cto", "names" => %w[Marble], "portrait" => "harbor")
    assert_select "[data-test='build-cto-glow'][data-glow='off']"
    @rendered = +""
    card("theme", "palettes" => [ PALETTE, PALETTE.merge("name" => "Field") ])
    assert_select "[data-test='build-card-palette'][data-chosen-index='0']"
    assert_select "[data-test='build-palette-glow'][data-glow='off']", 1, "the chosen theme is selected: Choose Theme is spent"
  end

  test "[unit] cta_glow_vars: only hex colours reach the style, and a broken palette falls back" do
    assert_equal({ "--glow-a" => "#15803d", "--glow-b" => "#f59e0b", "--glow-c" => "#4ade80" }, cta_glow_vars(PALETTE))
    assert_nil cta_glow_vars({})
    assert_nil cta_glow_vars(nil)
    assert_nil cta_glow_vars(PALETTE.merge("light" => PALETTE["light"].merge("primary" => "red; background: url(x)")))
  end

  test "the summary card draws the request; Build My App posts the launch, which asks a visitor to sign in first" do
    @row.update!(answers: { "title" => "League Standings Hub", "idea" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ] },
                 cto_name: "Marble", cto_avatar: "meadow", palette: PALETTE, subdomain: "league-hub")
    card("summary")
    assert_select "[data-test='build-card-summary'][data-ready='true']"
    assert_select "[data-test='build-summary-title']", "League Standings Hub"
    assert_select "[data-test='build-summary-features'] li", 2
    assert_select "[data-test='build-summary-cto'] img[src*='cto_portraits/meadow']"
    assert_select "[data-test='build-summary-cto']", /Marble/
    assert_select "[data-test='build-summary-theme']", /Pitch/
    assert_select "[data-test='build-summary-domain']", /league-hub\.mcritchie\.app/
    # Valid list markup: the <dl> holds only <div>s, each holding exactly one <dt> then one <dd>.
    list = css_select("[data-test='build-card-summary'] dl").first
    assert_equal %w[div div div], list.element_children.map(&:name)
    list.element_children.each do |pair|
      assert_equal %w[dt dd], pair.element_children.map(&:name), pair["data-test"]
    end
    button = css_select("[data-test='build-summary-build']").first
    assert_equal "Build My App", button.element_children.first.text.strip, "the resting label"
    # The pressed state (task build-sign-in-modal): while Turbo holds the form
    # aria-busy, the label gives way to a spinner and a working label.
    assert_select "form.group[action='/build/#{@row.token}'] [data-test='build-summary-build'] [data-test='build-summary-working'].hidden", text: /One moment…/
    assert_select "[data-test='build-summary-working'] svg.animate-spin[aria-hidden='true']", 1
    # Signed out it is the same PATCH: the server remembers the press and answers
    # with a stream that opens the sign-in modal (BuildController#sign_in_to_launch).
    assert_equal "true", button["data-signs-in"]
    assert_nil button["data-build-sign-in"]
    assert_select ".cta-glow[data-test='build-summary-glow'][style*='--glow-a: #15803d'] > [data-test='build-summary-build']", 1,
                  "Build My App glows in the chosen theme"
    assert_select "form[data-test='build-summary-form'][data-build-summary-form]", 1, "build_status.js pops the status card when this form posts"
    assert_select "form[action='/build/#{@row.token}'] input[name='_method'][value='patch']"
    assert_select "form[action='/build/#{@row.token}'] input[name='message_id'][value='#{@message.id}']"

    signed_in(User.create!(email: "m@example.com", name: "M", role: "viewer"))
    card("summary")
    assert_select "[data-test='build-summary-working']", text: /Building…/
    assert_select "form[action='/build/#{@row.token}'] input[name='_method'][value='patch']"
    assert_select "form[action='/build/#{@row.token}'] input[name='app_request[subdomain]'][value='league-hub']"
    assert_select "form[action='/build/#{@row.token}'] [data-test='build-summary-build'] > span:first-child", "Build My App"
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
    assert_select "[data-test='build-summary-next']", /Ask Ritch for another address/
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

  # [component] The styles behind the quality pass (task build-cards-quality-pass):
  # the orbit glow turns INSIDE a clipped ring (no sideways scroll) and holds still
  # under reduced motion; the status card's arrival grows past full size with a
  # glow; the step in progress shimmers, and holds still under reduced motion.
  test "the orbit glow is clipped to its ring, the card's arrival pops, and the current step shimmers, each still under reduced motion" do
    glow = Rails.root.join("app/assets/tailwind/cta_glow.css").read
    ring = glow[/\.cta-glow-ring \{[^}]*\}/m].to_s
    assert_includes ring, "overflow: hidden", "the turning square is clipped to the ring"
    assert_match(/inset: calc\(-1 \* var\(--glow-reach, 3px\)\)/, ring, "the ring reaches only 3px past the CTA")
    assert_match(/\.cta-glow-ring::before \{[^}]*animation: cta-glow-orbit/m, glow)
    assert_match(/@keyframes cta-glow-orbit \{\s*to \{ transform: translate\(-50%, -50%\) rotate\(1turn\); \}/m, glow, "a transform, run by the compositor")
    assert_match(/\.cta-glow\[data-glow="off"\] > \.cta-glow-ring/, glow, "a spent CTA draws no ring")
    assert_match(/\.cta-glow:has\(> :disabled\) > \.cta-glow-ring/, glow, "a disabled CTA draws no ring")
    reduced = glow[/@media \(prefers-reduced-motion: reduce\)\s*\{.*\z/m].to_s
    assert_includes reduced, ".cta-glow-ring::before { animation: none; }"

    shell = Rails.root.join("app/assets/tailwind/agent_shell.css").read
    pop = shell[/@keyframes agent-shell-pop-in \{.*?\n\}/m].to_s
    assert_includes pop, "scale(1.03)", "the card grows past full size"
    assert_includes pop, "box-shadow: 0 0 0 3px", "with a primary glow"

    cards = Rails.root.join("app/assets/tailwind/build_cards.css").read
    assert_match(/\.build-tile-current \{\s*animation: build-tile-breathe/m, cards)
    assert_match(/\.build-tile-current-name \{[^}]*animation: build-tile-shimmer/m, cards)
    assert_match(/\.build-status-pop \{\s*animation: build-status-pop/m, cards)
    reduced = cards[/@media \(prefers-reduced-motion: reduce\)\s*\{.*\z/m].to_s
    assert_match(/\.build-tile-current-name \{ animation: none; \}/, reduced)
    assert_includes reduced, ".build-status-pop { animation-name: build-status-flash; }", "reduced motion keeps only the glow"
  end
end
