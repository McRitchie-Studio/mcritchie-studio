# frozen_string_literal: true

require "test_helper"

# [integration] The release lane on /deployments: the Next Release card names who
# is assembling and who is shipping, and states what the production grant covers,
# in the sentences `bin/release status` prints (Release::LaneLease). The same block
# renders on the live push, with nothing that depends on the viewer.
class DeploymentsLaneLeaseTest < ActionDispatch::IntegrationTest
  setup { log_in_as(users(:alex)) }

  setup do
    Release.delete_all
    ReleaseConductorClaim.delete_all
    SessionMascot.delete_all
    Pokemon.create!(dex: 303, name: "Mawile", slug: "mawile", types: %w[steel],
                    generation: 3, sprite_url: "https://img.test/mawile.png")
  end

  def member!(release, label)
    task = Task.create!(title: "lane card #{label} member task", stage: "reviewed")
    release.add(task)
    task
  end

  # The sentences a card shows, as the text the CLI prints (each sentence's title).
  def card_sentences(scope, lane: nil)
    selector = "#{scope} [data-test='release-lane-row']#{"[data-lane='#{lane}']" if lane} [data-test='release-lane-sentence']"
    css_select(selector).map { |node| node["title"] }
  end

  def populate!(release)
    first = member!(release, "first")
    SessionMascot.create!(session_id: "sess-assembler-9b57", mascot_slug: "mawile")
    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "assembler", session: "sess-assembler-9b57",
                                  nonce: "nonce-secret-a", soul: "steffon")
    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "deployer", session: "sess-deployer-41cd",
                                  nonce: "nonce-secret-d", label: "Onix")
    release.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                          metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601,
                                      "window_minutes" => 30 })
    release.grant_ship_authorization!(actor: users(:alex).email, source: "web")
    [first, member!(release, "late")]
  end

  test "[integration] empty state: the card says nobody holds either role and no approval was asked for" do
    release = Release.open!

    get deployments_path
    assert_response :success

    assert_select "#current-release [data-test='release-lane-lease']", 1
    assert_equal ["Nobody is assembling #{release.slug}."], card_sentences("#current-release", lane: "assembler")
    assert_equal ["Nobody is shipping #{release.slug}."], card_sentences("#current-release", lane: "deployer")
    assert_equal ["No production approval has been asked for."], card_sentences("#current-release", lane: "grant")
    assert_select "#current-release [data-test='release-lane-sentence'][data-tone='muted']", 3
  end

  test "[integration] populated: the card shows the assembler, the deployer and the grant scope" do
    release = Release.open!
    _first, late = populate!(release)

    get deployments_path
    assert_response :success

    assembler = card_sentences("#current-release", lane: "assembler")
    deployer = card_sentences("#current-release", lane: "deployer")
    grant = card_sentences("#current-release", lane: "grant")

    assert_match(/\AMawile \(steffon, session …9b57\) is assembling #{release.slug} since .+ UTC\.\z/, assembler.sole)
    assert_match(/\AOnix \(session …41cd\) is shipping #{release.slug} since .+ UTC\.\z/, deployer.sole)
    assert_match(/\AApproved by Alex McRitchie at .+ UTC, timed mode\.\z/, grant[0])
    assert_equal "Covers every task on this release when it ships: 1 at approval, 2 now.", grant[1]
    assert_equal "Joined after approval: #{late.slug}.", grant[2]

    # The visible words are the same sentence, with the reader's clock in each time slot.
    visible = css_select("#current-release [data-lane='grant'] [data-test='release-lane-sentence']").map { |n| n.text.squish }
    assert_match(/\AApproved by Alex McRitchie at .+, timed mode\.\z/, visible[0])
    assert_equal grant[1], visible[1]
    assert_select "#current-release [data-lane='grant'] [data-test='release-lane-sentence'] time[data-at-stamp]", 1
    assert_select "#current-release [data-lane='assembler'] time[data-at-prefix='since']", 1
  end

  test "[integration] the card is what `bin/release status` prints, sentence for sentence" do
    release = Release.open!
    populate!(release)

    get deployments_path

    assert_equal Release::LaneLease.status_lines(release.reload), card_sentences("#current-release")
  end

  test "[integration] the card never carries a whole session id or a nonce" do
    release = Release.open!
    populate!(release)

    get deployments_path

    card = css_select("#current-release").first.to_html
    %w[sess-assembler-9b57 sess-deployer-41cd nonce-secret-a nonce-secret-d].each do |secret|
      refute_includes card, secret
    end
    assert_includes card, "session …9b57"
  end

  test "[integration] a grant recorded without a member set renders as not recorded" do
    release = Release.open!
    member!(release, "first")
    release.record_event!(step: "ship_authorized", status: "started", source: "conductor", metadata: { "mode" => "ask" })
    grant = release.record_event!(step: "ship_authorized", status: "completed", source: "conductor", actor: "steffon",
                                  metadata: { "mode" => "ask", "granted_via" => "confirm" })
    grant.update_columns(metadata: grant.metadata.except("scope"))

    get deployments_path

    assert_includes card_sentences("#current-release", lane: "grant"),
                    "Covers every task on this release when it ships: member set at authorization not recorded, 1 now."
  end

  test "[integration] the Last Release card keeps the grant and drops the holders" do
    release = Release.open!
    populate!(release)
    release.update_columns(state: "shipped", shipped_at: Time.current)

    get deployments_path

    assert_select "#last-release [data-test='release-lane-row'][data-lane='assembler']", 0
    assert_select "#last-release [data-test='release-lane-row'][data-lane='deployer']", 0
    assert_includes card_sentences("#last-release", lane: "grant"),
                    "Covered every task on this release when it shipped: 1 at approval, 2 at ship."
  end

  test "[integration] with no release, a prepare forming the next one is named on the empty card" do
    get deployments_path
    assert_select "#current-release", text: /Merge a reviewed task/

    ReleaseConductorClaim.acquire(release_slug: ReleaseConductorClaim::FORMING_SLUG, role: "assembler",
                                  session: "sess-forming-77aa", nonce: "n", label: "Onix")
    get deployments_path

    assert_select "#current-release", text: /Onix \(session …77aa\) is assembling the next release since/
  end

  # --- a second session stands down with the holder named -----------------------------

  # The claim CLI's board seam, pointed at this app: its HTTP calls run through the
  # integration session, so the real endpoint answers the real CLI.
  class BoardThroughTest
    Resp = Struct.new(:code, :body)

    def initialize(test, projects_dir)
      @test = test
      @projects_dir = projects_dir
    end

    attr_reader :projects_dir

    def token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    def env = { "CLAUDE_PROJECTS_DIR" => @projects_dir }
    def invalidate_token!(*) = nil
    def present?(value) = value.to_s.strip.present?

    def http_json(method, path, body = nil, bearer: nil, **)
      @test.public_send(method, path, params: body, headers: { "Authorization" => "Bearer #{bearer}" }, as: :json)
      Resp.new(@test.response.status, @test.response.body)
    end
  end

  test "[integration] a second session's prepare claim stands down and prints the sentence the card shows" do
    require Rails.root.join("bin/lib/release_claim_cli").to_s
    release = Release.open!
    SessionMascot.create!(session_id: "sess-first-holder-9b57", mascot_slug: "mawile")
    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "assembler", session: "sess-first-holder-9b57",
                                  nonce: "nonce-first", soul: "steffon")

    out = StringIO.new
    code = Dir.mktmpdir do |projects|
      cli = ReleaseClaimCli.new(env: { "RELEASE_CONDUCTOR_CLAIM_SESSION" => "sess-second-41cd", "TASK_CLAIM_NONCE" => "nonce-second" },
                                out: out, err: StringIO.new)
      cli.instance_variable_set(:@api, BoardThroughTest.new(self, projects))
      cli.run(["acquire", release.slug, "--role", "assembler"])
    end
    printed = out.string.lines.map(&:strip)

    assert_equal ReleaseClaimCli::STOOD_DOWN, code, "the second session does not get the claim"
    assert_equal "sess-first-holder-9b57", ReleaseConductorClaim.find_by(release_slug: release.slug, role: "assembler").claimed_session
    get deployments_path
    card = card_sentences("#current-release", lane: "assembler").sole
    assert_match(/\AMawile \(steffon, session …9b57\) is assembling #{release.slug} since/, card)
    assert_includes printed, card, "the stand-down prints the card's sentence verbatim:\n#{out.string}"
    refute_includes out.string, "sess-first-holder"
  end

  # --- the live push ----------------------------------------------------------------

  def pushed_card(&block)
    streams = capture_turbo_stream_broadcasts("deployments", &block)
    streams.select { |stream| stream["target"] == "current-release" }.map(&:to_html).join
  end

  test "[integration] a claim taken, a claim released and a grant recorded each push the lane to an open board" do
    release = Release.open!
    member!(release, "first")

    taken = pushed_card do
      ReleaseConductorClaim.acquire(release_slug: release.slug, role: "assembler", session: "sess-assembler-9b57",
                                    nonce: "nonce-secret-a", label: "Onix")
    end
    assert_includes taken, "Onix (session …9b57) is assembling #{release.slug}"

    released = pushed_card do
      ReleaseConductorClaim.release(release_slug: release.slug, role: "assembler", session: "sess-assembler-9b57",
                                    nonce: "nonce-secret-a")
    end
    assert_includes released, "Nobody is assembling #{release.slug}."

    release.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                          metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601,
                                      "window_minutes" => 30 })
    granted = pushed_card { release.grant_ship_authorization!(actor: users(:alex).email, source: "web") }
    assert_includes granted, "Approved by Alex McRitchie"
    assert_includes granted, "Covers every task on this release when it ships: 1 at approval, 1 now."
  end

  test "[integration] the pushed card names no host and nothing of the viewer" do
    release = Release.open!
    populate!(release)

    html = pushed_card { DeploymentsBroadcaster.release_modules(slots: [:current]) }

    assert_includes html, "data-test=\"release-lane-lease\""
    refute_includes html, "example.org"
    refute_match(%r{https?://(localhost|www\.example|127\.0\.0\.1)}, html)
    refute_includes html, users(:alex).email
    %w[sess-assembler-9b57 sess-deployer-41cd nonce-secret-a nonce-secret-d].each { |secret| refute_includes html, secret }
  end

  test "[integration] the pushed lane is the page's lane" do
    release = Release.open!
    populate!(release)

    get deployments_path
    page = card_sentences("#current-release")
    html = pushed_card { DeploymentsBroadcaster.release_modules(slots: [:current]) }
    pushed = Nokogiri::HTML5.fragment(html).css("template").first.inner_html
    pushed_titles = Nokogiri::HTML5.fragment(pushed).css("[data-test='release-lane-sentence']").map { |n| n["title"] }

    assert_equal page, pushed_titles
  end

  test "[integration] the card signature moves when the lane does, and holds when it does not" do
    release = Release.open!
    helper = ApplicationController.helpers
    before = helper.release_card_signature(release)
    assert_equal before, helper.release_card_signature(release.reload), "control: an unchanged lane is an unchanged signature"

    ReleaseConductorClaim.acquire(release_slug: release.slug, role: "deployer", session: "sess-deployer-41cd", nonce: "n")
    claimed = helper.release_card_signature(release.reload)
    refute_equal before, claimed
    refute_includes claimed, "41cd", "the signature is a digest; it carries no holder detail"
  end
end
