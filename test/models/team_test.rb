require "test_helper"

class TeamTest < ActiveSupport::TestCase
  test "slug is generated from name" do
    team = Team.create!(name: "Inter Miami")
    assert_equal "inter-miami", team.slug
  end

  test "to_param returns slug" do
    team = teams(:argentina)
    assert_equal "argentina", team.to_param
  end

  test "name is required" do
    team = Team.new(name: nil)
    assert_not team.valid?
    assert_includes team.errors[:name], "can't be blank"
  end

  test "slug is unique" do
    Team.create!(name: "Test Team")
    assert_raises ActiveRecord::RecordNotUnique do
      Team.create!(name: "Test Team")
    end
  end

  test "has many contracts" do
    team = teams(:argentina)
    assert_respond_to team, :contracts
  end

  test "has many people through contracts" do
    team = teams(:argentina)
    assert_includes team.people, people(:messi)
  end

  test "belongs to home arena by slug" do
    team = teams(:buffalo_bills)

    assert_equal arenas(:highmark_stadium), team.home_arena
  end

  test "stores mascot when it can be derived" do
    team = Team.create!(name: "Denver Broncos", location: "Denver")

    assert_equal "Broncos", team.reload[:mascot]
    assert_equal "Broncos", team.mascot
  end
end
