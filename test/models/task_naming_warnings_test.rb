require "test_helper"

# Guard catalog row 10.1. A title outside 3-5 words or an acceptance bullet outside
# 5-12 saves, and Task#warnings carries the advice for the fields that save changed.
class TaskNamingWarningsTest < ActiveSupport::TestCase
  test "[unit] a title outside 3-5 words saves and warns" do
    assert_empty Task.create!(title: "fix the login").warnings            # 3
    assert_empty Task.create!(title: "add a new login flow").warnings     # 5

    short = Task.create!(title: "fix login")                              # 2
    assert_equal 1, short.warnings.size
    assert_match(/title is 2 words; 3-5 reads best/, short.warnings.first)

    long = Task.create!(title: "add a brand new login flow now")          # 7
    assert long.persisted?
    assert_match(/title is 7 words/, long.warnings.first)
  end

  test "[unit] a save that leaves the title alone draws no title warning" do
    task = Task.create!(title: "now this title has far too many words to pass") # 9
    assert_equal 1, task.warnings.size

    task.update!(stage: "building")
    assert_empty task.warnings, "the advice is for the field this save changed"
  end

  test "[unit] an acceptance bullet outside 5-12 words saves and warns" do
    ok = Task.create!(title: "acceptance length check",
                      metadata: { "devops" => { "acceptance" => ["the user can log in successfully"] } }) # 6
    assert_empty ok.warnings

    short = Task.create!(title: "acceptance length again",
                         metadata: { "devops" => { "acceptance" => ["the user can log in successfully",
                                                                     "too short here"] } }) # 6, 3
    assert_equal ["the user can log in successfully", "too short here"], short.reload.devops_acceptance

    short.update!(metadata: short.metadata.deep_merge("devops" => { "acceptance" => ["too short"] })) # 2
    assert_equal 1, short.warnings.size
    assert_match(/acceptance #1 is 2 words/, short.warnings.first)
  end

  test "[unit] a devops write that leaves acceptance alone draws no bullet warning" do
    task = Task.create!(title: "acceptance change task",
                        metadata: { "devops" => { "acceptance" => ["too short"] } }) # 2
    assert_match(/acceptance #1 is 2 words; 5-12 reads best: too short/, task.warnings.first)

    task.update!(metadata: task.metadata.deep_merge("devops" => { "kind" => "bug" }))
    assert_equal "bug", task.devops_kind
    assert_empty task.warnings
  end
end
