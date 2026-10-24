# Change cards start their builder (runbook: docs/agents/system/client-build-launcher.md,
# "Change cards"). An owner's `go` on a change proposal in an app's web chat opens a
# `designed` card (AgentProposals::Executor#change); bin/client-build-launcher on
# Alex's Mac picks that card up here, runs `bin/task begin` for it, and reports
# back, so the card reaches `building` with a desk and nobody has to notice it.
#
#   candidates            designed change cards a launcher may start, oldest first
#   claim!(slug, ...)     records the launcher's start (state starting) under a row lock
#   finish!(slug, ...)    started: the desk is cut and the card is building; posts the
#                         one message back in the card's thread and the builder launch
#                         line to the ops channel. refused: bin/task begin failed; the
#                         card stays designed and the floor alert opens one
#                         change_build_refused incident for it.
#
# WHICH CARDS, every rule required (never a title match):
#   - stage designed, not blocked, nobody assigned, not a launch task (AppRequest)
#   - devops.kind feature, bug or chore, and devops.source_thread present
#   - exactly one repository, an app in config/apps.yml that is live and tier
#     studio or product (a basic-tier app is not started)
#   - CONFIRMED: an AgentProposal of kind change, channel web, status executed,
#     settled by the person who said go, whose result names this card's slug. The
#     executor writes that result after the owner's go ran (AgentProposalJob), so a
#     card the owner never confirmed has no such row and is never started.
#   - its start not already recorded: never started, a refusal past RETRY_AFTER, or
#     a start left `starting` past STALE_AFTER (a launcher that died mid-begin); at
#     most max_attempts starts (config/client_builds.yml, the same limit launch
#     tasks take).
#
# WHY THE LAUNCHER STOPS AT THE DESK. The launcher's builder is a sandboxed
# headless Claude built for static client bundles: no secrets in its environment,
# no file outside its run directory, no git, no network beyond the model. A hub
# app's builder needs the opposite (a desk in a primary checkout, a database, gh
# credentials to push and open a PR, bin/submit), and its instructions would come
# from a chat message. So the launcher runs our own `bin/task begin` (desk, claim,
# Avi's scout) and the one-command builder launch line goes to the ops channel and
# onto the card (devops.change_build.launch_line) for a session to run.
module ChangeBuilds
  KEY = "change_build".freeze
  ACTOR = "client-build-launcher".freeze
  BUILDER = "pokemon".freeze
  KINDS = %w[feature bug chore].freeze
  TIERS = %w[studio product].freeze
  OUTCOMES = %w[started refused].freeze
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

    AgentProposal.where(kind: "change", channel: "web", status: "executed").where.not(settled_by: [ nil, "" ])
                 .where("agent_proposals.result->>'task_slug' IN (?)", slugs).order(:id)
                 .index_by { |proposal| proposal.result["task_slug"] }
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
        write_run!(task, { "state" => "started", "finished_at" => now.iso8601, "desk" => desk,
                           "launch_line" => launch_line(slug, desk), "refused_reason" => nil })
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

  def thread_text(slug) = "Building started, task `#{slug}`."

  def ops_text(task)
    run = run_of(task)
    "Change build started: `#{task.slug}` (#{task.devops['repositories'].first}, from the app's web chat) is building " \
      "with its desk#{run['desk'] ? " at #{run['desk']}" : ''}. Start its builder: `#{run['launch_line']}`"
  end

  # After the commit: the thread's one message and the ops line. Neither failing
  # undoes the start; each failure is an ErrorLog row.
  def announce_started(task)
    proposal = confirmed_proposals([ task.slug ])[task.slug]
    safely(task) { post_to_thread!(task, proposal) } if proposal
    safely(task) { post_to_ops!(task) }
  end

  def safely(task)
    yield
  rescue StandardError => e
    ErrorLog.capture!(e).tap { |log| log.target_name = "change build #{task.slug}" }.save!
    nil
  end

  # One code-written line in the web thread the proposal came from, stored already
  # answered so no dispatcher claims it, and idempotent per card (external_id).
  def post_to_thread!(task, proposal, now: Time.current)
    external = "change-build:#{task.slug}:started"
    existing = AgentMessage.find_by(channel: "web", external_id: external)
    return existing if existing

    source = proposal.confirm_message || proposal.source_message
    message = AgentMessage.create!(
      channel: "web", external_id: external, channel_ref: proposal.channel_ref, thread_key: proposal.thread_key,
      author_ref: source&.author_ref, author_name: source&.author_name, person: proposal.person,
      content: ClientBuilds.content_marker("started"), mentions: {}, sent_at: now, soul_slug: proposal.soul_slug,
      routed_by: "chat", status: "completed", completed_at: now, hold_released_at: now, hold_released_by: ACTOR,
      action_summary: "build progress (started)", response_text: thread_text(task.slug), reply_posted_at: now,
      reply_status: "posted", envelope: { "via" => ClientBuilds::VIA, "kind" => "started", "task" => task.slug },
      run_meta: { "code_written" => true }
    )
    message.update!(reply_nonce: "agentmsg-#{message.id}", reply_external_id: "web:#{message.id}")
    message.record!("completed", actor: ACTOR, detail: { "via" => ClientBuilds::VIA, "kind" => "started" })
    AgentMessages::WebChat.broadcast_turn(message, append: true)
    message
  end

  def post_to_ops!(task, routes: AgentMessages::Routes.load, bot: nil)
    return if routes.ops_channel_id.nil? || (bot.nil? && !AgentMessages::DiscordBot.configured?)

    (bot || AgentMessages::DiscordBot.new).post_message(routes.ops_channel_id, content: ops_text(task)[0, 1900],
                                                                               nonce: "chb-#{task.id}-#{run_of(task)['attempts'].to_i}")
  end

  def parse_time(value)
    value.present? ? Time.zone.parse(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def write_run!(task, fields)
    devops = task.devops.merge(KEY => run_of(task).merge(fields).compact)
    task.metadata = (task.metadata || {}).merge("devops" => devops)
    Current.set(task_event_actor: BUILDER, task_event_source: ACTOR) { task.save! }
  end
end
