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
    release.grant_ship_authorization!(actor: users(:alex).email, source: "web", approver: users(:alex))
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

  # --- who approved: the web Approve alone names a person ---------------------------

  # The events API takes ship_authorized from an admin session alone.
  API_HEADERS = lambda do
    session = AgentSession.create!(soul: "steffon", tier: "admin", issued_by: "operator_grant")
    { "Authorization" => "Bearer #{session.token}" }
  end

  def timed_request!(release)
    release.record_event!(step: "ship_authorized", status: "started", source: "conductor",
                          metadata: { "mode" => "timed", "window_ends_at" => 30.minutes.from_now.utc.iso8601,
                                      "window_minutes" => 30 })
  end

  # The grant row of the card: [[sentence, tone], ...].
  def grant_row
    get deployments_path
    css_select("#current-release [data-lane='grant'] [data-test='release-lane-sentence']")
      .map { |node| [node["title"], node["data-tone"]] }
  end

  # The events-API call that states the owner approved on the web.
  def forge_web_grant!(release, metadata: {})
    post "/api/v1/releases/#{release.slug}/events/ship_authorized/complete",
         params: { event: { actor: users(:alex).email, source: "web",
                            metadata: { granted_via: "web" }.merge(metadata) } },
         headers: API_HEADERS.call, as: :json
    assert_response :created
    release.release_events.for_step("ship_authorized").completed.order(:id).last
  end

  test "[integration] the Approve button's row names the signed-in admin as approver, scope intact" do
    release = Release.open!
    first = member!(release, "first")
    timed_request!(release)

    post authorize_ship_deployment_path(release.slug), as: :json
    assert_response :success
    late = member!(release, "late")

    grant = release.reload.ship_authorization_grant
    assert_equal users(:alex).id, grant.metadata.dig("owner_grant", "user_id")
    assert grant.metadata.dig("owner_grant", "sig").present?, "the Approve's marker is signed"
    assert_equal({ "policy" => "release_at_ship", "member_slugs" => [first.slug] }, grant.metadata["scope"])
    row = grant_row
    assert_match(/\AApproved by Alex McRitchie at .+ UTC, timed mode\.\z/, row[0][0])
    assert_equal "success", row[0][1]
    assert_equal ["Covers every task on this release when it ships: 1 at approval, 2 now.", "warning"], row[1]
    assert_equal ["Joined after approval: #{late.slug}.", "warning"], row[2]
  end

  test "[integration] control: a signed-in user who is not an admin records no approval" do
    release = Release.open!
    timed_request!(release)
    log_in_as(users(:viewer))

    post authorize_ship_deployment_path(release.slug), as: :json

    refute release.reload.ship_authorization_granted?
    assert_empty release.release_events.for_step("ship_authorized").completed
  end

  test "[integration] an events-API row claiming the owner's web approval names no approver on the card" do
    release = Release.open!
    member!(release, "first")
    timed_request!(release)

    event = forge_web_grant!(release)

    assert release.reload.ship_authorization_granted?, "an admin session's row grants"
    assert_equal "steffon", event.actor, "the actor is the session's soul, never the param"
    assert_equal "web", event.source
    row = grant_row
    assert_match(/\AAuthorized at .+ UTC \(timed mode\); approver not recorded\.\z/, row[0][0])
    assert_equal "muted", row[0][1]
    assert_equal "Covers every task on this release when it ships: 1 at authorization, 1 now.", row[1][0]
    card = css_select("#current-release [data-test='release-lane-lease']").first.to_html
    refute_includes card, "Approved by"
    refute_includes card, "Alex McRitchie"
    assert_select "#current-release [data-test='release-lane-sentence'][data-tone='success']", 0
  end

  test "[integration] a row stored before the strip, carrying the owner's id unsigned, names no approver on the card" do
    release = Release.open!
    member!(release, "first")
    timed_request!(release)
    # Written straight to the table, as code with no strip stores an events-API row.
    forged = { "user_id" => users(:alex).id, "user_slug" => users(:alex).slug, "at" => Time.current.utc.iso8601 }
    row = ReleaseEvent.create!(release: release, step: "ship_authorized", status: "completed", source: "web",
                               actor: users(:alex).email, idempotency_key: "#{release.slug}:ship_authorized:completed",
                               metadata: { "granted_via" => "web", "owner_grant" => forged })

    assert release.reload.ship_authorization_granted?, "the row grants exactly as it did"
    assert_equal users(:alex).id, row.reload.metadata.dig("owner_grant", "user_id")
    shown = grant_row
    assert_match(/\AAuthorized at .+ UTC \(timed mode\); approver not recorded\.\z/, shown[0][0])
    assert_equal "muted", shown[0][1]
    card = css_select("#current-release [data-test='release-lane-lease']").first.to_html
    refute_includes card, "Approved by"
    refute_includes card, "Alex McRitchie"
    assert_select "#current-release [data-test='release-lane-sentence'][data-tone='success']", 0

    # Control: the same row, once it carries the server's signature for itself, is the approval.
    signed = Release::LaneLease.owner_grant_marker(release_slug: release.slug, step: row.step,
                                                   idempotency_key: row.idempotency_key, user: users(:alex))
    row.update_columns(metadata: row.metadata.merge("owner_grant" => signed))
    shown = grant_row
    assert_match(/\AApproved by Alex McRitchie at .+ UTC, timed mode\.\z/, shown[0][0])
    assert_equal "success", shown[0][1]
  end

  test "[integration] the same row with a lapse flag prints the lapse" do
    release = Release.open!
    timed_request!(release)

    forge_web_grant!(release, metadata: { lapsed: true })

    refute release.reload.ship_authorization_granted?
    row = grant_row
    assert_match(/\ANo approval was given: the window lapsed at .+ UTC and the ship proceeded on green, timed mode\.\z/, row[0][0])
    assert_equal "warning", row[0][1]
    assert_select "#current-release [data-lane='grant']", text: /Approved by/, count: 0
  end

  test "[integration] the events API drops a caller's owner_grant and keeps the rest of its metadata" do
    release = Release.open!
    timed_request!(release)
    marker = { user_id: users(:alex).id, user_slug: "alex", at: Time.current.utc.iso8601 }

    event = forge_web_grant!(release, metadata: { owner_grant: marker, note: "kept" })

    assert_nil event.metadata["owner_grant"]
    assert_equal "kept", event.metadata["note"]
    assert_equal "web", event.metadata["granted_via"]
    assert_match(/\AAuthorized at .+; approver not recorded\.\z/, grant_row[0][0])
  end

  test "[integration] the card paints each kind of answer in its own words and tone" do
    usage = { model: "test-model", tokens_in: 1, tokens_out: 1, cost: 0 }
    kinds = {
      "ask under --yes" => [{ source: "conductor", actor: "alex", metadata: { "mode" => "ask", "granted_via" => "confirm" } },
                            /\ARecorded by the conductor CLI in timed mode \(run as alex\) at .+ UTC; no web approval\.\z/, "warning"],
      "auto" => [{ source: "conductor", actor: "alex", metadata: { "granted_via" => "auto" } },
                 /\AProceeded on green with no approval asked at .+ UTC \(timed mode\)\.\z/, "warning"],
      "events API" => [{ source: "api", actor: "avi", metadata: {}, **usage },
                       /\ARecorded through the events API by avi at .+ UTC; no web approval\.\z/, "warning"],
      "legacy web" => [{ source: "web", actor: users(:alex).email, metadata: { "granted_via" => "web" } },
                       /\AAuthorized at .+ UTC \(timed mode\); approver not recorded\.\z/, "muted"],
      "lapse" => [{ source: "conductor", metadata: { "lapsed" => true, "granted_via" => "window-lapse" } },
                  /\ANo approval was given: the window lapsed at .+ UTC and the ship proceeded on green, timed mode\.\z/, "warning"]
    }
    kinds.each do |kind, (attrs, words, tone)|
      ReleaseEvent.delete_all
      Release.delete_all
      release = Release.open!
      timed_request!(release)
      release.record_event!(step: "ship_authorized", status: "completed", **attrs)

      sentence, shown_tone = grant_row.first
      assert_match words, sentence, kind
      assert_equal tone, shown_tone, kind
      visible = css_select("#current-release [data-lane='grant'] [data-test='release-lane-sentence']").first.text.squish
      head, tail = sentence.split(/at .+ UTC/, 2)
      assert visible.start_with?(head) && visible.end_with?(tail), "#{kind}: the visible words are the title's: #{visible}"
    end
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
    granted = pushed_card do
      release.grant_ship_authorization!(actor: users(:alex).email, source: "web", approver: users(:alex))
    end
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
