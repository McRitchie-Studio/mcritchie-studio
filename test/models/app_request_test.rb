require "test_helper"

# [unit] AppRequest — the /build funnel's record. The subdomain rules are the
# promise we make publicly (<name>.mcritchie.app), so each is pinned here:
# format, reserved names (including every satellite's), uniqueness among
# holding requests, and the tier's apps-per-account limit (data, unlimited today). Queueing opens the board task
# in the same transaction.
class AppRequestTest < ActiveSupport::TestCase
  def draft(**attrs) = AppRequest.create!({ prompt: "A booking site for my groomer" }.merge(attrs))

  test "a draft needs only a prompt, and mints its own secret token" do
    d = draft

    assert d.draft?
    assert_operator d.token.length, :>=, 20
    assert_nil d.subdomain
    refute AppRequest.new(prompt: "  ").valid?
    refute AppRequest.new(prompt: "x" * (AppRequest::PROMPT_LIMIT + 1)).valid?
  end

  test "subdomain format: 3-30 of a-z, 0-9, hyphen, alphanumeric at both ends" do
    %w[abc pawsome-grooming a1b app-2026].each do |ok|
      assert_nil AppRequest.unavailable_reason(ok), "#{ok} should be claimable"
    end
    [ "ab", "a" * 31, "--", "!!", "" ].each do |bad|
      assert_match(/letters, numbers or hyphens/, AppRequest.unavailable_reason(bad), "#{bad.inspect} should be refused")
    end
  end

  test "names are cleaned the way the field cleans them: case, runs of symbols, edge hyphens" do
    {
      "  Pawsome.mcritchie.app " => "pawsome",
      "  Pawsome.mcritchie.studio " => "pawsome",
      "Uber for Dogs!" => "uber-for-dogs",
      "asda ddadd   d" => "asda-ddadd-d",
      "-My_App--" => "my-app",
      "ab.cd" => "ab-cd"
    }.each { |typed, name| assert_equal name, AppRequest.normalize_subdomain(typed), typed.inspect }
  end

  # Client apps are served at <name>.mcritchie.app since 2026-10-19 (task
  # app-domains-use-mcritchie-app): the /build card showed .mcritchie.studio.
  test "[unit] a client app's address is on mcritchie.app, the production preview domain" do
    assert_equal "mcritchie.app", AppRequest::CLIENT_APP_DOMAIN
    assert_equal ClientAppHost::PRODUCTION_DOMAIN, AppRequest::CLIENT_APP_DOMAIN, "the address /build promises is the one ClientAppHost serves"
    request_row = AppRequest.new(subdomain: "pawsome")
    assert_equal "pawsome.mcritchie.app", request_row.host
    assert_equal "https://pawsome.mcritchie.app", request_row.url
    assert_equal "pawsome.mcritchie.app", AppRequest.host_for("pawsome")
    assert_nil AppRequest.new.host
    assert_nil AppRequest.new.url
    assert_nil AppRequest.host_for("")
  end

  test "[unit] a pasted address with either suffix cleans to the bare name, and only a trailing one" do
    {
      "pawsome.mcritchie.app" => "pawsome",
      "pawsome.mcritchie.studio" => "pawsome",
      "PAWSOME.MCRITCHIE.APP" => "pawsome",
      "mcritchie.app.pawsome" => "mcritchie-app-pawsome",
      "pawsome.mcritchie.app.mcritchie.studio" => "pawsome-mcritchie-app",
      "pawsome.example.app" => "pawsome-example-app"
    }.each { |typed, name| assert_equal name, AppRequest.normalize_subdomain(typed), typed.inspect }
  end

  # The reserved list still guards mcritchie.app names: a name that is ours on
  # mcritchie.studio (a satellite, a hub host) would pass for ours on mcritchie.app.
  test "[unit] a hub name stays reserved when claimed as a mcritchie.app address" do
    %w[www app rantly weekly-lock tax].each do |name|
      assert_equal "That name is reserved.", AppRequest.unavailable_reason("#{name}.mcritchie.app"), name
    end
  end

  # A satellite built before mcritchie.app (a showcase rebuild given its
  # subdomain by hand) is served at its registered hub host, so its address
  # and gallery link must not move to mcritchie.app, where nothing serves it.
  test "[unit] a live satellite from before mcritchie.app keeps its mcritchie.studio address" do
    assert_includes AppRequest.hub_hosted_names, "rantly"
    refute_includes AppRequest.hub_hosted_names, "pawsome"
    legacy = AppRequest.new(subdomain: "rantly")
    assert_equal "rantly.mcritchie.studio", legacy.host
    assert_equal "https://rantly.mcritchie.studio", legacy.url
    assert_equal "rantly.mcritchie.studio", AppRequest.host_for("rantly")
  end

  test "every example name the field types is a valid, unreserved name" do
    assert_equal 20, AppRequest::EXAMPLE_NAMES.size
    assert_equal AppRequest::EXAMPLE_NAMES.uniq, AppRequest::EXAMPLE_NAMES
    AppRequest::EXAMPLE_NAMES.each do |example|
      assert_nil AppRequest.unavailable_reason(example), "#{example} would teach a name we refuse"
    end
  end

  test "reserved names include ours and every satellite's subdomain" do
    %w[www api admin build stack].each { |name| assert_equal "That name is reserved.", AppRequest.unavailable_reason(name) }
    satellite_hosts = YAML.safe_load_file(Rails.root.join("config/satellites.yml"))["satellites"]
                          .map { |s| URI.parse(s["production_url"].to_s).host.to_s }
                          .select { |h| h.end_with?(".mcritchie.studio") }
                          .map { |h| h.delete_suffix(".mcritchie.studio") }
    refute_empty satellite_hosts
    satellite_hosts.each { |name| assert_equal "That name is reserved.", AppRequest.unavailable_reason(name), "#{name} is a live satellite" }
  end

  # rolio's production_url is a herokuapp host, not a subdomain of ours, so its
  # slug is what keeps the name from being claimed.
  test "every satellite's slug is reserved, whatever its production_url" do
    %w[rolio chain-ops turf-monster cyvasse].each do |name|
      assert_equal "That name is reserved.", AppRequest.unavailable_reason(name), "#{name} has a satellites.yml row"
    end
  end

  # The app catalog (AppCatalog::PATH) names apps and libraries satellites.yml never lists: the
  # libraries (studio-engine, solana-studio, turf-vault and its alias vault) and
  # apps with no satellite row (acquisition-studio, tax-studio's tax host). A
  # /build app must not take any of them.
  test "[unit] every app catalog app and library name is reserved, with aliases and our subdomains" do
    catalog = YAML.safe_load_file(AppCatalog::PATH)
    library_names = catalog["libraries"].flat_map { |lib| [ lib["slug"], *lib["aliases"] ] }
    assert_includes library_names, "studio-engine"
    assert_includes library_names, "vault"
    app_names = catalog["apps"].map { |app| app["slug"] }
    hosts = catalog["apps"].flat_map { |app| app.values_at("production_url", "qa_url") }.compact
                           .map { |url| URI.parse(url).host }.select { |h| h.end_with?(".mcritchie.studio") }
                           .map { |h| h.delete_suffix(".mcritchie.studio") }
    assert_includes hosts, "tax"
    (library_names + app_names + hosts).select { |name| name.match?(AppRequest::SUBDOMAIN_FORMAT) }.each do |name|
      assert_equal "That name is reserved.", AppRequest.unavailable_reason(name), "#{name} is in the app catalog"
      assert_equal "That name is reserved.", AppRequest.unavailable_reasons([ name ])[name], "#{name} (batch check)"
    end
  end

  # chain-ops' production_url is null until chain.mcritchie.studio exists, so
  # RESERVED holds "chain" by hand.
  test "chain stays reserved for chain-ops' planned host" do
    assert_equal "That name is reserved.", AppRequest.unavailable_reason("chain")
  end

  test "[unit] unavailable_reasons answers every suggestion in one pass, as unavailable_reason would (task build-flow-polish)" do
    draft(user: users(:alex)).queue!("pawsome")
    names = [ "pawsome", "www", "x", "fresh-name", "Fresh Name" ]
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:cached] }
    reasons = ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { AppRequest.unavailable_reasons(names) }
    assert_equal names.index_with { |name| AppRequest.unavailable_reason(name) }, reasons
    assert_equal "That name is taken.", reasons["pawsome"]
    assert_nil reasons["fresh-name"]
    assert_operator queries.size, :<=, 2, "one query for requests and one for apps, however many names"
  end

  test "a claimed name is taken; a cancelled request releases it" do
    first = draft(user: users(:alex)).queue!("pawsome")
    assert_equal "That name is taken.", AppRequest.unavailable_reason("pawsome")

    first.update!(status: "cancelled")
    assert_nil AppRequest.unavailable_reason("pawsome")
  end

  test "queue! claims the name, queues the request and opens a board task, together" do
    request_row = draft(user: users(:alex)).queue!("pawsome")

    assert request_row.queued?
    assert_equal "pawsome.mcritchie.app", request_row.host
    task = Task.find_by!(slug: request_row.task_slug)
    assert_equal "designed", task.stage
    assert_equal "Build Launch App pawsome", task.title
    assert_includes task.metadata.dig("devops", "agent_context"), "A booking site for my groomer"
  end

  # A builder may read nothing but the card. The prompt is a customer's words and
  # never names the house rules, so the card has to: without these two an app
  # passed its card with no footer.
  test "the card requires the site footer and points the builder at the launch SOP" do
    request_row = draft(user: users(:viewer)).queue!("pawsome")
    devops = Task.find_by!(slug: request_row.task_slug).metadata.fetch("devops")

    assert_equal [
      "pawsome.mcritchie.app serves the app the requester described",
      "pawsome.mcritchie.app's home page renders the site footer (footer[data-site-footer])"
    ], devops.fetch("acceptance")
    context = devops.fetch("agent_context")
    assert context.end_with?(
      "\n\nWork this request by docs/agents/modules/launch-build-queue.md. " \
      "Every new app ships the site footer, and legal pages when it holds personal data: " \
      "docs/agents/system/new-app-onboarding-sop.md § 7."
    ), context
  end

  test "the requester's prompt opens the card's context, verbatim, before anything of ours" do
    prompt = "A booking site.\n\nTwo paragraphs, \"quotes\" & <tags> kept as typed"
    request_row = draft(prompt: prompt, user: users(:viewer)).queue!("pawsome")
    context = Task.find_by!(slug: request_row.task_slug).metadata.dig("devops", "agent_context")

    assert context.start_with?("Prompt from the requester, verbatim:\n\n#{prompt}\n\nSubdomain reserved: pawsome.mcritchie.app."), context
    assert_operator context.index(prompt), :<, context.index("launch-build-queue.md")
  end

  test "the card points at docs that exist, and the footer selector is the one the engine emits" do
    AppRequest::BUILDER_POINTER.scan(%r{docs/\S+\.md}).each do |path|
      assert Rails.root.join(path).file?, "#{path} is named on every /build card and must exist"
    end
    assert_equal 2, AppRequest::BUILDER_POINTER.scan(%r{docs/\S+\.md}).size
    footer = File.read(File.join(Gem.loaded_specs.fetch("studio-engine").full_gem_path, "app/views/studio/site_footer/_footer.html.erb"))
    assert_match(/<footer[^>]*\sdata-site-footer[\s>]/, footer)
    assert_equal "footer[data-site-footer]", AppRequest::FOOTER_SELECTOR
  end

  test "the longest name the field accepts still opens a card the board accepts" do
    request_row = draft(user: users(:viewer)).queue!("a" * 30)

    assert_equal 2, Task.find_by!(slug: request_row.task_slug).devops_acceptance.size
  end

  test "a failed claim leaves no task behind" do
    draft(user: users(:alex)).queue!("pawsome")

    assert_no_difference -> { Task.count } do
      assert_raises(ActiveRecord::RecordInvalid) { draft(user: users(:viewer)).queue!("pawsome") }
    end
  end

  # The names are unregistered on purpose: the real showcase builds
  # (prisoners-dilemma, weekly-lock, rantly, portfolio, 10and5, search-position)
  # have satellites.yml rows since register-showcase-apps and
  # register-two-more-showcase-apps, so their subdomains are reserved now.
  test "an admin is exempt from the one-app rule, and their requests are showcase builds" do
    admin = users(:alex)
    assert admin.admin?
    first = draft(user: admin).queue!("coin-toss")
    second = draft(user: admin).queue!("chess-club")

    assert first.showcase? && second.showcase?
    assert_includes Task.find_by!(slug: second.task_slug).metadata.dig("devops", "agent_context"), "SHOWCASE build"
  end

  # A showcase app registered in config/satellites.yml reserves its subdomain the
  # day it is registered, so no new request can claim a name that ships there.
  test "a registered showcase app's subdomain is reserved" do
    %w[prisoners-dilemma weekly-lock rantly portfolio 10and5 search-position].each do |name|
      assert_equal "That name is reserved.", AppRequest.unavailable_reason(name),
                   "#{name} has a satellites.yml row, so its subdomain must not be claimable"
    end
  end

  test "a customer's request is never a showcase" do
    refute draft(user: users(:viewer)).queue!("league-hub").showcase?
  end

  test "a cancelled request frees its name in the database too, not only in the model" do
    first = draft(user: users(:viewer)).queue!("league-hub")
    first.update!(status: "cancelled")

    reclaimed = draft(user: users(:alex)).queue!("league-hub")
    assert reclaimed.queued?, "the holding-only unique index lets a cancelled name be claimed again"
    assert_raises(ActiveRecord::RecordNotUnique) do
      AppRequest.new(prompt: "dup", token: SecureRandom.hex(8), subdomain: "league-hub", status: "queued").save!(validate: false)
    end
  end

  test "a draft belongs to whoever signs in first, then only to them" do
    d = draft
    assert d.claimable_by?(users(:alex))

    d.update!(user: users(:alex))
    assert d.claimable_by?(users(:alex))
    refute d.claimable_by?(users(:viewer))
  end

  test "the gallery finds a live showcase app's screenshot by convention, and nothing when it is missing" do
    live = draft(user: users(:alex)).queue!("zz-no-screenshot")
    live.update!(status: "live")
    entry = BuildGallery.showcased.find { |e| e.url.include?("zz-no-screenshot") }

    assert entry
    assert_nil entry.image, "no file at build_gallery/zz-no-screenshot.webp, so no image"
    assert_nil entry.motion, "nor a loop"
    cyvasse = BuildGallery.configured.find { |e| e.name == "Cyvasse" }
    assert_equal "build_gallery/cyvasse.webp", cyvasse.image
    assert_equal "build_gallery/cyvasse.mp4", cyvasse.motion
  end

  test "each showcase rebuild's live card carries its dark still and its hover loop" do
    %w[prisoners-dilemma weekly-lock rantly portfolio 10and5 search-position].each_with_index do |subdomain, i|
      # These names are reserved satellites, so queue! refuses them; queue a
      # placeholder and give it the real subdomain, as production holds it.
      live = draft(user: users(:alex)).queue!("zz-showcase-#{i}")
      live.update_columns(subdomain: subdomain, status: "live")
      entry = BuildGallery.showcased.find { |e| e.url == "https://#{subdomain}.mcritchie.studio" }

      assert entry, "#{subdomain} is in the gallery"
      assert_equal "build_gallery/#{subdomain}.webp", entry.image, "#{subdomain} has a dark-mode still"
      assert_equal "build_gallery/#{subdomain}.mp4", entry.motion, "#{subdomain} has a hover loop"
    end
  end

  test "the gallery leads with Cyvasse, Turf Monster, Prisoners Dilemma and Rantly, the rest after in their usual order" do
    %w[portfolio rantly weekly-lock prisoners-dilemma].each_with_index do |subdomain, i|
      live = draft(user: users(:alex)).queue!("zz-lead-#{i}")
      live.update_columns(subdomain: subdomain, status: "live", updated_at: i.minutes.ago)
    end
    subdomains = BuildGallery.examples.map { |e| BuildGallery.subdomain(e.url) }

    assert_equal %w[cyvasse turfmonster prisoners-dilemma rantly], subdomains.first(4)
    assert_equal %w[portfolio weekly-lock], subdomains.drop(4) & %w[portfolio weekly-lock], "newest first after the lead"
  end

  test "[unit] Cyvasse and Turf Monster cards link to their own domains, each with its still and loop" do
    cards = BuildGallery.configured.index_by(&:name)

    assert_equal "https://cyvasse.xyz", cards.fetch("Cyvasse").url
    assert_equal "https://turfmonster.media", cards.fetch("Turf Monster").url
    assert_equal "build_gallery/turf-monster.webp", cards.fetch("Turf Monster").image
    assert_equal "build_gallery/turf-monster.mp4", cards.fetch("Turf Monster").motion
    # The card's address is the app's production domain, never the old
    # mcritchie.studio host that only redirects there.
    { "cyvasse" => "Cyvasse", "turf-monster" => "Turf Monster" }.each do |slug, name|
      app = AppCatalog.apps.find { |a| a.slug == slug }
      assert app, "config/apps.yml lists #{slug}"
      assert_equal app.production_url, cards.fetch(name).url, "#{name}'s card matches config/apps.yml"
    end
  end

  # WCAG relative luminance contrast of two #rrggbb colours.
  def contrast(a, b)
    lum = ->(hex) { hex.delete("#").scan(/../).map { |c| v = c.to_i(16) / 255.0; v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
                       .then { |r, g, bl| 0.2126 * r + 0.7152 * g + 0.0722 * bl } }
    hi, lo = [ lum.(a), lum.(b) ].sort.reverse
    (hi + 0.05) / (lo + 0.05)
  end

  test "[unit] every gallery palette is complete and its name and text read at AA on its surface, light and dark" do
    palettes = YAML.safe_load_file(BuildGallery::CONFIG).fetch("palettes")
    assert_operator palettes.size, :>=, 8, "Cyvasse, Turf Monster and the six showcase apps"

    palettes.each_key do |subdomain|
      palette = BuildGallery.palette_for(subdomain)
      assert palette, "#{subdomain}'s palette is complete (#{BuildGallery::PALETTE_KEYS.join(', ')}, light and dark)"
      palette.each do |mode, colours|
        %w[name text].each do |key|
          ratio = contrast(colours.fetch(key), colours.fetch("surface"))
          assert_operator ratio, :>=, 4.5, "#{subdomain} #{mode} #{key} #{colours[key]} on #{colours['surface']} is #{ratio.round(2)}:1"
        end
      end
    end
  end

  test "[unit] a palette reaches the card only whole and only as #rrggbb; no entry keeps the Studio theme" do
    assert_nil BuildGallery.palette_for("no-such-app")
    good = { "surface" => "#ffffff", "primary" => "#123456", "name" => "#000000", "text" => "#333333" }
    config = { "palettes" => {
      "whole" => { "light" => good, "dark" => good },
      "half" => { "light" => good },
      "injected" => { "light" => good, "dark" => good.merge("primary" => "red; background:url(x)") }
    } }
    YAML.stub(:safe_load_file, config) do
      assert_equal({ "light" => good, "dark" => good }, BuildGallery.palette_for("whole"))
      assert_nil BuildGallery.palette_for("half"), "a mode missing"
      assert_nil BuildGallery.palette_for("injected"), "only #rrggbb reaches the inline style"
    end
  end

  test "[unit] configured and showcase cards carry their palettes by subdomain" do
    assert_equal "#C08A2E", BuildGallery.configured.find { |e| e.name == "Cyvasse" }.palette.dig("light", "primary")
    assert_equal "#97BE99", BuildGallery.configured.find { |e| e.name == "Turf Monster" }.palette.dig("dark", "name")
    live = draft(user: users(:alex)).queue!("zz-palette")
    live.update_columns(subdomain: "rantly", status: "live")
    assert_equal "#d63c1f", BuildGallery.showcased.find { |e| e.url.include?("rantly") }.palette.dig("light", "primary")
  end

  test "a showcase card takes its name from the config, else titleizes the subdomain" do
    assert_equal "10&5 Hospitality", BuildGallery.display_name("10and5")
    assert_equal "Weekly Lock", BuildGallery.display_name("weekly-lock")
  end

  test "a customer's live app is never in the public gallery" do
    live = draft(user: users(:viewer)).queue!("customer-app")
    live.update!(status: "live")

    refute BuildGallery.examples.any? { |e| e.url.include?("customer-app") }
  end

  test "[unit] the status card waits for Ray's theme card: a locked idea alone is not a start; the theme card or any later step is" do
    row = AppRequest.create!(prompt: "A league site")
    thread = BuildIntake.thread_key(row.token)
    turn = lambda do |n, card, status: "completed"|
      AgentMessage.create!(channel: "web", external_id: "build:#{row.token}:#{n}", channel_ref: "build", thread_key: thread,
                           soul_slug: "ray", content: "hi", status: status, response_text: "ok", intake_card: card)
    end
    turn.call(1, { "card" => "idea", "title" => "League Standings Hub", "features" => %w[a b] })
    refute row.intake_started?, "an idea card waiting in the thread does not bring the status card"
    refute row.idea_locked?

    row.update!(answers: { "title" => "League Standings Hub", "idea" => "League Standings Hub" })
    assert row.idea_locked?
    refute row.intake_started?, "Start App locks the idea, but the card waits while Ray types the theme card"

    turn.call(2, { "card" => "palette", "palettes" => [] }, status: "received")
    refute row.intake_started?, "a theme card on an answer not yet completed is not shown in the thread"

    other = AppRequest.create!(prompt: "Another site")
    AgentMessage.create!(channel: "web", external_id: "build:#{other.token}:1", channel_ref: "build", thread_key: BuildIntake.thread_key(other.token),
                         soul_slug: "ray", content: "hi", status: "completed", response_text: "ok", intake_card: { "card" => "palette" })
    refute row.intake_started?, "another request's theme card is not this one's"

    turn.call(3, { "card" => "palette", "palettes" => [] })
    assert row.intake_started?, "Ray's theme card is in the thread: the status card appears"

    %w[palette cto address].each do |step|
      fresh = AppRequest.create!(prompt: "An old draft")
      fresh.update_columns(step == "palette" ? { palette: { "name" => "Pitch" } } : step == "cto" ? { cto_name: "Coach", cto_avatar: "harbor" } : { subdomain: "old-draft-#{fresh.id}" })
      assert fresh.intake_started?, "a draft holding #{step} without a theme card still shows what it holds"
    end
  end

  test "the intake fields hold the card rules, and the checklist reads them" do
    palette = { "name" => "Pitch",
                "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
                "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }
    request_row = AppRequest.create!(prompt: "A league site")
    assert_equal({ "idea" => false, "theme" => false, "cto" => false, "address" => false }, request_row.intake_checklist)
    assert_equal "idea", request_row.next_intake_step

    refute request_row.update(cto_name: "R2D2"), "a CTO name is letters"
    refute request_row.reload.update(cto_avatar: "pikachu"), "a portrait is a registry key or an upload ref"
    refute request_row.reload.update(palette: palette.deep_merge("dark" => { "text" => "#1e293b" })), "dark text must read on its surface"
    refute request_row.reload.update(answers: { "idea" => "x", "admin" => true }), "answers take the idea fields only"

    request_row.reload.update!(answers: { "idea" => "A league site" }, cto_name: "Coach", cto_avatar: "harbor",
                               palette: palette, subdomain: "league-hub")
    assert request_row.intake_complete?
    assert_nil request_row.next_intake_step
    request_row.queue!("league-hub")
    context = Task.find_by!(slug: request_row.task_slug).metadata.dig("devops", "agent_context")
    assert_includes context, "CTO: Coach (portrait harbor)"
    assert_includes context, "Palette Pitch: light"
  end

  # The tier's limit from config/workspace_packages.yml, with Vibe capped at `limit`.
  def with_vibe_apps_limit(limit, &)
    config = WorkspacePackage.config
    config["packages"].find { |pkg| pkg["key"] == "vibe" }["apps_per_account"] = limit
    WorkspacePackage.stub(:config, config, &)
  end

  test "[unit] apps per account: a capped tier refuses the account's extra app and names the limit" do
    user = users(:viewer)
    with_vibe_apps_limit(1) do
      draft(user: user).queue!("first-pup")
      second = draft(user: user)
      error = assert_raises(ActiveRecord::RecordInvalid) { second.queue!("second-pup") }
      assert_equal "Your Vibe plan includes 1 app, and you already have one.", second.errors[:base].first
      assert second.errors.added?(:base, :apps_per_account), "the controller reads the detail to offer next steps"
      assert_match(/Vibe plan/, error.message)
    end
    with_vibe_apps_limit(2) do
      assert draft(user: user).queue!("second-pup"), "a cap of 2 takes a second app"
      refute draft(user: user).tap { |r| r.assign_attributes(subdomain: "third-pup", status: "queued") }.valid?
    end
  end

  test "[unit] apps per account: an unlimited tier (Vibe today) and an admin are never capped" do
    user = users(:viewer)
    draft(user: user).queue!("first-pup")
    assert draft(user: user).queue!("second-pup"), "Vibe is unlimited in the data"
    with_vibe_apps_limit(1) do
      admin = users(:alex)
      draft(user: admin).queue!("show-one")
      assert draft(user: admin).queue!("show-two"), "an admin's showcase builds are never capped"
    end
  end
end
