require "test_helper"

module ReleaseNotes
  class FormatterTest < ActiveSupport::TestCase
    test "formats production release notes grouped by application with production task links" do
      studio_task = tasks(:done_task)
      studio_task.update!(
        title: "Sidebar back-navigation production fix",
        metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } }
      )
      turf_task = tasks(:queued_task)
      turf_task.update!(
        title: "Contest settle button",
        metadata: { "devops" => { "repositories" => ["turf-monster"] } }
      )

      message = Formatter.new(
        app: "mcritchie-studio",
        environment: "production",
        release: "v71",
        sha: "ef693ab1abc",
        url: "https://mcritchie.studio/",
        release_slug: "rel-2026-06-18-devops-tooling",
        checks: ["production /up 200", "/signin 200", "/tasks 200", "web + worker dynos running"],
        tasks: [studio_task, turf_task]
      ).message

      assert_includes message, "🚀 Production deployed: McRitchie Studio v71 (ef693ab)"
      assert_includes message, "https://mcritchie.studio/\n\n🪎 McRitchie Studio"
      assert_includes message, "🪎 McRitchie Studio"
      assert_includes message, "• [Sidebar back-navigation production fix](https://mcritchie.studio/tasks/task-ddd444)"
      assert_includes message, "\n\n🐊 Turf Monster"
      assert_includes message, "• [Contest settle button](https://mcritchie.studio/tasks/task-bbb222)"
      assert_includes message, "💎 Studio Engine\n• No deployed tasks"
      assert_includes message, "\n\nChecks: production /up 200, /signin 200, /tasks 200, web + worker dynos running."
    end

    test "uses selected app group for tasks without repository metadata" do
      task = tasks(:failed_task)
      task.update!(title: "Mainnet vault proof", metadata: {})

      message = Formatter.new(
        app: "turf-vault",
        environment: "production",
        release: "v3",
        sha: "123456789",
        url: "https://turfmonster.media/",
        tasks: [task]
      ).message

      assert_includes message, "🏛️ Vault\n• [Mainnet vault proof](https://mcritchie.studio/tasks/task-eee555)"
    end

    # Mirror of ApplicationHelper::APP_EMOJIS["rolio"] — the two glyph maps are
    # kept in sync by hand, so rolio must carry the same 📇 here for grouping.
    test "APP_GROUPS registers rolio with the 📇 glyph" do
      rolio = Formatter::APP_GROUPS.find { |group| group[:aliases].include?("rolio") }

      assert rolio, "expected an APP_GROUPS entry aliased to rolio"
      assert_equal "📇", rolio[:emoji]
      assert_equal "Rolio", rolio[:label]
    end

    # --- production smoke seal ---------------------------------------------

    test "[unit] a green seal appends the verdict line to the message + Discord header" do
      seal = Release::SmokeSeal.from_result(passed: true, summary: "@qa-readonly green vs prod")
      formatter = formatter_for(seal: seal)

      assert_includes formatter.message, "🟢 Production smoke seal: passed — @qa-readonly green vs prod"
      assert_includes formatter.discord_payload[:content], "🟢 Production smoke seal: passed"
      # The seal line rides AFTER the H1+H3 deploy header (a third content line).
      assert formatter.discord_payload[:content].start_with?("# 🚀 Production Deployment\n### [")
    end

    test "[unit] a red seal surfaces the FAILED verdict" do
      formatter = formatter_for(seal: Release::SmokeSeal.from_result(passed: false, summary: "2 specs failed"))
      assert_includes formatter.message, "🔴 Production smoke seal: FAILED — 2 specs failed"
    end

    test "[unit] no seal → no seal line (back-compat with unsealed releases)" do
      formatter = formatter_for # seal: nil
      assert_not_includes formatter.message, "Production smoke seal"
      assert_not_includes formatter.discord_payload[:content], "Production smoke seal"
    end

    # --- rich embeds -------------------------------------------------------

    # Seed the water-type tint + an Omanyte mascot row so signature_color and the
    # HD avatar thumbnail resolve. Returns the Pokémon.
    def seed_omanyte
      Studio::Enumeral.find_or_create_by!(category: "pokemon_type", key: "water") do |e|
        e.label = "Water"
        e.color = "#6390F0"
        e.position = 2
        e.rank = 100
      end
      Pokemon.find_or_create_by!(dex: 138) do |p|
        p.name = "Omanyte"
        p.slug = "omanyte"
        p.types = ["water"]
        p.generation = 1
        p.avatar_url = "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/138-omanyte.png"
      end
    end

    # A task carrying the Omanyte mascot, mcritchie-studio repo, a $0.87 spine, and
    # a 3:28 PM ship time — the exact shape of the LOCKED reference card.
    def reference_card_task
      seed_omanyte
      task = Task.create!(
        title: "Pin session mascot statusline",
        metadata: { "devops" => { "repositories" => ["mcritchie-studio"], "mascot" => "omanyte" } }
      )
      task.task_events.create!(to_stage: "shipped", occurred_at: Time.current, cost: BigDecimal("0.87"))
      task.update_column(:completed_at, Time.zone.local(2026, 6, 23, 15, 28)) # rubocop:disable Rails/SkipsModelValidations
      task
    end

    def formatter_for(*tasks, **overrides)
      Formatter.new(**{
        app: "mcritchie-studio", environment: "production", release: "v200",
        sha: "abcdef1234567", url: "https://mcritchie.studio/", tasks: tasks
      }.merge(overrides))
    end

    test "task card matches the locked reference shape (clean task, no blocker glyph, no image field)" do
      task = reference_card_task
      embeds = formatter_for(task).embeds
      # Exactly one embed — a task card; NO summary embed leads the array.
      assert_equal 1, embeds.size

      # The exact-hash assertion also locks that the card carries no width-lock
      # `image`/spacer field — only these five keys.
      assert_equal(
        {
          title: "Pin session mascot statusline",
          url: "https://mcritchie.studio/tasks/pin-session-mascot-statusline",
          color: 6_525_168, # 0x6390F0 — Omanyte's water signature color as a Discord int
          description: "🪎   ·   $0.87\nshipped 3:28 PM",
          thumbnail: { url: "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/138-omanyte.png" }
        },
        embeds.first
      )
    end

    test "discord_payload header is the H1 + H3 masked link, and embeds are task cards only" do
      task = tasks(:done_task)
      task.update!(metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
      payload = formatter_for(task, release: "rel-20260626-f2b187", url: "https://mcritchie.studio/").discord_payload

      assert_equal(
        "# 🚀 Production Deployment\n### [rel-20260626-f2b187 🪎](https://mcritchie.studio/)",
        payload[:content]
      )
      assert_equal 1, payload[:embeds].size, "embeds are task cards only — no leading summary embed"
      assert_equal task.title, payload[:embeds].first[:title]
      refute(payload[:embeds].any? { |embed| embed[:title].to_s.include?("deployed") }, "no summary embed is emitted")
    end

    test "header app emojis are DISTINCT across all tasks, in APP_GROUPS order" do
      studio = tasks(:done_task)
      studio.update!(metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
      turf = tasks(:queued_task)
      turf.update!(metadata: { "devops" => { "repositories" => %w[turf-monster mcritchie-studio] } })
      engine = tasks(:new_task)
      engine.update!(metadata: { "devops" => { "repositories" => ["studio-engine"] } })

      content = formatter_for(studio, turf, engine, release: "rel-x").discord_payload[:content]

      # mcritchie-studio appears on two tasks but its 🪎 is deduped, and the glyphs
      # follow APP_GROUPS order: mcritchie-studio 🪎, turf-monster 🐊, studio-engine 💎.
      assert_includes content, "### [rel-x 🪎🐊💎]"
    end

    test "color and thumbnail fall back to neutral grey with no thumbnail when the task has no mascot" do
      task = tasks(:done_task)
      task.update!(metadata: { "devops" => { "repositories" => ["mcritchie-studio"] } })
      embed = formatter_for(task).embeds.last

      assert_equal 0x2B2D31, embed[:color], "no mascot → neutral grey"
      assert_not embed.key?(:thumbnail), "no mascot → thumbnail omitted entirely"
    end

    test "an unknown mascot slug (e.g. a persona name) falls back to neutral, no thumbnail" do
      task = tasks(:done_task)
      task.update!(metadata: { "devops" => { "repositories" => ["mcritchie-studio"], "mascot" => "Jasper" } })
      embed = formatter_for(task).embeds.last

      assert_equal 0x2B2D31, embed[:color]
      assert_not embed.key?(:thumbnail)
    end

    test "description app emojis concatenate one glyph per repo via APP_GROUPS" do
      task = tasks(:done_task)
      task.update!(metadata: { "devops" => { "repositories" => %w[mcritchie-studio turf-monster studio-engine] } })
      line1 = formatter_for(task).embeds.last[:description].split("\n").first

      assert line1.start_with?("🪎🐊💎"), "expected one emoji per repo, concatenated: #{line1.inspect}"
    end

    test "description cost renders as $%.2f, and an em-dash when the task has no cost" do
      priced = tasks(:done_task)
      priced.task_events.create!(to_stage: "shipped", occurred_at: Time.current, cost: BigDecimal("12.5"))
      assert_includes formatter_for(priced).embeds.last[:description], "$12.50"

      free = tasks(:queued_task)
      assert_includes formatter_for(free).embeds.last[:description], "—", "a zero-cost task shows an em-dash"
    end

    test "blocker glyph: a clean task shows NOTHING, a blocked task appends ' · ⚠️'" do
      clear = tasks(:queued_task) # no blocked_at
      clear_line1 = formatter_for(clear).embeds.first[:description].split("\n").first
      refute_includes clear_line1, "⚠️", "a clean task ends after the cost — no blocker glyph"
      refute_includes clear_line1, "✅", "the old check glyph is gone"
      refute_includes clear_line1, "❌", "the old cross glyph is gone"

      # A block is a `building` attribute now, cleared on advance — so the durable
      # "was ever blocked" signal for a shipped/release task is the qa_feedback
      # marker (#ever_blocked?), not the (now-transient) blocked_at column.
      blocked = tasks(:failed_task)
      Activity.create!(task_slug: blocked.slug, activity_type: "qa_feedback", description: "hit a block")
      blocked_line1 = formatter_for(blocked).embeds.first[:description].split("\n").first
      assert blocked_line1.end_with?("   ·   ⚠️"), "a blocked task appends the warning: #{blocked_line1.inspect}"
    end

    test "the shipped line is included with completed_at and skipped without it" do
      shipped = tasks(:done_task) # fixture completed_at 2026-04-01 12:00:00 → 12:00 PM
      assert_includes formatter_for(shipped).embeds.last[:description], "\nshipped 12:00 PM"

      unshipped = tasks(:queued_task) # no completed_at
      refute_includes formatter_for(unshipped).embeds.last[:description], "shipped"
    end

    test "discord_payload sends task-card embeds within the 9-card cap and falls back to text beyond it" do
      task = tasks(:done_task)

      nine = formatter_for(*Array.new(9) { task })
      assert nine.embeddable?
      payload = nine.discord_payload
      assert_equal 9, payload[:embeds].size, "task cards only — no summary embed prepended"
      assert payload[:content].start_with?("# 🚀 Production Deployment"), "the deploy header rides in content"

      ten = formatter_for(*Array.new(10) { task })
      refute ten.embeddable?
      fallback = ten.discord_payload
      assert_equal ten.message, fallback[:content], "an over-cap release falls back to the plain-text message"
      refute fallback.key?(:embeds), "the text fallback prepends no embeds"
    end

    # --- epic grouping ------------------------------------------------------

    def epic_task(title, repo, epic)
      Task.create!(title: title, epic_slug: epic, metadata: { "devops" => { "repositories" => [repo] } })
    end

    test "[integration] each app group nests its tasks under their epic, loose tasks first" do
      loose = epic_task("Loose studio fix task", "mcritchie-studio", nil)
      epic_a = epic_task("Epic index page task", "mcritchie-studio", "devops-v3")
      polish = epic_task("Board polish sweep task", "mcritchie-studio", "board-polish")
      epic_b = epic_task("Epic release notes task", "mcritchie-studio", "devops-v3")
      turf = epic_task("Turf epic contest task", "turf-monster", "devops-v3")

      message = formatter_for(epic_a, loose, polish, epic_b, turf).message

      studio = message[/🪎 McRitchie Studio\n(.*?)\n\n/m, 1]
      assert_equal [
        "• [Loose studio fix task](https://mcritchie.studio/tasks/#{loose.slug})",
        "🧩 devops-v3",
        "  • [Epic index page task](https://mcritchie.studio/tasks/#{epic_a.slug})",
        "  • [Epic release notes task](https://mcritchie.studio/tasks/#{epic_b.slug})",
        "🧩 board-polish",
        "  • [Board polish sweep task](https://mcritchie.studio/tasks/#{polish.slug})"
      ], studio.split("\n")
      assert_includes message, "🐊 Turf Monster\n🧩 devops-v3\n  • [Turf epic contest task]",
                      "the app stays the outer level; the epic nests inside each app"
    end

    test "[unit] a release with no epics renders its bullets flat, as before" do
      task = epic_task("Plain flat bullet task", "mcritchie-studio", nil)
      message = formatter_for(task).message

      assert_includes message, "🪎 McRitchie Studio\n• [Plain flat bullet task]"
      assert_not_includes message, "🧩"
      assert_not_includes formatter_for(task).discord_payload[:content], "🧩"
    end

    test "[unit] the Discord header lists the epics and each card names its epic, grouped together" do
      first = epic_task("Epic card first task", "mcritchie-studio", "devops-v3")
      loose = epic_task("Loose card middle task", "mcritchie-studio", nil)
      second = epic_task("Epic card second task", "mcritchie-studio", "devops-v3")
      formatter = formatter_for(first, loose, second)

      assert_equal ["devops-v3"], formatter.epic_slugs
      assert_includes formatter.discord_payload[:content], "\n🧩 devops-v3"
      assert_equal [first.title, second.title, loose.title], formatter.embeds.map { |embed| embed[:title] },
                   "an epic's cards sit together at its first card's place"
      assert_equal({ text: "🧩 devops-v3" }, formatter.embeds.first[:footer])
      assert_nil formatter.embeds.last[:footer], "a loose card wears no footer"
    end

    # rel-20260925-3b1f5c, faithfully: its 27 tasks (slug, title, repo) as read from
    # production. Over the 9-card cap, so the payload is the plain-text layout — a
    # 2790-character `content` that Discord refused (limit 2000). No task carried an
    # epic, so the epic grouping was not the cause.
    REL_20260925_TASKS = [
      ["delete-last-review-guards", "Delete Last Review Guards", "mcritchie-studio"],
      ["cut-release-and-desk-pages", "Cut Release And Desk Pages", "mcritchie-studio"],
      ["derivation-404s-and-list-totals", "Derivation 404s And List Totals", "mcritchie-studio"],
      ["capability-pages-under-three-hundred", "Capability Pages Under Three Hundred", "mcritchie-studio"],
      ["epic-view-and-notes", "Epic View And Notes", "mcritchie-studio"],
      ["desk-is-the-build-claim", "Desk Is The Build Claim", "mcritchie-studio"],
      ["auto-grade-at-ship", "Auto Grade At Ship", "mcritchie-studio"],
      ["harden-derived-fact-reads", "Harden Derived Fact Reads", "mcritchie-studio"],
      ["agents-map-two-hundred-lines", "AGENTS Map Two Hundred Lines", "mcritchie-studio"],
      ["derive-merge-rung-and-authors", "Derive Merge Rung And Authors", "mcritchie-studio"],
      ["scope-ship-grant-to-request", "Scope Ship Grant To Request", "mcritchie-studio"],
      ["retire-local-cert-evidence", "Retire Local Cert Evidence", "mcritchie-studio"],
      ["operator-windows-on-board", "Operator Windows On Board", "mcritchie-studio"],
      ["ship-gate-reads-tree-verdict", "Ship Gate Reads Tree Verdict", "mcritchie-studio"],
      ["roster-misses-pokemon-and-xan", "Roster Misses Pokemon And Xan", "mcritchie-studio"],
      ["soul-character-reference-lane", "Soul Character Reference Lane", "mcritchie-studio"],
      ["data-flow-doc-contradicts-code", "Data Flow Doc Contradicts Code", "mcritchie-studio"],
      ["sync-reports-its-refusals", "Sync Reports Its Refusals", "turf-monster"],
      ["epic-slug-on-task-cards", "Epic Slug On Task Cards", "mcritchie-studio"],
      ["dor-reads-settled-ci-verdict", "DoR Reads Settled CI Verdict", "mcritchie-studio"],
      ["harden-drafting-mailbox-lane", "Harden Drafting Mailbox Lane", "mcritchie-studio"],
      ["rename-alex-agent-to-xan", "Rename Alex Agent To Xan", "mcritchie-studio"],
      ["packages-polish-and-hosting", "Packages Polish And Hosting", "mcritchie-studio"],
      ["focus-session-build-sop", "Focus Session Build SOP", "mcritchie-studio"],
      ["workspace-launch-and-packages", "Workspace Launch And Packages", "mcritchie-studio"],
      ["land-devops-v3-design", "Land DevOps V3 Design", "mcritchie-studio"],
      ["document-studio-turf-data-flow", "Document Studio Turf Data Flow", "mcritchie-studio"],
    ].freeze

    test "[unit] the 27-task release that Discord refused now splits into messages that each fit" do
      tasks = REL_20260925_TASKS.map do |slug, title, repo|
        Task.new(slug: slug, title: title, metadata: { "devops" => { "repositories" => [repo] } })
      end
      formatter = Formatter.new(app: "mcritchie-studio", environment: "production", release: "rel-20260925-3b1f5c",
                                sha: "6d1522a9abed3dd0499d282d06a9b132d22ac51e", url: "https://mcritchie.studio",
                                tasks: tasks)
      payload = formatter.discord_payload

      assert_not formatter.embeddable?
      assert_operator DiscordClient.discord_length(payload[:content]), :>, DiscordClient::CONTENT_LIMIT,
                      "the reproduction: one message breaks Discord's content cap"

      bodies = DiscordClient.messages(**payload)
      assert_equal 2, bodies.size
      bodies.each { |body| assert_operator DiscordClient.discord_length(body[:content]), :<=, DiscordClient::CONTENT_LIMIT }
      REL_20260925_TASKS.each do |slug, _title, _repo|
        assert_equal 1, bodies.count { |body| body[:content].include?("/tasks/#{slug})") }, "#{slug} posts exactly once"
      end
    end
  end
end
