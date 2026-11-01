require "test_helper"

# [unit] ChangeBuilds, the board side of the launcher starting chat-sourced change
# cards: which designed cards it may start (a confirmed web-chat proposal on a
# studio or product app, never a title match), the start record, and the one
# message back in the card's thread.
class ChangeBuildsTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  include ActiveJob::TestHelper

  OWNER_SLACK = "U0OWNER001".freeze

  setup do
    @t0 = Time.current
    @seq = 0
    AgentMessages::SlackRoutes.current = AgentMessages::SlackRoutes.new(
      "team_id" => "T0TEST0001", "bot_user_id" => "U0APPBOT01", "owner_user_id" => OWNER_SLACK, "souls" => { "avi" => {} }
    )
  end

  teardown { AgentMessages::SlackRoutes.reset! }

  def person!(role)
    AgentPerson.create!(display_name: "#{role} #{SecureRandom.hex(2)}").tap { |p| p.set_role!(role, client_domain: (role == "client" ? "turf_monster" : nil)) }
  end

  def slack_message!(author:, person:, content:, ts:)
    AgentMessage.create!(channel: "slack", external_id: "C0DESK0001:#{ts}", channel_ref: "C0DESK0001",
                         guild_id: "T0TEST0001", thread_key: "slack:C0DESK0001:1761800000.000001",
                         author_ref: author, author_name: "Someone", person: person, content: content,
                         soul_slug: "avi", routed_by: "thread", status: "completed",
                         envelope: { "channel_type" => "channel" })
  end

  # A designed card opened from a Slack proposal, confirmed by `go` from `author`
  # (the person `person`, settled as `settled_by`; :go for the go's own person).
  def slack_card!(slug, repo: "mcritchie-studio", author: OWNER_SLACK, person: person!("owner"), settled_by: :go)
    task = Task.create!(title: "Admin page #{slug}", slug: slug, stage: "designed", priority: 1,
                        metadata: { "devops" => { "kind" => "feature", "shape" => "ui-only", "repositories" => [ repo ],
                                                  "acceptance" => [ "one admin link" ],
                                                  "source_thread" => "https://slack.com/archives/C0DESK0001/p1" } })
    @seq += 1
    ask = slack_message!(author: author, person: person, content: "Avi, combine the admin links", ts: "1761800000.#{format('%06d', @seq)}")
    @seq += 1
    go = slack_message!(author: author, person: person, content: "go", ts: "1761800000.#{format('%06d', @seq)}")
    AgentProposal.create!(thread_key: ask.thread_key, channel: "slack", channel_ref: "C0DESK0001", guild_id: "T0TEST0001",
                          soul_slug: "avi", source_message: ask, confirm_message: go, kind: "change", capability: "task",
                          params: { "title" => task.title }, summary: "Open a task", status: "executed",
                          settled_by: settled_by == :go ? "person:#{person.id}" : settled_by, settled_at: @t0,
                          expires_at: 1.day.from_now, result: { "task_slug" => slug })
    task
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

  test "Alex McRitchie's own Slack go starts a hub card and a Turf card" do
    slack_card!("combine-admin-links")
    slack_card!("turf-slack-card", repo: "turf-monster")

    assert_equal %w[combine-admin-links turf-slack-card], picked.sort
    assert_equal "mcritchie-studio", ChangeBuilds.candidates(now: @t0).find { |c| c["task_slug"] == "combine-admin-links" }["repo"]
  end

  test "a Slack go not from the verified owner never starts a build; control: the owner's does" do
    slack_card!("wrong-author", author: "U0OTHER001")                  # owner role, not the configured Slack user
    slack_card!("team-person", person: person!("team"))                # the owner's Slack id, a team person
    slack_card!("client-person", person: person!("client"))
    slack_card!("other-settler", settled_by: "person:#{person!('owner').id}") # settled by someone else
    slack_card!("basic-app", repo: "moms-app")                         # the owner, but a basic-tier app
    assert_empty picked

    AgentMessages::SlackRoutes.current = AgentMessages::SlackRoutes.new("team_id" => "T0TEST0001", "owner_user_id" => "")
    slack_card!("no-owner-configured")
    assert_empty picked, "a blank configured owner id starts nothing"

    AgentMessages::SlackRoutes.current = AgentMessages::SlackRoutes.new("team_id" => "T0TEST0001", "owner_user_id" => OWNER_SLACK)
    assert_equal [ "no-owner-configured" ], picked
  end

  test "a Discord go on the same card is not started: only web and the owner's Slack or Teams" do
    card = slack_card!("discord-card")
    AgentProposal.find_by!("result->>'task_slug' = ?", card.slug).update_columns(channel: "discord")

    assert_empty picked
  end

  test "an owner's Slack start posts the started line (with the launch line) into the Slack thread through the reply job" do
    card = slack_card!("combine-admin-links")
    ChangeBuilds.claim!(card.slug, worker: "mac", run: "r1", now: @t0)
    desk = "/Users/alex/projects/mcritchie-studio/.worktrees/combine-admin-links"

    assert_enqueued_with(job: AgentMessageReplyJob) do
      ChangeBuilds.finish!(card.slug, run: "r1", outcome: "started", desk: desk, now: @t0)
    end
    proposal = AgentProposal.find_by!("result->>'task_slug' = ?", card.slug)
    line = AgentMessage.find_by!(channel: "slack", external_id: "change-build:combine-admin-links:started")
    assert_equal [ proposal.thread_key, "C0DESK0001", "T0TEST0001", "queued", "completed", OWNER_SLACK ],
                 [ line.thread_key, line.channel_ref, line.guild_id, line.reply_status, line.status, line.author_ref ]
    assert line.response_text.start_with?("Building started, task `combine-admin-links`.")
    assert_includes line.response_text, "cd #{desk} && claude --agent pokemon"
    assert_equal "1761800000.000001", Media::Slack.thread_ts(line), "the reply lands in the proposal's thread"
    assert ClientBuilds.progress?(line)

    assert_no_difference -> { AgentMessage.count } do
      ChangeBuilds.post_to_thread!(card.reload, proposal)
    end
  end

  test "a started card reaching submitted posts one submitted line, with the PR on the owner's Slack thread" do
    card = slack_card!("combine-admin-links")
    ChangeBuilds.claim!(card.slug, worker: "mac", run: "r1", now: @t0)
    ChangeBuilds.finish!(card.slug, run: "r1", outcome: "started", desk: "/tmp/desk", now: @t0)
    card.reload.update_columns(pr_url: "https://github.com/McRitchie-Studio/mcritchie-studio/pull/9")

    assert_difference -> { AgentMessage.where(channel: "slack").count }, 1 do
      ChangeBuilds.announce_submitted(card.reload)
      ChangeBuilds.announce_submitted(card.reload)
    end
    line = AgentMessage.find_by!(external_id: "change-build:combine-admin-links:submitted")
    assert_equal "Submitted for review, task `combine-admin-links`. https://github.com/McRitchie-Studio/mcritchie-studio/pull/9 · " \
                 "#{AgentProposal::BOARD_URL}/tasks/combine-admin-links", line.response_text
  end

  test "a card the launcher never started posts nothing at submitted; a web card's submitted line names no PR" do
    never = slack_card!("never-started")
    assert_no_difference -> { AgentMessage.count } do
      ChangeBuilds.announce_submitted(never)
    end

    web = chat_card!("web-card")
    ChangeBuilds.claim!(web.slug, worker: "mac", run: "r1", now: @t0)
    ChangeBuilds.finish!(web.slug, run: "r1", outcome: "started", desk: "/tmp/desk", now: @t0)
    web.reload.update_columns(pr_url: "https://github.com/McRitchie-Studio/turf-monster/pull/3")
    ChangeBuilds.announce_submitted(web.reload)
    line = AgentMessage.find_by!(channel: "web", external_id: "change-build:web-card:submitted")
    assert_equal [ "Submitted for review, task `web-card`.", "posted" ], [ line.response_text, line.reply_status ]
  end

  test "Task's after_commit announces the submitted move" do
    card = slack_card!("hooked-card")
    ChangeBuilds.claim!(card.slug, worker: "mac", run: "r1", now: @t0)
    ChangeBuilds.finish!(card.slug, run: "r1", outcome: "started", desk: "/tmp/desk", now: @t0)
    card.reload.update_columns(stage: "building")

    card.reload.update!(stage: "submitted")
    assert AgentMessage.exists?(external_id: "change-build:hooked-card:submitted")
  end

  test "starts? answers the executor: the owner's Slack go on an eligible repo, never a basic app or a docs kind" do
    card = slack_card!("asked")
    proposal = AgentProposal.find_by!("result->>'task_slug' = ?", card.slug)

    assert ChangeBuilds.starts?(proposal, repo: "mcritchie-studio", kind: "feature")
    refute ChangeBuilds.starts?(proposal, repo: "moms-app", kind: "feature")
    refute ChangeBuilds.starts?(proposal, repo: "mcritchie-studio", kind: "docs")
    proposal.update_columns(settled_by: "person:0")
    refute ChangeBuilds.starts?(proposal.reload, repo: "mcritchie-studio", kind: "feature")
  end
end
