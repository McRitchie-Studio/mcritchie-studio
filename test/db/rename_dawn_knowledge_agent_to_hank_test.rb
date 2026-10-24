require "test_helper"
require Rails.root.join("db/migrate/20261021060000_rename_dawn_knowledge_agent_to_hank").to_s

# [unit] The business agent Dawn is renamed Hank: every hub access map moves its
# "dawn" key to "hank" with the level unchanged, and down restores it.
class RenameDawnKnowledgeAgentToHankTest < ActiveSupport::TestCase
  def doc(access)
    Studio::KnowledgeDoc.create!(title: "Doc", entity: "commercial-welding-llc", path: "deal",
                                 status: "filed", access: access)
  end

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { RenameDawnKnowledgeAgentToHank.new.migrate(direction) }
  end

  test "up moves the dawn key to hank and keeps every level" do
    privileged = doc("samson" => "full", "dawn" => "none")
    standup = doc("samson" => "full", "dawn" => "aware")
    untouched = doc("samson" => "aware")

    migrate(:up)

    assert_equal({ "samson" => "full", "hank" => "none" }, privileged.reload.access)
    assert_equal({ "samson" => "full", "hank" => "aware" }, standup.reload.access)
    assert_equal({ "samson" => "aware" }, untouched.reload.access)
    assert_equal "aware", standup.access_for("hank")
  end

  test "an existing hank key wins over the dawn key it would replace" do
    both = doc("dawn" => "full", "hank" => "none")

    migrate(:up)

    assert_equal({ "hank" => "none" }, both.reload.access)
  end

  test "down restores the dawn key" do
    row = doc("samson" => "full", "dawn" => "aware")

    migrate(:up)
    migrate(:down)

    assert_equal({ "samson" => "full", "dawn" => "aware" }, row.reload.access)
  end

  test "the other agent-keyed access maps move too" do
    source = KnowledgeSource.create!(kind: "google_drive", name: "Deal folder", external_root_id: "root-hank",
                                     access: { "samson" => "full", "dawn" => "aware" })
    document = SourceDocument.create!(knowledge_source: source, external_id: "file-hank", status: "active",
                                      access: { "dawn" => "none" })
    ask = Communication.create!(kind: "ask", channel: "email", ask_text: "Who is on this?", status: "open",
                                access: { "samson" => "full", "dawn" => "aware" })

    migrate(:up)

    assert_equal({ "samson" => "full", "hank" => "aware" }, source.reload.access)
    assert_equal({ "hank" => "none" }, document.reload.access)
    assert_equal({ "samson" => "full", "hank" => "aware" }, ask.reload.access)
  end
end
