require "test_helper"

# [integration] The two BATCH flips a watching operator sees on /deployments — the
# archive sweep (shipped → archived) and a production ship (assembled → shipped) —
# taken across the whole model → DeploymentsBroadcaster → ActionCable boundary,
# which is where the operator-visible behaviour actually lives.
#
# Two properties, and the old code broke both:
#
#   ORDER — the batch must leave from the TOP of the column down. Both loops used
#   to run oldest-first (find_each by id / order(:created_at)), which is the BOTTOM
#   card first, so the column visibly unzipped upward.
#
#   ONE CARD PER BROADCAST — every flip reaches the board on its own commit, so the
#   CLI's cadence (BOARD_FLIP_CADENCE) actually spaces them out. archive_completed!
#   used to wrap the batch in ONE transaction, which held every after_commit
#   broadcast until the single commit: no cadence could survive that.
class BoardBatchFlipCadenceTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  # Turbo::StreamsChannel.broadcast_stream_to(STREAM, …) broadcasts to the stream
  # name derived from the streamable — a plain String stays itself (stream_name_from
  # is private on the channel, so it is called through send rather than re-spelled).
  DEPLOYMENTS_STREAM = Turbo::StreamsChannel.send(:stream_name_from, DeploymentsBroadcaster::STREAM)

  # The stream payloads (HTML strings) that mention this card, in broadcast order.
  def card_payloads(payloads, slug)
    payloads.select { |payload| payload.to_s.include?("card-#{slug}") }
  end

  # Which of the two cards each payload is about, in broadcast order — the order
  # the operator watches the cards leave in.
  def flip_order(payloads, slugs)
    payloads.filter_map do |payload|
      slugs.find { |slug| payload.to_s.include?("card-#{slug}") }
    end
  end

  # How many card removals have actually reached the stream so far. Read MID-LOOP,
  # this is what separates "each flip commits and broadcasts on its own" from a
  # batch held inside one transaction.
  #
  # `broadcasts` hands back the RAW queued messages — JSON-encoded, so the HTML's
  # quotes arrive escaped and a plain `include?('action="remove"')` matches nothing.
  # (capture_broadcasts decodes for you; this one does not.)
  def removals_so_far
    broadcasts(DEPLOYMENTS_STREAM).count do |raw|
      decoded = begin
        ActiveSupport::JSON.decode(raw)
      rescue StandardError
        raw
      end
      decoded.to_s.include?("action=\"remove\"")
    end
  end

  test "[integration] the archive sweep removes cards top-to-bottom, one broadcast each" do
    bottom = Task.create!(title: "cadence bottom shipped task", stage: "shipped")
    top    = Task.create!(title: "cadence top shipped task", stage: "shipped")
    # A board column renders position DESC, so `top` is the card the operator sees
    # first. Other shipped fixtures ride along; the assertions are about these two.
    bottom.update_column(:position, 100)
    top.update_column(:position, 300)

    payloads = capture_broadcasts(DEPLOYMENTS_STREAM) do
      Release::Conductor.archive_completed!
    end

    assert_equal [top.slug, bottom.slug], flip_order(payloads, [top.slug, bottom.slug]),
                 "the sweep must reach the board from the top of the Shipped column down"
    [top, bottom].each do |task|
      mine = card_payloads(payloads, task.slug)
      assert_equal 1, mine.size, "#{task.slug} must arrive as its OWN broadcast, not batched with the rest"
      assert_includes mine.first, "action=\"remove\""
      assert_includes mine.first, "data-exit-action=\"archive\"",
                      "the board reads the exit style off the stream — archive dissolves, delete does not"
    end
  end

  test "[integration] each archived card reaches the board BEFORE the next one is archived" do
    Task.create!(title: "cadence first shipped task", stage: "shipped")
    Task.create!(title: "cadence second shipped task", stage: "shipped")

    baseline = removals_so_far
    at_each_pause = []
    result = Release::Conductor.stub(:pause_between_archives, ->(_seconds) { at_each_pause << removals_so_far - baseline }) do
      Release::Conductor.archive_completed!(pause: 0.5)
    end

    assert_operator result[:count], :>=, 2
    assert_equal (1..result[:count] - 1).to_a, at_each_pause,
                 "the k-th pause must see k cards ALREADY gone from the board — with the batch " \
                 "wrapped in one transaction every pause sees 0 and the cadence buys nothing"
  end

  test "[integration] a ship moves members top-to-bottom, one broadcast each" do
    release = Release.open!
    bottom  = Task.create!(title: "cadence bottom ship member", stage: "reviewed")
    top     = Task.create!(title: "cadence top ship member", stage: "reviewed")
    release.add(bottom)
    release.add(top)
    release.assemble!
    bottom.update_column(:position, 100)
    top.update_column(:position, 300)

    payloads = capture_broadcasts(DEPLOYMENTS_STREAM) do
      release.ship!(by: "steffon")
    end

    assert_equal [top.slug, bottom.slug], flip_order(payloads, [top.slug, bottom.slug]),
                 "the batch must depart from the top of the Assembled column down"
    [top, bottom].each do |task|
      mine = card_payloads(payloads, task.slug)
      assert_equal 1, mine.size, "#{task.slug} moves in ONE payload of its own"
      assert_includes mine.first, "action=\"remove\"", "a move removes the old card…"
      assert_includes mine.first, "action=\"prepend\"", "…and prepends the fresh one in its new column"
      assert_equal "shipped", task.reload.stage
    end
  end
end
