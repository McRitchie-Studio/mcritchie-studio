require "test_helper"

# [unit] The staged email queue (task staged-email-queue): Broadcast#stage!
# renders and holds each reader's email without sending, approve and execute
# move it on, and the send job delivers exactly the stored snapshot, once,
# within the daily cap and the reputation gate.
class StagedEmailTest < ActiveJob::TestCase
  include ActionMailer::TestHelper

  STATS = {
    "ann@example.com" => { "username" => "Ann", "games" => 42, "wins" => 30, "losses" => 12 },
    "bob@example.com" => { "username" => "Bob", "games" => 7 }
  }.freeze

  setup do
    ActionMailer::Base.deliveries.clear # this case is not an ActionMailer::TestCase, so nothing else clears it
    @broadcast = Broadcast.create!(slug: "your-games", template_key: "cyvasse_your_games", target_list: "cyvasse-legacy",
                                   subject: "%{username}, your %{games} Cyvasse games are still here")
    @ann = listed("ann@example.com")
    @bob = listed("bob@example.com")
    @nameless = listed("nameless@example.com") # no Cyvasse stats
  end

  # A verified-valid contact on the list (cyvasse-legacy is verified-only),
  # carrying its Cyvasse stats in contacts.traits when STATS names it.
  def listed(email, **attrs)
    traits = STATS.key?(email) ? { "cyvasse" => STATS[email] } : {}
    Contact.create!(email: email, tags: [ "cyvasse-legacy" ], traits: traits, **attrs)
           .tap { _1.record_verification!(status: "valid") }
  end

  def stage!(**) = @broadcast.stage!(**)
  def row(contact) = @broadcast.staged_emails.find_by!(contact: contact)
  def perform_sends! = perform_enqueued_jobs(only: BroadcastSendJob)

  test "staging renders each reader's email, sends nothing, and skips a reader missing a field" do
    result = nil
    assert_no_emails { assert_no_enqueued_jobs { result = stage! } }

    assert_equal 2, result.staged
    assert_equal 1, result.skipped
    ann = row(@ann)
    assert_equal "staged", ann.status
    assert_equal "Ann, your 42 Cyvasse games are still here", ann.rendered_subject
    assert_includes ann.rendered_html, "You played <strong>42 games</strong>"
    assert_includes ann.rendered_html, "/e/c/#{ann.delivery_token}?l=play", "the snapshot carries its own tracking links"
    assert_equal({ "email" => "ann@example.com", "username" => "Ann", "games" => 42, "wins" => 30, "losses" => 12 }, ann.merge_fields)
    assert_equal "ann@example.com", ann.email

    skipped = row(@nameless)
    assert_equal "skipped", skipped.status
    assert_equal "missing username, games", skipped.skip_reason
    assert_nil skipped.rendered_html, "a reader without the fields is never rendered with blanks"
    assert_equal 0, @broadcast.deliveries.count, "a held email is not a delivery"
  end

  test "staging is idempotent: a second run stages nobody twice" do
    stage!
    assert_no_difference("StagedEmail.count") { assert_equal 0, stage!.total }

    Contact.create!(email: "late@example.com", tags: [ "cyvasse-legacy" ]).record_verification!(status: "valid")
    assert_equal 1, stage!.total, "only the new reader is staged"
  end

  test "staging respects the list rules: unsubscribed, unverified and already-sent readers stay out" do
    @bob.unsubscribe!
    Contact.create!(email: "unchecked@example.com", tags: [ "cyvasse-legacy" ])
    @broadcast.deliveries.create!(contact: @ann, sent_at: 1.day.ago)

    stage!
    assert_equal [ @nameless.id ], @broadcast.staged_emails.pluck(:contact_id)
  end

  test "limit and filter narrow what is staged" do
    assert_equal 1, stage!(limit: 1).total
    assert_equal [ @bob.id ], (stage!(filter: { email: "bob@example.com" }) && @broadcast.staged_emails.where(contact: @bob).pluck(:contact_id))
  end

  test "approve, cancel and re-stage move a row through its states" do
    stage!
    ann = row(@ann)
    assert_equal ann, ann.approve!
    assert ann.approved?
    assert_not_nil ann.approved_at

    bob = row(@bob)
    bob.cancel!
    assert bob.cancelled?
    assert_raises(ArgumentError) { bob.approve! }

    bob.render_snapshot!
    assert bob.reload.staged?, "re-staging re-renders a cancelled row back to staged"
    assert_nil bob.cancelled_at

    assert_raises(ArgumentError) { row(@nameless).approve! }
  end

  test "approve_staged! takes the oldest N, or the ids given" do
    stage!
    assert_equal 1, @broadcast.approve_staged!(count: 1)
    assert_equal 1, @broadcast.approve_staged!(ids: [ row(@bob).id, row(@nameless).id ]), "a skipped row is never approved"
    assert_equal %w[approved approved skipped], @broadcast.staged_emails.order(:contact_id).pluck(:status)
  end

  test "execute sends only approved emails, and exactly the stored snapshot" do
    stage!
    row(@ann).approve!
    # Tamper with the broadcast after approval: the approved snapshot still goes.
    @broadcast.update!(subject: "Changed after approval %{username}")

    result = @broadcast.execute_staged!(limit: 10)
    assert_equal 1, result.queued
    perform_sends!

    ann = row(@ann)
    mail = ActionMailer::Base.deliveries.sole
    assert_equal [ "ann@example.com" ], mail.to
    assert_equal ann.rendered_subject, mail.subject
    assert_equal ann.rendered_html, mail.html_part ? mail.html_part.decoded : mail.decoded
    assert_equal "sent", ann.status
    assert_equal ann.delivery_token, ann.delivery.token, "the delivery takes the token the snapshot's links carry"
    assert_equal [ "sent" ], ann.delivery.events.pluck(:kind)
    assert row(@bob).staged?, "an unapproved email stays held"
  end

  test "never twice: a second execute queues nothing, and a reader sent another way is skipped" do
    stage!
    @broadcast.approve_staged!
    assert_equal 2, @broadcast.execute_staged!(limit: 10).queued
    assert_equal 0, @broadcast.execute_staged!(limit: 10).queued, "a queued row is claimed once"

    @broadcast.deliveries.create!(contact: @bob, sent_at: Time.current) # the editor got there first
    perform_sends!

    assert_equal [ "ann@example.com" ], ActionMailer::Base.deliveries.flat_map(&:to), ActionMailer::Base.deliveries.map(&:subject).inspect
    assert_equal "sent", row(@ann).status
    assert_equal "skipped", row(@bob).status
    assert_equal "already sent by another send", row(@bob).skip_reason

    # Re-running a job for a sent row does nothing.
    assert_no_emails { BroadcastSendJob.perform_now(@broadcast.id, @ann.id, row(@ann).id) }
  end

  test "the queued_at claim is atomic: a row claimed between this run's read and its claim is not queued twice" do
    stage!
    row(@ann).approve!
    ann_id = row(@ann).id
    raced = false
    # A second execute claims Ann's row just after this one reads the ready rows.
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      next if raced || payload[:sql] !~ /SELECT "staged_emails"\."id", "staged_emails"\."contact_id"/

      raced = true
      StagedEmail.where(id: ann_id).update_all(queued_at: Time.current)
    end
    assert_equal 0, @broadcast.execute_staged!(limit: 10).queued, "UPDATE … WHERE queued_at IS NULL must touch nothing"
    assert raced, "the race never ran, so this test proved nothing"
    assert_no_enqueued_jobs(only: BroadcastSendJob)
  ensure
    ActiveSupport::Notifications.unsubscribe(sub) if sub
  end

  test "a reader who unsubscribes after approval is skipped at send" do
    stage!
    row(@ann).approve!
    @broadcast.execute_staged!(limit: 1)
    @ann.unsubscribe!
    assert_no_emails { perform_sends! }
    assert_equal "unsubscribed before send", row(@ann).skip_reason
  end

  test "the daily cap limits a run and counts what is already queued" do
    stage!
    @broadcast.approve_staged!
    gate = Broadcasts::SendGate.new(daily_cap: 1)
    assert_equal 1, @broadcast.execute_staged!(limit: 10, gate: gate.status).queued
    second = @broadcast.execute_staged!(limit: 10, gate: gate.status)
    assert_equal 0, second.queued
    assert_includes second.gate.reasons, "daily cap of 1 reached"
  end

  test "the gate pauses on a bounce rate over 2% and a complaint rate over 0.05%" do
    other = Broadcast.create!(subject: "Old", template_key: "cyvasse_is_back")
    deliveries = 10.times.map { |i| other.deliveries.create!(contact: Contact.create!(email: "o#{i}@example.com"), sent_at: 1.hour.ago) }
    assert_not Broadcasts::SendGate.status.paused?

    deliveries.first.record_event!(kind: "bounced", source: "resend")
    gate = Broadcasts::SendGate.status
    assert gate.paused?
    assert_equal [ "bounce rate 10.0% is over 2%" ], gate.reasons

    stage!
    @broadcast.approve_staged!
    assert_equal 0, @broadcast.execute_staged!(limit: 10).queued, "a paused gate queues nothing"

    deliveries.first.events.delete_all
    deliveries.last.record_event!(kind: "complained", source: "resend")
    assert_match(/complaint rate/, Broadcasts::SendGate.status.reasons.sole)

    travel 25.hours do
      assert_not Broadcasts::SendGate.status.paused?, "the window is the last 24 hours"
    end
  end

  test "a personalized broadcast refuses the unstaged batch send" do
    assert @broadcast.requires_staging?
    assert_raises(ArgumentError) { @broadcast.send_batch!(size: 1) }
    assert_not Broadcast.new(subject: "Hi", template_key: "cyvasse_is_back").requires_staging?
  end

  test "the preview disarms tracking: no open pixel, links go straight to their destinations" do
    stage!
    ann = row(@ann)
    assert_includes ann.rendered_html, "/e/o/#{ann.delivery_token}"
    assert_not_includes ann.preview_html, "/e/o/"
    assert_not_includes ann.preview_html, "/e/c/"
    assert_includes ann.preview_html, "https://cyvasse.xyz/"
  end

  test "merge fields read traits nil-safe" do
    assert_equal({ "email" => "nameless@example.com" }, Broadcasts::MergeFields.for(@nameless))
    @nameless.update_columns(traits: { "cyvasse" => "not a hash" })
    assert_equal({ "email" => "nameless@example.com" }, Broadcasts::MergeFields.for(@nameless.reload))
    assert_equal %w[username games], Broadcasts::MergeFields.fields_in("%{username} %{games} %{username}")
    assert_equal "Ann, {x}", Broadcasts::MergeFields.interpolate("%{username}, {x}", { "username" => "Ann" })
    assert_equal "Hi Tom Bcc: x@y.z, %{games}",
                 Broadcasts::MergeFields.interpolate("Hi %{username}, %{games}", { "username" => "Tom\r\nBcc: x@y.z" }),
                 "a line break in a value never reaches the subject header; a missing field stays as written"
  end
end
