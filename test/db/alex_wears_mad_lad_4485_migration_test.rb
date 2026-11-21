require "test_helper"
require Rails.root.join("db/migrate/20261121220000_alex_wears_mad_lad_4485.rb").to_s

# [unit] AlexWearsMadLad4485 moves the alex agent's stored portrait to the new
# cache-busting path and back, and leaves a hand-set avatar alone.
class AlexWearsMadLad4485MigrationTest < ActiveSupport::TestCase
  M = AlexWearsMadLad4485

  setup { @alex = Agent.find_by!(slug: "alex") }

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  test "[unit] up moves the old portrait path to alex-4485.webp; down moves it back" do
    @alex.update_columns(avatar: M::OLD)

    migrate(:up)
    assert_equal M::NEW, @alex.reload.avatar

    migrate(:down)
    assert_equal M::OLD, @alex.reload.avatar
  end

  test "[unit] up leaves a hand-set avatar and other souls untouched" do
    @alex.update_columns(avatar: "/agents/custom.webp")
    other = Agent.where.not(slug: "alex").first
    other&.update_columns(avatar: M::OLD)

    migrate(:up)

    assert_equal "/agents/custom.webp", @alex.reload.avatar
    assert_equal M::OLD, other.reload.avatar if other
  end
end
