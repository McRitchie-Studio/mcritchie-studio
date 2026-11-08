require "test_helper"

# [component] /integrations: public, three groups of compact tiles, Coming soon
# tags on every entry not delivered, prices on add-ons, and a booking CTA on
# every entry; the detail waits behind each tile's Details toggle.
class IntegrationsControllerTest < ActionDispatch::IntegrationTest
  # The agreed limit for a tile's one line (tagline, else blurb): 64 characters.
  # Today's longest is 64 (gmail), so a longer line fails here, not on a phone.
  TILE_LINE_LIMIT = 64
  def entry(key) = "[data-test='integration-entry'][data-entry='#{key}']"

  test "[component] anyone sees the three groups, without signing in" do
    get integrations_path

    assert_response :success
    assert_select "h1", text: "Build smarter. Your backend runs itself."
    assert_equal %w[connect add_ons custom], css_select("[data-test='integration-group']").map { |g| g["data-group"] }
    assert_equal %w[Connect We\ run\ it Talk\ to\ us], css_select("[data-test='integration-group'] h2").map { _1.text.strip }
    assert_equal Integration.entries.reject(&:dark?).map(&:key), css_select("[data-test='integration-entry']").map { |e| e["data-entry"] },
                 "a visitor sees every entry but the dark ones"
  end

  test "[component] the group chips jump to each group, pinned under the header, with each group's count" do
    get integrations_path

    nav = css_select("[data-test='group-nav']").first
    assert_includes nav["class"].split, "sticky"
    assert_includes nav["class"].split, "top-[var(--pin-stack-bottom,0px)]", "it pins under whatever chrome the engine pins above"
    chips = css_select("[data-test='group-chip']")
    assert_equal %w[#connect #add-ons #custom], chips.map { _1["href"] }
    chips.each do |chip|
      group = Integration.groups.find { _1.key == chip["data-group"] }
      assert_select "section##{group.key.dasherize}[data-test='integration-group'][data-group='#{group.key}']", 1
      assert_equal "#{group.title} #{group.entries.size}", chip.text.squish
    end
  end

  test "[component] a tile shows one short line; the blurb, ways in, abilities and price note wait behind Details" do
    get integrations_path

    css_select("[data-test='integration-entry']").each do |card|
      item = Integration.find(card["data-entry"])
      assert_equal item.line, card.at_css("[data-test='entry-line']").text.strip, item.key
      assert_operator item.line.length, :<=, TILE_LINE_LIMIT, "#{item.key}: a tile's line stays one short line"
      details = card.at_css("[data-test='entry-details']")
      assert details, "#{item.key} has Details"
      assert_equal "details", details.name, "#{item.key}: a native disclosure, no script"
      assert_not details.key?("open"), "#{item.key}: Details starts closed"
      assert_equal "summary", card.at_css("[data-test='entry-details-toggle']").name, item.key
      # Nothing about how it connects shows outside Details.
      card.css("[data-test='entry-connections'], [data-test='entry-blurb'], [data-test='entry-price-note'], [data-test='entry-tier-note']").each do |hidden|
        assert hidden.ancestors("[data-test='entry-details']").any?, "#{item.key}: #{hidden['data-test']} sits behind Details"
      end
    end
    assert_select "#{entry('discord')} [data-test='entry-details'] [data-test='entry-blurb']", text: /Two-way/
    assert_select "#{entry('extra_builds')} [data-test='entry-blurb']", 0, "no tagline: the line is the blurb, shown once"
  end

  test "[component] the read-only tiles say Read only on the tile line, and crypto's line is not its blurb again" do
    get integrations_path

    %w[google_calendar gmail google_drive fathom].each do |key|
      line = css_select("#{entry(key)} [data-test='entry-line']").first.text.strip
      assert_match(/Read only\.\z/, line, "#{key}: read only shows on the tile, not only in Details")
      assert_operator line.length, :<=, TILE_LINE_LIMIT, key
    end
    crypto = Integration.find(:crypto)
    assert_equal "Solana wallets and stablecoin payouts in your app.", crypto.line
    assert_not crypto.blurb.start_with?(crypto.line.delete_suffix(".")), "crypto: the tile line is not the blurb with a word cut"
  end

  test "[component] the Details toggle shows a visible focus ring for a keyboard user" do
    get integrations_path

    toggles = css_select("[data-test='entry-details-toggle']")
    assert toggles.any?
    toggles.each do |summary|
      classes = summary["class"].split
      %w[rounded focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary].each do |cls|
        assert_includes classes, cls, "the summary carries #{cls}"
      end
    end
  end

  test "[unit] the controller carries no connection_card? helper, and the Google partial names the action row" do
    assert_not IntegrationsController.private_method_defined?(:connection_card?), "dead helper removed"
    assert_not IntegrationsController.method_defined?(:connection_card?)
    partial = Rails.root.join("app/views/integrations/_google_connection.html.erb").read
    assert_includes partial, "action row"
    assert_not_includes partial, "Sign in row"
  end

  test "[component] every entry not live reads Coming soon or On request, never Available" do
    get integrations_path

    Integration.entries.reject(&:dark?).each do |item|
      if item.soon?
        assert_select "#{entry(item.key)} [data-test='coming-soon']", text: "Coming soon"
      elsif item.on_request?
        assert_select "#{entry(item.key)} [data-test='on-request']", text: "On request"
      end
      assert_select "#{entry(item.key)} [data-test='available']", item.live? ? 1 : 0
    end
    css_select("[data-test='entry-cta'][data-intent='connect']").each do |cta|
      refute_equal "soon", cta.ancestors("[data-test='integration-entry']").first["data-status"]
    end
  end

  test "[component] integrations read Free, add-ons a price or Quote, each with its button" do
    get integrations_path

    assert_select "#{entry('discord')} [data-test='entry-price']", text: /Free/
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-price']", text: %r{\$25/month \+ \$15/user/month}
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-price-note']", text: "Google Business Starter seat included"
    assert_no_match(/\$250/, response.body)
    assert_select "#{entry('payments')} [data-test='entry-price']", text: /Quote/
    assert_select "#{entry('discord')} [data-test='entry-cta']", text: "Connect"
    assert_select "#{entry('github_org')} [data-test='entry-cta']", text: "Connect"
    assert_select "#{entry('slack')} [data-test='entry-cta']", text: "Get notified"
    assert_select "#{entry('stripe_connect')} [data-test='entry-cta']", text: "Talk to us"
    assert_select "#{entry('payments')} [data-test='entry-cta']", text: "Talk to us"
    assert_select "#{entry('payments')} [data-test='on-request']"
    assert_select "#{entry('google_workspace_connect')} [data-test='entry-tier']", text: "From Pro"
    assert_select "#{entry('google_workspace_connect')} [data-test='entry-lead'][data-lead='google'] [data-test='brand-logo']"
    css_select("[data-test='entry-cta']").each do |cta|
      item = cta.ancestors("[data-test='integration-entry']").first["data-entry"]
      next if IntegrationsController::GOOGLE_CARDS.key?(item) # opens the sign-in modal; its own test below
      intent = Integration.find(item).intent
      expected = item == "discord" ? integrations_discord_path : contact_form_path(source: { page: "integrations", item: item, intent: intent })
      assert_equal expected, cta["href"], item
    end
  end

  test "[integration] signed out, each Google card's Connect opens the sign-in modal back to /integrations; Fathom's still opens the contact form" do
    get integrations_path

    IntegrationsController::GOOGLE_CARDS.each_key do |item|
      assert_select "#{entry(item)} [data-test='entry-cta']", count: 1 do |ctas|
        cta = ctas.first
        assert_equal "button", cta.name, item
        assert_nil cta["href"], item
        assert_equal "auth", cta["data-opens"], item
        assert_includes cta["@click"], "$store.modals.open('auth'", item
        assert_includes cta["@click"], "returnTo: '#{integrations_path}'", item
        assert_includes cta["@click"], "title: 'Sign in to connect Google'", item
      end
    end
    assert_select "#{entry('fathom')} [data-test='entry-cta'][href='#{contact_form_path(source: { page: "integrations", item: "fathom", intent: Integration.find("fathom").intent })}']", count: 1
  end

  test "[component] Extra build requests is a Builder add-on: From Builder, its blurb, Quote and Talk to us" do
    get integrations_path

    assert_select "#{entry('extra_builds')} [data-test='entry-tier']", text: "From Builder"
    assert_select "#{entry('extra_builds')} [data-test='entry-line']", text: "More changes than Builder's several a month, or a second app."
    assert_select "#{entry('extra_builds')} [data-test='entry-price']", text: /Quote/
    assert_select "#{entry('extra_builds')} [data-test='entry-cta']", text: "Talk to us"
  end

  test "[component] the add-on is named Managed Workspace, keeps the Google logo and names Google Workspace" do
    get integrations_path

    assert_select "#{entry('google_workspace_managed')} [data-test='entry-name']", text: "Managed Workspace"
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-lead'][data-lead='google']"
    assert_select "#{entry('google_workspace_managed')} [data-test='entry-blurb']", text: /Google Workspace/
    assert_no_match(/Google Workspace, managed/, response.body)
  end

  test "[component] the Discord card says two-way, stays On request, and opens its guide" do
    get integrations_path

    assert_select "#{entry('discord')} [data-test='entry-name']", text: "Discord"
    assert_select "#{entry('discord')} [data-test='entry-blurb']", text: /two-way/i
    assert_select "#{entry('discord')} [data-test='on-request']"
    assert_select "#{entry('discord')} [data-test='entry-cta'][href='#{integrations_discord_path}']", text: "Connect"
  end

  # --- /integrations/discord --------------------------------------------------

  test "[component] the Discord guide renders publicly with examples, setup and the permissions note" do
    get integrations_discord_path

    assert_response :success
    assert_select "h1", text: "Give your agents a home in Discord"
    assert_select "[data-test='discord-guide'] header [data-test='on-request']", text: "On request"
    assert_select "[data-test='examples-label']", text: /Examples/
    assert_select "[data-test='example-post']", minimum: 3
    assert_select "[data-test='example-exchange-line']", 2
    assert_select "[data-test='example-exchange']", text: /@Studio CTO why is checkout slow\?/
    assert_select "[data-test='setup-step']", 7
    assert_select "[data-test='permissions-note']", text: /You will approve exactly what the bot can do, and you can remove it any time from your server settings\./
    assert_select "[data-test='back-to-integrations'][href='#{integrations_path}']"
  end

  # The bot is not built yet (Mr. McRitchie, 2026-10-13): the page and the card
  # promise it, on request, and never claim it already runs.
  test "[component] the Discord guide and card speak of the bot in the future, never as live" do
    get integrations_discord_path

    assert_select "[data-test='discord-guide'] header p", text: /not live yet/
    assert_select "[data-test='discord-guide'] header p", text: /will\s+post what matters/
    page = css_select("[data-test='discord-guide']").text
    [ /our bot posts/i, /Add our bot to your server/, /Click "Add to Discord"/, /You approve exactly/, /bot is set up with you/ ].each do |claim|
      assert_no_match claim, page
    end

    get integrations_path
    assert_select "#{entry('discord')} [data-test='entry-blurb']", text: /our bot will post .* and answer when you/
    assert_no_match(/our bot posts/i, css_select(entry("discord")).text)
  end

  test "[component] the setup guide is seven numbered steps, each with Discord's own help article and a drawing of its screen" do
    get integrations_discord_path

    help = "https://support.discord.com/hc/en-us/articles/"
    expected = {
      "server" => "#{help}204849977-How-do-I-create-a-server",
      "channel" => "#{help}10543994968087-Channel-Permissions-Settings-101",
      "roles" => "#{help}214836687-Discord-Roles-and-Permissions",
      "invite" => "#{help}21334461140375-Using-Apps-on-Discord",
      "ids" => "#{help}206346498-Where-can-I-find-my-User-Server-Message-ID",
      "send" => nil,
      "test" => nil
    }
    steps = css_select("[data-test='setup-steps'] > [data-test='setup-step']")
    assert_equal expected.keys, steps.map { |step| step["data-step"] }, "the steps, in order"
    assert_equal "ol", css_select("[data-test='setup-steps']").first.name, "a numbered list"

    steps.each_with_index do |step, index|
      key = step["data-step"]
      assert_match(/Step #{index + 1}:/, step.at_css("h3").text, key)
      links = step.css("[data-test='step-help-link']")
      if expected[key]
        assert_equal [ expected[key] ], links.map { |link| link["href"] }, key
        assert_equal "_blank", links.first["target"], key
        assert_includes links.first["rel"].split, "noopener", key
      else
        assert_empty links, key
      end
      visual = step.css("[data-test='step-visual']")
      assert_equal [ key ], visual.map { |v| v["data-visual"] }, "#{key} draws its own screen"
      assert_equal "img", visual.first["role"], key
      assert visual.first["aria-label"].present?, "#{key}'s drawing is named"
    end

    # Every outbound link in the guide is an official Discord URL, opened in a new tab.
    outbound = css_select("[data-test='discord-guide'] a[href^='http']")
    assert_equal 5, outbound.size, "the five help articles, nothing else leaves the page"
    outbound.each do |link|
      assert_match(%r{\Ahttps://(support\.)?discord\.com/}, link["href"])
      assert_equal "_blank", link["target"], link["href"]
    end
  end

  test "[component] each step says what the client does, honestly: the invite comes from us, IDs only, a hello to test" do
    get integrations_discord_path

    step = ->(key) { "[data-test='setup-step'][data-step='#{key}']" }
    assert_select step.("channel"), text: /#agents/
    assert_select step.("roles"), text: /Allow anyone to @mention this role/
    assert_select step.("roles"), text: /Assign nobody/
    assert_select step.("invite"), text: /Your invite link comes from us/
    assert_select "#{step.("invite")} [data-test='invite-slot']", text: /On request/
    %w[View\ Channels Read\ Message\ History Send\ Messages Send\ Messages\ in\ Threads].each do |permission|
      assert_select "#{step.("invite")} [data-test='invite-permissions'] li", text: /\A\W*#{permission}\z/
    end
    assert_select step.("ids"), text: /Developer Mode/
    assert_select step.("ids"), text: /Advanced/
    assert_select step.("send"), text: /Never send a password or a token/
    assert_select "#{step.("send")} [data-test='step-request-link'][href='#discord-request']"
    assert_select "#discord-request [data-test='discord-request-cta']"
    assert_select step.("test"), text: /@Studio CTO hello/
    assert_select step.("test"), text: /Replies are not instant/
    # One shared bot answers for every agent and leads with the agent name (AgentMessageReplyJob).
    assert_select "#{step.("test")} [data-test='step-visual']", text: /Studio\s*Bot\s*Studio CTO · Hello/
    assert_select "[data-test='example-exchange-line']", text: /Studio CTO · Two slow queries/
    assert_no_match(/within a few minutes|instantly|right away/i, css_select(step.("test")).text, "a reply waits on the agent, so the page promises no speed")
    # Operator-only setup stays off the client page.
    assert_no_match(/developer portal|Message Content|1Password|bot-token|McRitchie Agents/i, response.body)
  end

  test "[component] the guide's button requests the bot through the contact form, never a Discord authorization link" do
    get integrations_discord_path

    assert_select "[data-test='discord-request-cta']", text: "Request the Discord bot" do |cta|
      assert_equal contact_form_path(source: { page: "integrations/discord", item: "discord", intent: "connect" }), cta.first["href"]
    end
    assert_no_match(%r{discord(app)?\.com/(api/)?oauth2}, response.body)
    assert_no_match(/webhook/i, response.body, "the webhook version is gone")
  end

  test "[component] the Talk to us section: Custom eyebrow, no price line, one Talk to us button each" do
    get integrations_path

    group = "[data-test='integration-group'][data-group='custom']"
    assert_select "#{group} [data-test='group-kicker']", text: "Custom"
    assert_select "#{group} h2", text: "Talk to us"
    assert_equal %w[stripe_connect crypto extra_storage ai_features custom_connectors enterprise_extras],
                 css_select("#{group} [data-test='integration-entry']").map { |e| e["data-entry"] }
    assert_select "#{group} [data-test='entry-price']", 0
    assert_no_match(/Scoped on a call/, css_select(group).to_s)
    css_select("#{group} [data-test='integration-entry']").each do |card|
      ctas = card.css("[data-test='entry-cta']")
      assert_equal [ "Talk to us" ], ctas.map { |c| c.text.strip }, card["data-entry"]
      assert_equal "custom", ctas.first["data-intent"]
    end
    assert_select "#{entry('stripe_connect')} [data-test='coming-soon']"
    assert_select "[data-test='integration-group'][data-group='connect'] #{entry('stripe_connect')}", 0, "Stripe is listed once"
    assert_equal %w[google_calendar gmail google_drive fathom google_workspace_connect discord github_org slack],
                 css_select("[data-test='integration-group'][data-group='connect'] [data-test='integration-entry']").map { |e| e["data-entry"] }
    assert_equal %w[google_workspace_managed payments extra_builds],
                 css_select("[data-test='integration-group'][data-group='add_ons'] [data-test='integration-entry']").map { |e| e["data-entry"] }
  end

  test "[component] the page closes on Book a call and links back to /packages, and /packages links here" do
    get integrations_path
    assert_select "[data-test='not-listed'] [data-test='not-listed-cta'][href='#{schedule_index_path}']", text: "Book a call"
    assert_select "[data-test='packages-link'][href='#{packages_path}']"

    get packages_path
    assert_select "[data-test='integrations-link'][href='#{integrations_path}']"
  end
end
