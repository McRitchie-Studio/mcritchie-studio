require "test_helper"

# [unit] Broadcast#send_batch! works a list down (task broadcast-batch-send):
# N random subscribed contacts on the audience that this broadcast has not
# reached, queued a spacing apart, and a batch_status that counts both sides.
class BroadcastBatchTest < ActiveJob::TestCase
  setup do
    @broadcast = Broadcast.create!(slug: "batchy", subject: "Hi", template_key: "cyvasse_is_back", target_list: "cyvasse-legacy")
    # Verified valid: cyvasse-legacy is a verified-only audience (tests below).
    @listed = 5.times.map { |i| Contact.create!(email: "l#{i}@example.com", tags: [ "cyvasse-legacy" ]).tap { _1.record_verification!(status: "valid") } }
    @other = Contact.create!(email: "other@example.com", tags: [ "turf" ])
    @gone = Contact.create!(email: "gone@example.com", tags: [ "cyvasse-legacy" ])
    @gone.unsubscribe!
  end

  def queued_contact_ids
    enqueued_jobs.select { _1["job_class"] == "BroadcastSendJob" }.map { _1["arguments"].last }
  end

  test "a batch takes N subscribed list contacts, spaced apart" do
    ids = @broadcast.send_batch!(size: 3)

    assert_equal 3, ids.size
    assert_equal ids.sort, queued_contact_ids.sort
    assert_empty ids & [ @other.id, @gone.id ], "only subscribed contacts on the list"
    times = enqueued_jobs.map { Time.iso8601(_1["scheduled_at"]) }.sort
    gaps = times.each_cons(2).map { |a, b| (b - a).round(1) }
    assert_equal [ 0.6, 0.6 ], gaps, "each send waits BATCH_SPACING after the last"
  end

  test "the next batch skips anyone already sent, and the list runs out cleanly" do
    first = @broadcast.send_batch!(size: 3)
    first.each { |id| @broadcast.deliveries.create!(contact_id: id, sent_at: Time.current) }
    clear_enqueued_jobs

    second = @broadcast.send_batch!(size: 10)
    assert_equal 2, second.size
    assert_empty first & second
    assert_equal({ sent: 3, remaining: 2, opened: 0, clicked: 0 }, @broadcast.batch_status)
  end

  test "a delivery created but never sent still counts as remaining" do
    @broadcast.deliveries.create!(contact: @listed.first)
    assert_equal 5, @broadcast.unsent_contacts.count
  end

  test "a batch needs an audience and a positive size" do
    assert_raises(ArgumentError) { @broadcast.send_batch!(size: 0) }
    @broadcast.update!(target_list: nil)
    assert_raises(ArgumentError) { @broadcast.send_batch!(size: 2) }
  end

  test "cyvasse-legacy batches take only contacts verified valid" do
    unchecked = Contact.create!(email: "unchecked@example.com", tags: [ "cyvasse-legacy" ])
    catch_all = Contact.create!(email: "catchall@example.com", tags: [ "cyvasse-legacy" ])
    catch_all.record_verification!(status: "catch-all")

    ids = @broadcast.send_batch!(size: 50)
    assert_equal @listed.map(&:id).sort, ids.sort
    assert_equal 5, @broadcast.batch_status[:remaining]

    clear_enqueued_jobs
    everyone = @broadcast.send_batch!(size: 50, verified: false)
    assert_includes everyone, unchecked.id
    assert_includes everyone, catch_all.id
  end

  test "other audiences are not verified-only unless asked" do
    turf = Broadcast.create!(slug: "turfy", subject: "Hi", template_key: "cyvasse_is_back", target_list: "turf")
    assert_equal [ @other.id ], turf.send_batch!(size: 5)
    clear_enqueued_jobs
    assert_empty turf.send_batch!(size: 5, verified: true)
    assert Broadcast.verification_required?("cyvasse-legacy")
    assert_not Broadcast.verification_required?("turf")
  end
end
