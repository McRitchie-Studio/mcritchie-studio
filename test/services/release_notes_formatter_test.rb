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

    test "task embed matches the locked reference card exactly" do
      task = reference_card_task
      embed = formatter_for(task).embeds.last

      assert_equal(
        {
          title: "Pin session mascot statusline",
          url: "https://mcritchie.studio/tasks/pin-session-mascot-statusline",
          color: 6_525_168, # 0x6390F0 — Omanyte's water signature color as a Discord int
          description: "🪎   ·   $0.87   ·   ✅\nshipped 3:28 PM",
          thumbnail: { url: "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/138-omanyte.png" }
        },
        embed
      )
    end

    test "summary embed leads the array, green, with the headline title and production url" do
      embeds = formatter_for(tasks(:done_task)).embeds
      summary = embeds.first

      assert_equal 0x57F287, summary[:color]
      assert_equal "🚀 Production deployed: McRitchie Studio v200 (abcdef1)", summary[:title]
      assert_equal "https://mcritchie.studio/", summary[:url]
      assert_equal tasks(:done_task).title, embeds.last[:title], "task cards follow the summary"
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

    test "description blocker glyph is ❌ when blocked_at is set, ✅ otherwise" do
      blocked = tasks(:failed_task) # fixture carries blocked_at
      assert_includes formatter_for(blocked).embeds.last[:description].split("\n").first, "❌"

      clear = tasks(:queued_task)
      assert_includes formatter_for(clear).embeds.last[:description].split("\n").first, "✅"
    end

    test "the shipped line is included with completed_at and skipped without it" do
      shipped = tasks(:done_task) # fixture completed_at 2026-04-01 12:00:00 → 12:00 PM
      assert_includes formatter_for(shipped).embeds.last[:description], "\nshipped 12:00 PM"

      unshipped = tasks(:queued_task) # no completed_at
      refute_includes formatter_for(unshipped).embeds.last[:description], "shipped"
    end

    test "discord_payload sends embeds within the 9-card cap and falls back to text beyond it" do
      task = tasks(:done_task)

      nine = formatter_for(*Array.new(9) { task })
      assert nine.embeddable?
      assert nine.discord_payload.key?(:embeds)
      assert_equal 10, nine.discord_payload[:embeds].size, "summary + 9 cards = Discord's 10-embed max"

      ten = formatter_for(*Array.new(10) { task })
      refute ten.embeddable?
      assert ten.discord_payload.key?(:content), "an over-cap release falls back to the plain-text message"
      assert_equal ten.message, ten.discord_payload[:content]
    end
  end
end
