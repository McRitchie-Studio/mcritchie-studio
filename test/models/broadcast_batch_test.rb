require "test_helper"

# [unit] Broadcast#send_batch! works a list down (task broadcast-batch-send):
# N random subscribed contacts on the audience that this broadcast has not
# reached, queued a spacing apart, and a batch_status that counts both sides.
class BroadcastBatchTest < ActiveJob::TestCase
  setup do
    @broadcast = Broadcast.create!(slug: "batchy", subject: "Hi", template_key: "cyvasse_is_back", target_list: "cyvasse-legacy")
    @listed = 5.times.map { |i| Contact.create!(email: "l#{i}@example.com", tags: [ "cyvasse-legacy" ]) }
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
end
