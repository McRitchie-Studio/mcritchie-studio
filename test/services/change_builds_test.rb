require "test_helper"

# [unit] ChangeBuilds, the board side of the launcher starting chat-sourced change
# cards: which designed cards it may start (a confirmed web-chat proposal on a
# studio or product app, never a title match), the start record, and the one
# message back in the card's thread.
class ChangeBuildsTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @t0 = Time.current
    @seq = 0
  end

  def web_message!(app: "turf-monster", user_id: 41, content: "Can you add a dark toggle?")
    @seq += 1
    AgentMessage.create!(channel: "web", external_id: "web-test-#{@seq}-#{SecureRandom.hex(3)}", channel_ref: app,
                         thread_key: AgentMessages::WebChat.thread_key(app, user_id), author_ref: user_id.to_s,
                         author_name: "Owner", content: content, soul_slug: "turf_monster", routed_by: "chat",
                         status: "completed")
  end

  # A designed card as AgentProposals::Executor#change opens it, and the proposal
  # that opened it, settled as AgentProposalJob leaves it.
  def chat_card!(slug, repo: "turf-monster", kind: "feature", status: "executed", settled_by: "web:41",
                 source_thread: :default, title: "Dark toggle #{slug}")
    thread = source_thread == :default ? "#{AgentProposal::BOARD_URL}/applications/#{repo}/chat" : source_thread
    task = Task.create!(title: title, slug: slug, stage: "designed", priority: 1,
                        metadata: { "devops" => { "kind" => kind, "shape" => "ui-only", "repositories" => [ repo ],
                                                  "acceptance" => [ "a toggle" ], "source_thread" => thread }.compact })
    ask = web_message!(app: repo)
    go = web_message!(app: repo, content: "go")
    AgentProposal.create!(thread_key: ask.thread_key, channel: "web", channel_ref: repo, soul_slug: "turf_monster",
                          source_message: ask, confirm_message: go, kind: "change", capability: "task",
                          params: { "title" => title }, summary: "Open a task", status: status, settled_by: settled_by,
                          settled_at: @t0, expires_at: 1.day.from_now,
                          result: (status == "executed" ? { "task_slug" => slug } : {}))
    task
  end

  def picked = ChangeBuilds.candidates(now: @t0).map { |c| c["task_slug"] }

  test "a chat-sourced, owner-confirmed change card on a product app is a candidate" do
    chat_card!("dark-toggle")

    assert_equal [ "dark-toggle" ], picked
    candidate = ChangeBuilds.candidates(now: @t0).sole
    assert_equal %w[turf-monster feature], candidate.values_at("repo", "kind")
  end

  test "a studio-tier card is a candidate too, and bug and chore kinds are" do
    chat_card!("hub-bug", repo: "mcritchie-studio", kind: "bug")
    chat_card!("turf-chore", kind: "chore")

    assert_equal %w[hub-bug turf-chore], picked.sort
  end

  test "a title match is never a candidate: the card must be the one the proposal's result names" do
    chat_card!("the-real-one", title: "Same title")
    Task.create!(title: "Same title", slug: "same-title-copy", stage: "designed", priority: 1,
                 metadata: { "devops" => { "kind" => "feature", "repositories" => [ "turf-monster" ],
                                           "source_thread" => "#{AgentProposal::BOARD_URL}/applications/turf-monster/chat" } })

    assert_equal [ "the-real-one" ], picked
  end

  test "an unconfirmed proposal's card is never a candidate: proposed, confirmed but not run, or no settler" do
    chat_card!("still-proposed", status: "proposed", settled_by: nil)
    chat_card!("confirmed-not-run", status: "confirmed")
    card = chat_card!("no-settler", settled_by: nil)

    assert_empty picked
    assert_raises(ChangeBuilds::Refused) { ChangeBuilds.claim!(card.slug, worker: "w", run: "r1", now: @t0) }
    assert_equal "designed", card.reload.stage
  end

  test "a basic-tier app's card is not a candidate; control: the same card on a product app is" do
    chat_card!("moms-toggle", repo: "moms-app")
    assert_empty picked

    chat_card!("turf-toggle")
    assert_equal [ "turf-toggle" ], picked
  end

  test "a docs card, a card without a source thread, a blocked or assigned card, and a launch task are not candidates" do
    chat_card!("docs-card", kind: "docs")
    chat_card!("no-thread", source_thread: nil)
    chat_card!("blocked-card").update_columns(blocked_at: @t0)
    chat_card!("assigned-card").update_columns(agent_slug: agents(:mack_agent).slug)
    chat_card!("launch-card")
    AppRequest.new(prompt: "x", task_slug: "launch-card", token: SecureRandom.hex(8)).save!(validate: false)

    assert_empty picked
  end

  test "claim records the start; a started card posts one message back in its thread and the launch line" do
    card = chat_card!("dark-toggle")
    claimed = ChangeBuilds.claim!("dark-toggle", worker: "mac", run: "r1", now: @t0)
    assert_equal({ "task_slug" => "dark-toggle", "repo" => "turf-monster", "attempts" => 1 }, claimed)
    assert_empty picked, "a card being started is not offered again"

    desk = "/Users/alex/projects/turf-monster/.worktrees/dark-toggle"
    assert_difference -> { AgentMessage.where(channel: "web").count }, 1 do
      ChangeBuilds.finish!("dark-toggle", run: "r1", outcome: "started", desk: desk, now: @t0)
    end

    run = ChangeBuilds.run_of(card.reload)
    assert_equal [ "started", desk ], run.values_at("state", "desk")
    assert_includes run["launch_line"], "cd #{desk} && claude --agent pokemon"
    assert_includes run["launch_line"], "task begin dark-toggle"

    proposal = AgentProposal.find_by!("result->>'task_slug' = ?", "dark-toggle")
    line = AgentMessage.find_by!(external_id: "change-build:dark-toggle:started")
    assert_equal [ proposal.thread_key, "turf-monster", "posted", "Building started, task `dark-toggle`." ],
                 [ line.thread_key, line.channel_ref, line.reply_status, line.response_text ]
    assert ClientBuilds.progress?(line), "shown as a code-written line, never the stored marker"

    # Control: the message is once per card, whatever retries the post.
    assert_no_difference -> { AgentMessage.count } do
      ChangeBuilds.post_to_thread!(card, proposal)
    end
    err = assert_raises(ChangeBuilds::Refused) { ChangeBuilds.finish!("dark-toggle", run: "r1", outcome: "started", now: @t0) }
    assert_equal :not_held, err.code
  end

  test "a desk path with a shell character is dropped from the launch line" do
    chat_card!("odd-desk")
    ChangeBuilds.claim!("odd-desk", worker: "mac", run: "r1", now: @t0)
    task = ChangeBuilds.finish!("odd-desk", run: "r1", outcome: "started", desk: "/tmp/x; rm -rf ~", now: @t0)

    run = ChangeBuilds.run_of(task)
    assert_nil run["desk"]
    assert run["launch_line"].start_with?("cd #{ChangeBuilds::HUB} && ")
  end

  test "a refusal keeps the card designed, posts nothing in the thread, and retries after RETRY_AFTER until max_attempts" do
    card = chat_card!("no-slot")
    ChangeBuilds.claim!("no-slot", worker: "mac", run: "r1", now: @t0)

    assert_no_difference -> { AgentMessage.count } do
      ChangeBuilds.finish!("no-slot", run: "r1", outcome: "refused", reason: "bin/task begin exited 1: no desk slot", now: @t0)
    end
    card.reload
    assert_equal "designed", card.stage
    assert_equal [ "refused", "bin/task begin exited 1: no desk slot" ], ChangeBuilds.run_of(card).values_at("state", "refused_reason")

    assert_empty ChangeBuilds.candidates(now: @t0 + 5.minutes), "not retried at once"
    assert_equal [ "no-slot" ], ChangeBuilds.candidates(now: @t0 + 11.minutes).map { |c| c["task_slug"] }

    (2..ChangeBuilds.max_attempts).each do |n|
      at = @t0 + (11 * n).minutes
      ChangeBuilds.claim!("no-slot", worker: "mac", run: "r#{n}", now: at)
      ChangeBuilds.finish!("no-slot", run: "r#{n}", outcome: "refused", reason: "again", now: at)
    end
    assert_empty ChangeBuilds.candidates(now: @t0 + 2.hours), "past max_attempts the card is left for a person"
  end

  test "a start left starting past STALE_AFTER is offered again" do
    chat_card!("died-mid-begin")
    ChangeBuilds.claim!("died-mid-begin", worker: "mac", run: "r1", now: @t0)

    assert_empty ChangeBuilds.candidates(now: @t0 + 29.minutes)
    assert_equal [ "died-mid-begin" ], ChangeBuilds.candidates(now: @t0 + 31.minutes).map { |c| c["task_slug"] }
  end
end
