require "test_helper"

# [integration] The standard profile columns, WRITTEN AND READ BACK.
#
# The unit guard beside this asks `User.column_names`, which is answered from
# schema.rb — the file the test database is loaded from. That proves the schema
# says the columns exist. It does NOT prove a value survives a round trip, and
# the two come apart in exactly one way that matters here: `add_column` with
# `if_not_exists: true` is a no-op when the column is already present, so a
# migration that silently did nothing still leaves a green column_names check on
# an app whose schema.rb was updated by something else.
#
# So this writes real rows through the real adapter.
class StandardProfileColumnsPersistTest < ActiveSupport::TestCase
  def user(**attrs)
    User.create!({ email: "columns-#{SecureRandom.hex(4)}@example.com", role: "viewer" }.merge(attrs))
  end

  test "a name round-trips through both halves" do
    u = user(first_name: "Alex", last_name: "McRitchie").reload

    assert_equal "Alex", u.first_name
    assert_equal "McRitchie", u.last_name
  end

  # TWO TIMESTAMPS, NOT A BOOLEAN, and this is the test that says why. "Subscribed"
  # is DERIVED — joined after left — so the pair has to survive a rejoin with both
  # dates intact. A boolean column could not answer "when did they leave", and a
  # single timestamp could not tell a rejoin from a first join.
  test "the newsletter pair records a join, a leave, and a rejoin" do
    joined = 3.days.ago.change(usec: 0)
    left   = 2.days.ago.change(usec: 0)

    u = user(joined_email_list_at: joined, left_email_list_at: left).reload
    assert_equal joined, u.joined_email_list_at
    assert_equal left, u.left_email_list_at
    refute u.joined_email_list_at > u.left_email_list_at, "left after joining — not subscribed"

    rejoined = 1.day.ago.change(usec: 0)
    u.update!(joined_email_list_at: rejoined)
    u.reload

    assert u.joined_email_list_at > u.left_email_list_at, "rejoined — subscribed again"
    assert_equal left, u.left_email_list_at,
                 "the leave date must survive a rejoin — it is the durable fact, not a flag"
  end

  # An account that has never touched the list holds NULL in both, and that is a
  # third state distinct from joined and from left. A boolean would have collapsed
  # it into "not subscribed" and lost "never asked".
  test "an untouched account holds neither date" do
    u = user.reload

    assert_nil u.joined_email_list_at
    assert_nil u.left_email_list_at
  end
end
