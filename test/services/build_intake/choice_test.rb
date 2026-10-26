require "test_helper"

# [unit] A tap on an intake card (BuildIntake::Choice): it sets the field from
# the stored card or a checked post, AND posts the visitor's turn into the
# request's thread (.agents/epics/build-with-ray-v2.md, 2-5), a line written
# from the saved value, so Alex answers next without the visitor typing. A
# refused tap writes nothing and posts nothing; a double tap posts once; at a
# cap the turn is answered in code.
class BuildIntakeChoiceTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  PALETTE = { "name" => "Pitch",
              "light" => { "primary" => "#15803d", "accent" => "#f59e0b", "surface" => "#ffffff", "text" => "#111827" },
              "dark" => { "primary" => "#4ade80", "accent" => "#fbbf24", "surface" => "#0b1220", "text" => "#f1f5f9" } }.freeze

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    BuildIntake.reset_policy!
    @request = AppRequest.create!(prompt: "A league site with schedules")
  end

  teardown do
    AgentMessages::Answerers.reset!
    BuildIntake.reset_policy!
  end

  def thread = AgentMessage.where(channel: "web", thread_key: BuildIntake.thread_key(@request.token)).order(:id)

  # A completed answer of Alex's on this request's thread, carrying `card`.
  def answer_with(card)
    message = AgentMessage.create!(channel: "web", external_id: "build:#{@request.token}:#{SecureRandom.uuid}", channel_ref: "build",
                                   thread_key: BuildIntake.thread_key(@request.token), soul_slug: "alex", content: "earlier",
                                   status: "completed", response_text: "Here you go.")
    message.update!(intake_card: card)
    message
  end

  def tap(field, **params) = BuildIntake::Choice.new(@request, ip: "203.0.113.9").tap { |c| c.apply!(field, params) }

  test "[unit] the theme is asked before the CTO, and a theme tap with no CTO yet moves the request on to the CTO" do
    assert_equal %w[idea theme cto address], BuildIntake::STEPS
    idea = answer_with({ "card" => "idea", "title" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ] })
    tap("idea", message_id: idea.id)
    assert_equal "theme", @request.reload.next_intake_step, "after the idea, the theme"

    themes = answer_with({ "card" => "palette", "palettes" => [ PALETTE, PALETTE.merge("name" => "Field") ] })
    tap("palette", message_id: themes.id, index: "1")
    assert_equal "Field", @request.reload.palette["name"]
    assert_nil @request.cto_name, "the theme is set with no CTO"
    assert_equal "cto", @request.next_intake_step, "after the theme, the CTO"

    tap("cto", custom_name: "Marble", portrait: "harbor")
    assert_equal "address", @request.reload.next_intake_step
  end

  test "[unit] a draft from the old order (CTO picked, no theme yet) still takes its theme tap and goes on to the domain" do
    @request.update!(answers: { "title" => "League Standings Hub", "idea" => "League Standings Hub" }, cto_name: "Coach", cto_avatar: "meadow")
    assert_equal "theme", @request.next_intake_step

    themes = answer_with({ "card" => "palette", "palettes" => [ PALETTE ] })
    relay = tap("palette", message_id: themes.id, index: "0").relay
    assert_equal "Let's go with the Pitch theme.", relay.content
    @request.reload
    assert_equal [ "Coach", "meadow", "Pitch" ], [ @request.cto_name, @request.cto_avatar, @request.palette["name"] ], "the CTO it picked is kept"
    assert_equal "address", @request.next_intake_step
  end

  test "every field sets its value and relays the visitor's line as a turn Alex will answer" do
    idea = answer_with({ "card" => "idea", "title" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ] })
    themes = answer_with({ "card" => "palette", "palettes" => [ PALETTE ] })

    lines = {
      [ "idea", { message_id: idea.id } ] => "Let's build League Standings Hub.",
      [ "palette", { message_id: themes.id, index: "0" } ] => "Let's go with the Pitch theme.",
      [ "cto", { custom_name: "Marble", portrait: "harbor" } ] => "My CTO is Marble.",
      [ "address", { subdomain: "league-hub" } ] => "Let's use league-hub.mcritchie.app."
    }
    relays = lines.map do |(field, params), line|
      relay = tap(field, **params).relay
      assert_equal line, relay.content, field
      assert_equal %w[received alex chat], [ relay.status, relay.soul_slug, relay.routed_by ], "#{field}: answerable by Alex"
      assert_equal "public", relay.person.role
      relay
    end

    @request.reload
    assert_equal({ "title" => "League Standings Hub", "features" => [ "Live standings", "Schedules" ], "idea" => "League Standings Hub" }, @request.answers)
    assert_equal [ "Marble", "harbor", "Pitch", "league-hub" ], [ @request.cto_name, @request.cto_avatar, @request.palette["name"], @request.subdomain ]
    assert @request.intake_complete?
    assert_equal relays.first, AgentMessage.claimable(soul: "alex").first, "the dispatcher claims the first relayed turn (one per thread at a time)"
    assert_equal 4, thread.where(status: "received").count
  end

  test "Build something else relays without setting anything, and unlocks the idea this card set" do
    idea = answer_with({ "card" => "idea", "title" => "League Standings Hub", "features" => %w[a b] })
    tap("idea", message_id: idea.id)
    assert @request.reload.intake_checklist["idea"]

    relay = tap("idea_else", message_id: idea.id).relay
    assert_equal "I'd like to build something else.", relay.content
    assert_equal({}, @request.reload.answers)

    other = answer_with({ "card" => "idea", "title" => "Fantasy Draft Board", "features" => %w[a b] })
    tap("idea", message_id: other.id)
    tap("idea_else", message_id: idea.id)
    assert_equal "Fantasy Draft Board", @request.reload.answers["title"], "an older card's link leaves a newer idea alone"
  end

  test "a refused tap writes nothing and posts nothing" do
    themes = answer_with({ "card" => "palette", "palettes" => [ PALETTE ] })
    AppRequest.create!(prompt: "taken", subdomain: "taken-name", status: "queued", user: User.create!(email: "t@example.com", name: "T", role: "viewer"))

    refusals = {
      [ "cto", { custom_name: "x", portrait: "harbor" } ] => /2 to 24 letters/,
      [ "cto", { custom_name: "Marble", portrait: "pikachu" } ] => /avatar/,
      [ "cto", { custom_name: "Marble", portrait: "animal:pikachu" } ] => /avatar/,
      [ "palette", { message_id: themes.id, index: "4" } ] => /themes/,
      [ "idea", { message_id: themes.id } ] => /no longer available/,
      [ "address", { subdomain: "taken-name" } ] => /taken|claimed|in use/i,
      [ "theme", {} ] => /Unknown choice/
    }
    assert_no_difference -> { thread.count } do
      refusals.each do |(field, params), reason|
        error = assert_raises(BuildIntake::Choice::Refused, field) { tap(field, **params) }
        assert_match reason, error.message, field
      end
    end
    assert_nil @request.reload.cto_name
    assert_equal({}, @request.palette)
  end

  # The write and the relayed turn commit together: a relay that fails AFTER
  # the field was saved (the save! inside the transaction already ran) takes
  # the saved value back with it, refused or raised.
  test "a failed relay rolls back the saved choice" do
    refusing = Object.new
    refusing.define_singleton_method(:call) { |*_args, **_kw| raise BuildIntake::Ingest::Refused.new("Slow down.", code: "RATE") }
    error = assert_raises(BuildIntake::Choice::Refused) do
      BuildIntake::Choice.new(@request, ingest: refusing).apply!("cto", { custom_name: "Marble", portrait: "harbor" })
    end
    assert_equal "Slow down.", error.message
    assert_equal [ nil, nil ], @request.reload.values_at(:cto_name, :cto_avatar), "the refused relay unsaved the CTO"

    crashing = Object.new
    crashing.define_singleton_method(:call) { |*_args, **_kw| raise ActiveRecord::StatementInvalid, "connection lost" }
    assert_raises(ActiveRecord::StatementInvalid) do
      BuildIntake::Choice.new(@request, ingest: crashing).apply!("address", { subdomain: "league-hub" })
    end
    assert_nil @request.reload.subdomain, "a crashed relay unsaved the domain"
    assert_equal 0, thread.count
  end

  test "a card from another request's thread is refused" do
    other = AppRequest.create!(prompt: "theirs")
    foreign = AgentMessage.create!(channel: "web", external_id: "build:#{other.token}:x", channel_ref: "build", thread_key: BuildIntake.thread_key(other.token),
                                   soul_slug: "alex", content: "x", status: "completed", response_text: "y")
    foreign.update!(intake_card: { "card" => "palette", "palettes" => [ PALETTE ] })
    assert_raises(BuildIntake::Choice::Refused) { tap("palette", message_id: foreign.id, index: "0") }
    assert_equal 0, thread.count
  end

  test "a double tap of one card posts one turn" do
    first = tap("cto", custom_name: "Marble", portrait: "harbor", client_id: "tap-00000001").relay
    again = tap("cto", custom_name: "Marble", portrait: "harbor", client_id: "tap-00000001").relay
    assert_equal first, again
    assert_equal 1, thread.count
  end

  test "[unit] Choose Theme on the theme already chosen posts nothing and spends no turn (task build-flow-polish)" do
    themes = answer_with({ "card" => "palette", "palettes" => [ PALETTE, PALETTE.merge("name" => "Field") ] })
    tap("palette", message_id: themes.id, index: "0")
    turns = thread.count
    saved_at = @request.reload.updated_at

    again = tap("palette", message_id: themes.id, index: "0")
    assert_nil again.relay, "no visitor turn, so Alex is not asked again"
    assert_equal turns, thread.count
    assert_equal saved_at, @request.reload.updated_at, "nothing written"

    changed = tap("palette", message_id: themes.id, index: "1")
    assert_equal "Let's go with the Field theme.", changed.relay.content, "another theme still posts"
    assert_equal turns + 1, thread.count
  end

  test "[unit] Use Domain on the domain already chosen posts nothing; another name does" do
    tap("address", subdomain: "league-hub")
    assert_equal 1, thread.count
    assert_nil tap("address", subdomain: "league-hub").relay
    assert_nil tap("address", subdomain: "League Hub").relay, "the same name however it is typed"
    assert_equal 1, thread.count
    assert_equal "Let's use league-site.mcritchie.app.", tap("address", subdomain: "league-site").relay.content
    assert_equal 2, thread.count
  end

  test "a queued request takes no taps" do
    @request.update_columns(status: "queued")
    assert_raises(BuildIntake::Choice::Refused) { tap("cto", custom_name: "Marble", portrait: "harbor") }
    assert_equal 0, thread.count
  end

  test "past the request cap the relayed turn is answered in code, and the field is still set" do
    BuildIntake.policy = BuildIntake.policy.dup.tap { |p| p.turns_per_request = 1 }
    BuildIntake::Ingest.new(request: @request, ip: "203.0.113.9").call("hello")

    relay = tap("cto", custom_name: "Marble", portrait: "harbor").relay
    assert_equal "completed", relay.status
    assert_equal BuildIntake::Caps::CAP_SUMMARY, relay.action_summary
    assert_includes relay.response_text, "Sign in to continue"
    assert_equal "Marble", @request.reload.cto_name
  end
end
