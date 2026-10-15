require "test_helper"
require "rake"
require_relative "../support/agent_message_fixtures"

# [unit] The delete path for agent person notes: agent_people:notes lists a
# person's notes with their ids, and agent_people:forget deletes one (NOTE) or
# all of a person's (PERSON + ALL=1), refusing anything less specific.
class AgentPeopleRakeTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agent_people:forget")
    %w[agent_people:notes agent_people:forget].each { |t| Rake::Task[t].reenable }
    @message = agent_message!(soul: "xan", channel: "discord", author_ref: "500", author_name: "Alex")
    @notes = AgentPersonNote.record_from!(@message, [ "Favorite color is purple.", "Runs the hub." ])
    @person = @message.person
  end

  def run_task(name, **env)
    saved = env.keys.to_h { |k| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    Rake::Task[name].reenable
    capture_io { Rake::Task[name].invoke }.first
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  test "notes lists each note with its id, date, source and soul" do
    out = run_task("agent_people:notes", "PERSON" => @person.id.to_s)
    assert_includes out, "##{@person.id} Alex: 2 note(s)"
    assert_match(/note #{@notes.first.id}  \d{4}-\d\d-\d\d  from ##{@message.id}  xan  Favorite color is purple\./, out)
  end

  test "forget NOTE deletes that one note; PERSON with ALL=1 deletes them all" do
    out = run_task("agent_people:forget", "NOTE" => @notes.first.id.to_s)
    assert_includes out, "forgot note #{@notes.first.id}"
    assert_equal [ "Runs the hub." ], @person.notes.reload.map(&:body)

    out = run_task("agent_people:forget", "PERSON" => @person.id.to_s, "ALL" => "1")
    assert_includes out, "forgot 1 note(s)"
    assert_empty @person.notes.reload
  end

  test "forget with PERSON alone refuses and deletes nothing" do
    assert_raises(SystemExit) { capture_io { run_task("agent_people:forget", "PERSON" => @person.id.to_s) } }
    assert_equal 2, @person.notes.count
  end
end
