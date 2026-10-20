# The board side of the automatic first version (.agents/epics/client-app-zero-to-one.md;
# runbook: docs/agents/system/client-build-launcher.md). bin/client-build-launcher on
# Alex's Mac drives it through Api::V1::ClientBuildsController:
#
#   candidates            designed launch tasks, oldest first, that a launcher may claim
#   claim!(slug, ...)     designed -> building, atomically, and the intake to build from
#   progress!(slug, ...)  one code-written line in the app owner's CTO chat
#   finish!(slug, ...)    preview_ready -> shipped; failed -> blocked with the reason;
#                         released -> designed (back in line), unless the app
#                         published during the run: then it ships; every
#                         outcome revokes the run's publish session
#
# WHICH TASKS. A launch task is the one an AppRequest names (AppRequest#task_slug,
# written by AppLaunch in the same transaction as the task), never a title match.
# Only a request whose App and AppCto exist (the AppLaunch path) has an intake to
# build from; an older AppRequest#queue! task is not listed.
#
# THE STAGE FLOW, and why it skips submitted/reviewed. A first version is a static
# bundle on the shared preview host, with no repository and no PR. `submitted`
# would put it in the PR review sweep (Task.reviewable), which would claim it and
# find nothing to review; `reviewed` would put it in the release conductor's queue
# under a repository that does not exist. So the bundle task never touches the Deploy
# lane: claim moves it designed -> building (Building lights only while a builder
# runs), and a published bundle moves it building -> shipped (the version is live
# at its preview address), with devops.included_in_release false as a second guard.
# A failure blocks it (Task#block!, a building attribute) with a qa_feedback row.
#
# devops.client_build holds the run: state (building, preview_ready, failed), the
# worker and run id that hold it, attempts, the version and preview_url, the reason.
# A launcher writes only the run it holds (run id match), so a stale or duplicate
# finish answers a refusal and changes nothing.
module ClientBuilds
  KEY = "client_build".freeze
  # The soul the build is recorded under (built_by), and the actor of a block.
  BUILDER = "pokemon".freeze
  ACTOR = "client-build-launcher".freeze
  CONFIG_PATH = Rails.root.join("config/client_builds.yml")
  REASON_LIMIT = 1000
  CANDIDATE_LIMIT = 25
  PROGRESS_KINDS = %w[started preview_ready failed].freeze
  VIA = "build_progress".freeze
  # preview_ready ships the task; failed blocks it; released (the launcher was
  # stopped, or found a run it had lost) puts it back in line, designed, for the
  # next claim. A release still spends the attempt, so a crash loop ends at
  # max_attempts with the task left for a person.
  OUTCOMES = %w[preview_ready failed released].freeze

  # A refusal the API answers 409 (or 404 for :not_found) with the reason.
  class Refused < StandardError
    attr_reader :code

    def initialize(code, message)
      @code = code
      super(message)
    end
  end

  module_function

  def config = @config ||= YAML.safe_load_file(CONFIG_PATH).freeze

  def preview_domain = config.fetch("preview_domain")
  def max_attempts = Integer(config.fetch("max_attempts"))

  def preview_url(subdomain) = "https://#{subdomain}.#{preview_domain}"

  # The requests whose task is a launch task with an intake (App + AppCto).
  def launch_requests
    AppRequest.where.not(task_slug: nil).where(status: AppRequest::HOLDING)
              .where(subdomain: AppCto.select(:app_slug))
  end

  # Designed, unblocked launch tasks, oldest first, each with what a launcher
  # needs to pick: attempts so far and whether someone else holds it (an assignee).
  def candidates(limit: CANDIDATE_LIMIT)
    requests = launch_requests.index_by(&:task_slug)
    Task.where(slug: requests.keys, stage: "designed", blocked_at: nil).order(:created_at, :id).limit(limit)
        .map { |task| candidate_json(task, requests.fetch(task.slug)) }
  end

  # The builds a worker holds right now (state building), for its orphan check at start.
  def in_flight(worker: nil)
    scope = Task.where(stage: "building").where("metadata->'devops'->'#{KEY}'->>'state' = 'building'")
    scope = scope.where("metadata->'devops'->'#{KEY}'->>'worker' = ?", worker.to_s) if worker.present?
    scope.order(:created_at).map { |task| { "task_slug" => task.slug, "run" => run_of(task)["run"], "worker" => run_of(task)["worker"] } }
  end

  def candidate_json(task, request)
    { "task_slug" => task.slug, "title" => task.title, "subdomain" => request.subdomain,
      "created_at" => task.created_at.iso8601, "attempts" => run_of(task)["attempts"].to_i,
      "assignee" => task.agent_slug.presence }
  end

  # designed -> building for `worker`'s run `run`, under a row lock, so two claims
  # never both win. Returns { "task" => ..., "intake" => ... }.
  def claim!(slug, worker:, run:, now: Time.current)
    raise Refused.new(:bad_request, "worker and run are required") if worker.blank? || run.blank?

    Task.transaction do
      task = Task.lock.find_by(slug: slug)
      raise Refused.new(:not_found, "task #{slug} not found") unless task

      request = AppRequest.find_by(task_slug: slug)
      app_cto = request && AppCto.find_by(app_slug: request.subdomain)
      raise Refused.new(:not_a_launch, "#{slug} is not a launch task with an intake") unless app_cto
      raise Refused.new(:taken, "#{slug} is #{task.blocked? ? 'blocked' : task.stage}, not designed") unless task.stage == "designed" && !task.blocked?
      raise Refused.new(:assigned, "#{slug} is assigned to #{task.agent_slug}") if task.agent_slug.present?

      attempts = run_of(task)["attempts"].to_i
      raise Refused.new(:attempts_spent, "#{slug} has used #{attempts} of #{max_attempts} build attempts") if attempts >= max_attempts

      write_run!(task, { "state" => "building", "worker" => worker.to_s, "run" => run.to_s, "attempts" => attempts + 1,
                         "started_at" => now.iso8601, "finished_at" => nil, "reason" => nil }, stage: "building")
      { "task" => { "slug" => task.slug, "stage" => task.stage }, "intake" => intake(request, app_cto) }
    end
  rescue ActiveRecord::RecordInvalid => e
    # The tier's lane cap (BuildingLanes) refuses the claim as a validation.
    raise Refused.new(:lane, e.record.errors.full_messages.to_sentence.presence || e.message)
  end

  # What the builder builds from. Every value but the subdomain and the URL was
  # written by the client; the launcher passes them to the model as quoted data.
  def intake(request, app_cto)
    answers = request.answers.is_a?(Hash) ? request.answers : {}
    { "task_slug" => request.task_slug, "subdomain" => request.subdomain, "app_name" => app_cto.app&.name,
      "prompt" => request.prompt.to_s, "title" => answers["title"], "idea" => answers["idea"],
      "features" => Array(answers["features"]), "audience" => answers["audience"], "day_one" => answers["day_one"],
      "palette" => AppPalette.normalize(app_cto.palette).merge("name" => (request.palette || {})["name"]).compact,
      "cto" => { "name" => app_cto.name, "portrait" => app_cto.portrait_asset ? app_cto.portrait : nil },
      "preview_url" => preview_url(request.subdomain) }
  end

  # The run's end. preview_ready: shipped, with the version and the preview URL.
  # failed: blocked, with the reason as a qa_feedback row. Either way the CTO chat
  # gets its line after the commit. Every outcome revokes the run's publish
  # session (revoke_sessions!).
  def finish!(slug, run:, outcome:, reason: nil, version: nil, now: Time.current)
    raise Refused.new(:bad_request, "outcome is #{OUTCOMES.join(', ')}") unless OUTCOMES.include?(outcome.to_s)

    outcome = outcome.to_s
    task = Task.transaction do
      task = held!(slug, run)
      revoke_sessions!(task)
      # A release of a run whose bundle already went live (the launcher stopped or
      # crashed between publish and finish): the preview is real, so the task
      # ships instead of going back in line to be rebuilt.
      if outcome == "released" && (published = published_during_run(task, slug))
        outcome = "preview_ready"
        version = published.version
      end
      if outcome == "preview_ready"
        subdomain = AppRequest.find_by!(task_slug: slug).subdomain
        write_run!(task, { "state" => "preview_ready", "version" => version.to_s.presence, "finished_at" => now.iso8601,
                           "preview_url" => preview_url(subdomain) }, stage: "shipped", extra: { "included_in_release" => false })
      elsif outcome == "released"
        write_run!(task, { "state" => "released", "finished_at" => now.iso8601,
                           "reason" => reason.to_s.squish.presence&.slice(0, REASON_LIMIT) }, stage: "designed")
      else
        why = reason.to_s.squish.presence || "the build failed without a reason"
        write_run!(task, { "state" => "failed", "finished_at" => now.iso8601, "reason" => why[0, REASON_LIMIT] })
        Current.set(task_event_actor: ACTOR) { task.block!(by: ACTOR, kind: "environment") }
        Activity.create!(task_slug: task.slug, activity_type: "qa_feedback",
                         description: "The first-version build failed: #{why[0, REASON_LIMIT]}",
                         metadata: { "summary" => "First-version build failed", "kind" => "environment", "agent_handle" => ACTOR })
      end
      task
    end
    announce(slug, outcome, run) unless outcome == "released"
    task
  end

  # The finish's chat line. The stage move has committed; a chat that cannot take
  # the line (no owner, a broadcast fault) is logged, never a failed finish.
  def announce(slug, kind, run)
    progress!(slug, kind: kind, run: run)
  rescue StandardError => e
    ErrorLog.capture!(e).tap { |log| log.target_name = slug }.save!
    nil
  end

  # One line in the owner's CTO chat, written by code from the launch's data (never
  # model or client prose), stored already answered so no dispatcher claims it, and
  # broadcast to the open chat. Idempotent per run and kind.
  def progress!(slug, kind:, run:, now: Time.current)
    raise Refused.new(:bad_request, "kind is one of #{PROGRESS_KINDS.join(', ')}") unless PROGRESS_KINDS.include?(kind.to_s)

    request = AppRequest.find_by(task_slug: slug)
    app_cto = request && AppCto.find_by(app_slug: request.subdomain)
    raise Refused.new(:not_a_launch, "#{slug} is not a launch task with an intake") unless app_cto && request.user

    external = "build:#{slug}:#{run}:#{kind}"
    existing = AgentMessage.find_by(channel: "web", external_id: external)
    return existing if existing

    user = request.user
    message = AgentMessage.create!(
      channel: "web", external_id: external, channel_ref: app_cto.app_slug,
      thread_key: AgentMessages::WebChat.thread_key(app_cto.app_slug, user.id), author_ref: user.id.to_s,
      author_name: app_cto.name, person: AgentMessages::WebIngest.person_for(user), content: content_marker(kind), mentions: {},
      sent_at: now, soul_slug: AppCto::SOUL, routed_by: "chat", status: "completed", completed_at: now,
      hold_released_at: now, hold_released_by: ACTOR, action_summary: "build progress (#{kind})",
      response_text: progress_line(kind.to_s, app_cto, request.subdomain), reply_posted_at: now, reply_status: "posted",
      envelope: { "via" => VIA, "kind" => kind.to_s, "task" => slug, "run" => run.to_s },
      run_meta: { "code_written" => true }
    )
    message.update!(reply_nonce: "agentmsg-#{message.id}", reply_external_id: "web:#{message.id}")
    message.record!("completed", actor: ACTOR, detail: { "via" => VIA, "kind" => kind.to_s })
    AgentMessages::WebChat.broadcast_turn(message, append: true)
    message
  end

  # The stored `content` (the column is required): a marker, not words the owner
  # sent. The chat shows only the CTO's line for a progress turn (progress?), and the
  # CTO's history reads the marker as what it is.
  def content_marker(kind) = "[build progress: #{kind}]"

  def progress?(message) = message.envelope.is_a?(Hash) && message.envelope["via"] == VIA

  def progress_line(kind, app_cto, subdomain)
    name = markdown_plain(app_cto.app&.name.presence || subdomain)
    case kind
    when "started"
      "I've started building the first version of #{name}. I'll post here the moment it's ready to try."
    when "preview_ready"
      host = "#{subdomain}.#{preview_domain}"
      "The first version of #{name} is ready: **[#{host}](#{preview_url(subdomain)})**. " \
        "Open it, try it, and tell me what you'd like changed."
    when "failed"
      "I hit a snag building the first version of #{name}. The team is looking at it, and I'll post here when it's moving again."
    end
  end

  # The client chose the app's name: shown as text, never as markdown.
  def markdown_plain(text) = text.to_s.gsub(/[\\`*_\[\]()#<>!|~]/) { |c| "\\#{c}" }

  def run_of(task)
    run = task.devops[KEY]
    run.is_a?(Hash) ? run : {}
  end

  # The newest bundle the task's app published since the run started, or nil.
  def published_during_run(task, slug)
    started = Time.iso8601(run_of(task)["started_at"].to_s) rescue nil
    subdomain = AppRequest.find_by(task_slug: slug)&.subdomain
    return nil unless started && subdomain

    AppPreviewVersion.where(app_slug: subdomain).where("published_at >= ?", started).newest_first.first
  end

  # The builder's task_claim logins on `task` (the launcher's publish session).
  # A failed run leaves the task building, blocked, where the login would stay
  # live until its 24-hour expiry; a finish of any outcome ends it here, server
  # side, so no launcher has to remember to. Only after held! has passed: a stale
  # run's finish revokes nothing.
  def revoke_sessions!(task)
    AgentSession.unrevoked.for_task(task.slug).where(tier: "studio", issued_by: "task_claim", soul: BUILDER)
                .update_all(revoked_at: Time.current, revoked_by: ACTOR)
  end

  # The task, locked, when `run` holds its build; else a refusal.
  def held!(slug, run)
    task = Task.lock.find_by(slug: slug)
    raise Refused.new(:not_found, "task #{slug} not found") unless task

    held = run_of(task)
    unless task.stage == "building" && held["state"] == "building" && held["run"].to_s == run.to_s && run.present?
      raise Refused.new(:not_held, "run #{run} does not hold #{slug}'s build (#{held['state'] || 'none'} run #{held['run'] || '-'})")
    end

    task
  end

  def write_run!(task, fields, stage: nil, extra: {})
    devops = task.devops.merge(extra).merge(KEY => run_of(task).merge(fields).compact)
    task.metadata = (task.metadata || {}).merge("devops" => devops)
    Current.set(task_event_actor: BUILDER, task_event_source: ACTOR) do
      task.stage = stage if stage
      task.save!
    end
  end
end
