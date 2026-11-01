# Change cards start their builder (runbook: docs/agents/system/client-build-launcher.md,
# "Change cards"). An owner's `go` on a change proposal in an app's web chat, or
# Alex McRitchie's own `go` in Slack or Teams, opens a `designed` card
# (AgentProposals::Executor#change); bin/client-build-launcher on
# Alex McRitchie's Mac picks that card up here, runs `bin/task begin` for it, and reports
# back, so the card reaches `building` with a desk and nobody has to notice it.
#
#   candidates            designed change cards a launcher may start, oldest first
#   claim!(slug, ...)     records the launcher's start (state starting) under a row lock
#   finish!(slug, ...)    started: the desk is cut and the card is building; posts the
#                         one message back in the card's thread and the builder launch
#                         line to the ops channel. refused: bin/task begin failed; the
#                         card stays designed and the floor alert opens one
#                         change_build_refused incident for it.
#   announce_submitted    a started card reaching `submitted` (Task's after_commit)
#                         posts one line in the same thread: submitted for review,
#                         with the PR on an owner's Slack or Teams thread.
#   builder_candidates    started cards whose headless builder the launcher may run
#   builder_claim!        records a builder run (builder state running) and answers
#                         the brief's card fields; the thread hears it started
#   builder_finish!       finished (the board reads the stage: submitted, or failed
#                         when the card never got there), failed, or released (the
#                         launcher stopped); a failure is told in the thread and
#                         raised by the floor alert (change_build_refused, per card)
#
# WHICH CARDS, every rule required (never a title match):
#   - stage designed, not blocked, nobody assigned, not a launch task (AppRequest)
#   - devops.kind feature, bug or chore, and devops.source_thread present
#   - exactly one repository, an app in config/apps.yml that is live and tier
#     studio or product (a basic-tier app is not started)
#   - CONFIRMED: an AgentProposal of kind change, status executed, settled by the
#     person who said go, whose result names this card's slug. The executor writes
#     that result after the owner's go ran (AgentProposalJob), so a card the owner
#     never confirmed has no such row and is never started. Its channel is either
#       web    an app owner's go on their own app's CTO thread (ProposalConfirm's
#              owner_verdict), as before; or
#       slack / teams  ONLY Alex McRitchie's go (owner_go?): the go message's
#              person holds the owner role, the proposal was settled by that
#              person, and the go's author is the medium's configured owner user
#              (config/agent_routes.yml slack.owner_user_id, teams.owner_aad_object_id).
#              A team member's or anyone else's go in Slack never starts a build,
#              even where ProposalConfirm let it confirm the card.
#     The repo rule is the same for both: the hub (tier studio) and Turf Monster
#     (tier product) are already eligible, so an owner's Slack card on either starts;
#     a basic-tier app or a library waits for a session on every channel.
#   - its start not already recorded: never started, a refusal past RETRY_AFTER, or
#     a start left `starting` past STALE_AFTER (a launcher that died mid-begin); at
#     most max_attempts starts (config/client_builds.yml, the same limit launch
#     tasks take).
#
# WHERE THE LAUNCHER STOPS. For an app owner's WEB card it stops at the desk: its
# instructions came from a client's chat, and a hub app's builder needs a desk, a
# database, gh credentials and bin/submit, so the launch line goes to the ops
# channel and onto the card (devops.change_build.launch_line) for a session.
#
# THE CHANGE BUILDER (devops.change_build.builder). For a card ALEX McRITCHIE'S
# OWN go opened (owner_go?) and while config/client_builds.yml `change_builder`
# is enabled, the start records builder state `pending` and the launcher then runs
# a headless Pokémon in the desk (ClientBuildLauncher::ChangeBuilder) that follows
# the DevOps cycle to `submitted` with bin/submit-wait. Its brief is built only
# from this card's fields (builder_json), fenced as data. States:
#   pending   offered to the launcher
#   running   a run holds it (worker, run, started_at); a run left running past
#             run_minutes + BUILDER_GRACE is offered again (a launcher that died)
#   submitted the run ended and the card had reached submitted (or later)
#   failed    the run ended short (timeout, crash, never submitted); offered again
#             after RETRY_AFTER until change_builder.max_attempts, then left for a
#             session; the floor alert raises it either way
# The board, not the builder, says whether it submitted: finished reads the stage.
module ChangeBuilds
  KEY = "change_build".freeze
  ACTOR = "client-build-launcher".freeze
  BUILDER = "pokemon".freeze
  KINDS = %w[feature bug chore].freeze
  # The channels a confirming proposal may be on: web (an app owner) and the chat
  # media where only Alex McRitchie's own go counts (OWNER_ROUTES).
  CHANNELS = %w[web slack teams].freeze
  OWNER_ROUTES = { "slack" => "AgentMessages::SlackRoutes", "teams" => "AgentMessages::TeamsRoutes" }.freeze
  TIERS = %w[studio product].freeze
  OUTCOMES = %w[started refused].freeze
  BUILDER_OUTCOMES = %w[finished failed released].freeze
  # The stages a card the builder submitted can be in by the time its run ends.
  SUBMITTED_STAGES = %w[submitted reviewed assembled shipped archived].freeze
  BUILDER_GRACE = 15.minutes
  RETRY_AFTER = 10.minutes
  STALE_AFTER = 30.minutes
  CANDIDATE_LIMIT = 25
  REASON_LIMIT = 300
  HUB = "/Users/alex/projects/mcritchie-studio".freeze
  TASK_BIN = "/Users/alex/projects/.agents/bin/task".freeze
  # An absolute desk path as bin/task begin prints it: no space, quote or shell character.
  DESK_RULE = %r{\A/[A-Za-z0-9._/-]+\z}

  class Refused < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  module_function

  def max_attempts = ClientBuilds.max_attempts

  def run_of(task)
    run = task.devops[KEY]
    run.is_a?(Hash) ? run : {}
  end

  # The repos whose apps may be started: live, tier studio or product.
  def eligible_repos = AppCatalog.apps.select { |app| app.live? && TIERS.include?(app.tier) }.map(&:slug)

  # slug => the confirmed proposal that opened it, for the given slugs.
  def confirmed_proposals(slugs)
    return {} if slugs.empty?

    AgentProposal.where(kind: "change", channel: CHANNELS, status: "executed").where.not(settled_by: [ nil, "" ])
                 .where("agent_proposals.result->>'task_slug' IN (?)", slugs).includes(confirm_message: :person).order(:id)
                 .select { |proposal| confirmer_may_start?(proposal) }
                 .index_by { |proposal| proposal.result["task_slug"] }
  end

  # Whoever said go may have the card started: an app owner on web (ProposalConfirm
  # already held them to their own app's thread), or Alex McRitchie in Slack/Teams.
  def confirmer_may_start?(proposal) = proposal.channel == "web" || owner_go?(proposal)

  # ALEX McRITCHIE'S OWN GO in Slack or Teams, from facts code wrote (never the
  # message text): the go is on the proposal's medium, its person holds the owner
  # role and settled the proposal, and its author is the medium's configured owner
  # user. A blank configured id (Teams before its tenant exists) answers false.
  def owner_go?(proposal)
    routes = OWNER_ROUTES[proposal.channel.to_s]
    go = proposal.confirm_message
    return false unless routes && go && go.channel == proposal.channel && go.person&.role == "owner"
    return false unless proposal.settled_by.to_s == "person:#{go.person_id}"

    owner = routes.constantize.current.owner_user_id.to_s.strip
    owner.present? && go.author_ref.to_s == owner
  end

  # Whether the launcher will pick up the card this confirmed proposal opens in
  # `repo`: the executor's go answer says so only when it will.
  def starts?(proposal, repo:, kind:)
    confirmer_may_start?(proposal) && KINDS.include?(kind.to_s) && eligible_repos.include?(repo.to_s)
  end

  def chat?(proposal) = OWNER_ROUTES.key?(proposal.channel.to_s)

  # The change_builder section of config/client_builds.yml; a missing one is off.
  def builder_config
    section = ClientBuilds.config["change_builder"]
    section.is_a?(Hash) ? section : {}
  end

  def builder_enabled? = builder_config["enabled"] == true
  def builder_max_attempts = Integer(builder_config.fetch("max_attempts", 2))
  def builder_run_minutes = Integer(builder_config.fetch("run_minutes", 90))

  # Whether a start of the card this proposal confirmed also runs the headless
  # builder: only Alex McRitchie's own Slack or Teams go, and only while enabled.
  def builds?(proposal) = !proposal.nil? && builder_enabled? && owner_go?(proposal)

  def builder_of(task)
    builder = run_of(task)["builder"]
    builder.is_a?(Hash) ? builder : {}
  end

  def candidates(limit: CANDIDATE_LIMIT, now: Time.current)
    repos = eligible_repos
    return [] if repos.empty?

    scope = Task.where(stage: "designed", blocked_at: nil, agent_slug: [ nil, "" ])
                .where("tasks.metadata->'devops'->>'kind' IN (?)", KINDS)
                .where("COALESCE(tasks.metadata->'devops'->>'source_thread', '') <> ''")
                .where("jsonb_array_length(COALESCE(tasks.metadata->'devops'->'repositories', '[]'::jsonb)) = 1")
                .where("tasks.metadata->'devops'->'repositories'->>0 IN (?)", repos)
                .where.not(slug: AppRequest.where.not(task_slug: nil).select(:task_slug))
                .order(:created_at, :id).to_a
    proposals = confirmed_proposals(scope.map(&:slug))
    picked = scope.select { |task| proposals.key?(task.slug) && startable?(task, now) }
    (limit ? picked.first(limit) : picked).map { |task| candidate_json(task, proposals.fetch(task.slug)) }
  end

  def startable?(task, now)
    run = run_of(task)
    return false if run["attempts"].to_i >= max_attempts

    at = parse_time(run["finished_at"] || run["started_at"])
    case run["state"]
    when nil then true
    when "refused" then at.nil? || at <= now - RETRY_AFTER
    when "starting" then at.nil? || at <= now - STALE_AFTER
    else false
    end
  end

  def candidate_json(task, proposal)
    { "task_slug" => task.slug, "title" => task.title, "repo" => task.devops["repositories"].first,
      "kind" => task.devops["kind"], "proposal_id" => proposal.id, "created_at" => task.created_at.iso8601,
      "attempts" => run_of(task)["attempts"].to_i }
  end

  # Records the start under the task's row lock, so two launchers never both win.
  def claim!(slug, worker:, run:, now: Time.current)
    raise Refused.new(:bad_request, "worker and run are required") if worker.blank? || run.blank?

    Task.transaction do
      task = Task.lock.find_by(slug: slug)
      raise Refused.new(:not_found, "task #{slug} not found") unless task
      unless candidates(limit: nil, now: now).any? { |c| c["task_slug"] == slug }
        raise Refused.new(:not_a_candidate, "#{slug} is not a startable change card (#{task.stage}, #{run_of(task)['state'] || 'never started'})")
      end

      attempts = run_of(task)["attempts"].to_i
      write_run!(task, { "state" => "starting", "worker" => worker.to_s, "run" => run.to_s, "attempts" => attempts + 1,
                         "started_at" => now.iso8601, "finished_at" => nil })
      { "task_slug" => task.slug, "repo" => task.devops["repositories"].first, "attempts" => attempts + 1 }
    end
  end

  # The launcher's report on its start. started: the desk is cut (`desk`, the path
  # bin/task begin printed); refused: bin/task begin failed with `reason`.
  def finish!(slug, run:, outcome:, reason: nil, desk: nil, now: Time.current)
    raise Refused.new(:bad_request, "outcome is #{OUTCOMES.join(' or ')}") unless OUTCOMES.include?(outcome.to_s)

    task = Task.transaction do
      task = Task.lock.find_by(slug: slug)
      raise Refused.new(:not_found, "task #{slug} not found") unless task

      held = run_of(task)
      unless held["state"] == "starting" && held["run"].to_s == run.to_s && run.present?
        raise Refused.new(:not_held, "run #{run} does not hold #{slug}'s start (#{held['state'] || 'none'} run #{held['run'] || '-'})")
      end

      if outcome.to_s == "started"
        desk = desk.to_s.match?(DESK_RULE) ? desk.to_s : nil
        builds = desk && builds?(confirmed_proposals([ slug ])[slug])
        write_run!(task, { "state" => "started", "finished_at" => now.iso8601, "desk" => desk,
                           "launch_line" => launch_line(slug, desk), "refused_reason" => nil,
                           "builder" => ({ "state" => "pending", "attempts" => 0 } if builds) })
      else
        why = reason.to_s.squish.presence || "bin/task begin failed without a reason"
        write_run!(task, { "state" => "refused", "finished_at" => now.iso8601, "refused_reason" => why[0, REASON_LIMIT] })
      end
      task
    end
    announce_started(task) if outcome.to_s == "started"
    task
  end

  # The one command that starts the card's builder in its desk.
  def launch_line(slug, desk)
    "cd #{desk || HUB} && claude --agent #{BUILDER} \"Build task #{slug} to submitted: run #{TASK_BIN} begin #{slug} " \
      "to take the desk, then building-sop from Step 2.\""
  end

  # The thread's line. On the owner's own Slack or Teams thread it carries the
  # launch line too: he is the operator who runs it.
  def thread_text(task, proposal = nil)
    line = "Building started, task `#{task.slug}`."
    launch = run_of(task)["launch_line"]
    return line unless proposal && chat?(proposal) && launch.present?
    if builder_of(task).present?
      return "#{line} Its desk is cut and the card is building; a headless Pokémon builder takes it to submitted next."
    end

    "#{line} Its desk is cut and the card is building; start its builder with: `#{launch}`"
  end

  # The builder's own thread lines (owner chat threads only: only owner_go? cards
  # get a builder).
  def builder_text(task, kind)
    builder = builder_of(task)
    case kind
    when "builder-started"
      "Builder running, task `#{task.slug}`: a headless Pokémon is building it in its desk " \
        "(attempt #{builder['attempts']} of #{builder_max_attempts}, up to #{builder_run_minutes} min)."
    else
      retry_text = if builder["attempts"].to_i < builder_max_attempts
                     "The launcher tries again in #{RETRY_AFTER.inspect}."
                   else
                     "No attempts left; a session can continue it from the desk: `#{run_of(task)['launch_line']}`"
                   end
      "Builder stopped, task `#{task.slug}`: #{builder['reason']}. #{retry_text}"
    end
  end

  def submitted_text(task, proposal)
    line = "Submitted for review, task `#{task.slug}`."
    return line unless chat?(proposal)

    "#{line} #{[ task.pr_url.presence, proposal.task_url(task.slug) ].compact.join(' · ')}"
  end

  def ops_text(task, proposal = confirmed_proposals([ task.slug ])[task.slug])
    run = run_of(task)
    from = proposal ? proposal.requested_in : "a chat"
    "Change build started: `#{task.slug}` (#{task.devops['repositories'].first}, from #{from}) is building " \
      "with its desk#{run['desk'] ? " at #{run['desk']}" : ''}. Start its builder: `#{run['launch_line']}`"
  end

  # After the commit: the thread's one message and the ops line. Neither failing
  # undoes the start; each failure is an ErrorLog row.
  def announce_started(task)
    proposal = confirmed_proposals([ task.slug ])[task.slug]
    safely(task) { post_to_thread!(task, proposal) } if proposal
    safely(task) { post_to_ops!(task, proposal: proposal) }
  end

  # A card the launcher started, reaching `submitted`: one line in its thread.
  # Called from Task's after_commit; never raises (a failure is an ErrorLog row).
  def announce_submitted(task)
    return unless run_of(task)["state"] == "started"

    safely(task) do
      proposal = confirmed_proposals([ task.slug ])[task.slug]
      post_to_thread!(task, proposal, kind: "submitted") if proposal
    end
  end

  def safely(task)
    yield
  rescue StandardError => e
    ErrorLog.capture!(e).tap { |log| log.target_name = "change build #{task.slug}" }.save!
    nil
  end

  # One code-written line in the thread the proposal came from, idempotent per
  # card and kind (external_id). On web it is stored already answered, so no
  # dispatcher claims it. On Slack or Teams it is stored completed with its reply
  # queued, so the one reply path (AgentMessageReplyJob, Media#deliver_reply)
  # posts it in that thread as the proposal's soul.
  def post_to_thread!(task, proposal, kind: "started", now: Time.current)
    external = "change-build:#{task.slug}:#{kind}"
    external += ":#{builder_of(task)['attempts'].to_i}" if kind.start_with?("builder-")
    existing = AgentMessage.find_by(channel: proposal.channel, external_id: external)
    return existing if existing

    text = case kind
           when "submitted" then submitted_text(task, proposal)
           when "started" then thread_text(task, proposal)
           else builder_text(task, kind)
           end
    source = proposal.confirm_message || proposal.source_message
    web = proposal.channel == "web"
    envelope = (web ? {} : source&.envelope.to_h.slice("service_url", "conversation_id", "activity_id", "from_id", "channel_type"))
                 .merge("via" => ClientBuilds::VIA, "kind" => kind, "task" => task.slug)
    message = AgentMessage.create!(
      channel: proposal.channel, external_id: external, channel_ref: proposal.channel_ref, thread_key: proposal.thread_key,
      guild_id: proposal.guild_id, author_ref: source&.author_ref, author_name: source&.author_name, person: proposal.person,
      content: ClientBuilds.content_marker(kind), mentions: {}, sent_at: now, soul_slug: proposal.soul_slug,
      routed_by: web ? "chat" : "thread", status: "completed", completed_at: now, hold_released_at: now,
      hold_released_by: ACTOR, action_summary: "build progress (#{kind})", response_text: text,
      reply_posted_at: (now if web), reply_status: web ? "posted" : "queued", envelope: envelope,
      run_meta: { "code_written" => true }
    )
    message.update!({ reply_nonce: "agentmsg-#{message.id}" }.merge(web ? { reply_external_id: "web:#{message.id}" } : {}))
    message.record!("completed", actor: ACTOR, detail: { "via" => ClientBuilds::VIA, "kind" => kind })
    if web
      AgentMessages::WebChat.broadcast_turn(message, append: true)
    else
      AgentMessageReplyJob.perform_later(message.id)
    end
    message
  end

  # The ops line goes to the floor alert's home (config/agent_media.yml
  # `purposes.floor_alert`: discord #ops), as the shared bot.
  def post_to_ops!(task, home: Media.home(purpose: :floor_alert), bot: nil, proposal: nil)
    return if home.nil? || !home.channel?
    return if home.medium == "discord" && bot.nil? && !AgentMessages::DiscordBot.configured?

    payload = { content: (proposal ? ops_text(task, proposal) : ops_text(task))[0, 1900], nonce: "chb-#{task.id}-#{run_of(task)['attempts'].to_i}" }
    payload[:bot] = bot if bot
    Media.post(home, **payload)
  end

  # Started cards whose headless builder may run now, oldest first: building, not
  # blocked, a builder recorded at the start, still Alex McRitchie's own go, and
  # startable (builder_startable?). Empty while the switch is off.
  def builder_candidates(limit: CANDIDATE_LIMIT, now: Time.current)
    return [] unless builder_enabled?

    scope = Task.where(stage: "building", blocked_at: nil)
                .where("tasks.metadata->'devops'->'#{KEY}'->>'state' = 'started'")
                .where("tasks.metadata->'devops'->'#{KEY}'->'builder' IS NOT NULL")
                .order(:created_at, :id).to_a
    proposals = confirmed_proposals(scope.map(&:slug))
    picked = scope.select { |task| builds?(proposals[task.slug]) && builder_startable?(task, now) }
    (limit ? picked.first(limit) : picked).map { |task| builder_json(task) }
  end

  def builder_startable?(task, now)
    builder = builder_of(task)
    return false if run_of(task)["desk"].blank? || builder["attempts"].to_i >= builder_max_attempts

    case builder["state"]
    when "pending" then true
    when "failed" then (at = parse_time(builder["finished_at"])).nil? || at <= now - RETRY_AFTER
    when "running" then (at = parse_time(builder["started_at"])).nil? || at <= now - (builder_run_minutes.minutes + BUILDER_GRACE)
    else false
    end
  end

  # The card fields a builder brief is built from, and nothing else: never the
  # task's description or a chat message.
  def builder_json(task)
    devops = task.devops
    { "task_slug" => task.slug, "title" => task.title, "repo" => devops["repositories"].first,
      "kind" => devops["kind"], "shape" => devops["shape"], "acceptance" => Array(devops["acceptance"]),
      "test_plan" => Array(devops["test_plan"]), "risk_tags" => Array(devops["risk_tags"]),
      "source_thread" => devops["source_thread"], "desk" => run_of(task)["desk"],
      "created_at" => task.created_at.iso8601, "attempts" => builder_of(task)["attempts"].to_i }
  end

  # Records a builder run under the card's row lock; answers the brief's fields.
  def builder_claim!(slug, worker:, run:, now: Time.current)
    raise Refused.new(:bad_request, "worker and run are required") if worker.blank? || run.blank?

    task = Task.transaction do
      task = Task.lock.find_by(slug: slug)
      raise Refused.new(:not_found, "task #{slug} not found") unless task
      unless builder_candidates(limit: nil, now: now).any? { |c| c["task_slug"] == slug }
        raise Refused.new(:not_a_candidate, "#{slug} has no builder to run (#{task.stage}, builder #{builder_of(task)['state'] || 'none'})")
      end

      write_builder!(task, { "state" => "running", "worker" => worker.to_s, "run" => run.to_s,
                             "attempts" => builder_of(task)["attempts"].to_i + 1, "started_at" => now.iso8601,
                             "finished_at" => nil, "reason" => nil, "log" => nil })
      task
    end
    announce_builder(task, "builder-started")
    builder_json(task)
  end

  # The launcher's report on a builder run. finished: the run exited by itself,
  # and the stage decides (submitted, or failed: it never got there). failed: a
  # timeout, a turn cap, a crash, or a brief the launcher refused to run. released:
  # the launcher stopped; back to pending, the attempt spent.
  def builder_finish!(slug, run:, outcome:, reason: nil, log: nil, now: Time.current)
    raise Refused.new(:bad_request, "outcome is #{BUILDER_OUTCOMES.join(', ')}") unless BUILDER_OUTCOMES.include?(outcome.to_s)

    task = Task.transaction do
      task = Task.lock.find_by(slug: slug)
      raise Refused.new(:not_found, "task #{slug} not found") unless task

      held = builder_of(task)
      unless held["state"] == "running" && held["run"].to_s == run.to_s && run.present?
        raise Refused.new(:not_held, "run #{run} does not hold #{slug}'s builder (#{held['state'] || 'none'} run #{held['run'] || '-'})")
      end

      state, why = case outcome.to_s
                   when "released" then [ "pending", nil ]
                   when "finished"
                     if SUBMITTED_STAGES.include?(task.stage) then [ "submitted", nil ]
                     else [ "failed", "the builder exited without reaching submitted (the card is #{task.stage})" ]
                     end
                   else [ "failed", reason.to_s.squish.presence || "the builder failed without a reason" ]
                   end
      write_builder!(task, { "state" => state, "finished_at" => now.iso8601, "reason" => why&.slice(0, REASON_LIMIT),
                             "log" => (log.to_s if log.to_s.match?(DESK_RULE)) })
      task
    end
    announce_builder(task, "builder-failed") if builder_of(task)["state"] == "failed"
    task
  end

  def announce_builder(task, kind)
    safely(task) do
      proposal = confirmed_proposals([ task.slug ])[task.slug]
      post_to_thread!(task, proposal, kind: kind) if proposal
    end
  end

  # Cards whose builder failed and that never reached submitted: the floor
  # alert's per-card change_build_refused check names each.
  def failed_builders
    Task.where(stage: "building")
        .where("tasks.metadata->'devops'->'#{KEY}'->'builder'->>'state' = 'failed'").order(:id).to_a
  end

  def parse_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def write_builder!(task, fields)
    write_run!(task, { "builder" => builder_of(task).merge(fields).compact })
  end

  def write_run!(task, fields)
    devops = task.devops.merge(KEY => run_of(task).merge(fields).compact)
    task.metadata = (task.metadata || {}).merge("devops" => devops)
    Current.set(task_event_actor: BUILDER, task_event_source: ACTOR) { task.save! }
  end
end
