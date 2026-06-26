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
        release_train: "2026-06-18-devops-tooling",
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

      blocked = tasks(:failed_task) # fixture carries blocked_at
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
  end
end
