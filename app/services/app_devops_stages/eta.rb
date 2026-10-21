class AppDevopsStages
  # How long the step a task is on usually takes, for the status card's ETA
  # (task app-card-stage-labels; .agents/epics/client-app-zero-to-one.md,
  # decision 4). Read from the board's own record, never guessed:
  #
  #   A task step (designed, building, submitted, reviewed, assembled) is the
  #   MEDIAN seconds_in_from of the last SAMPLE forward transitions out of it
  #   (TaskEvent, kind transition: designed → building, building → submitted,
  #   …, assembled → shipped), across the whole board.
  #   Deploying is the median of the last SAMPLE shipped releases' production
  #   deploys (prod_deploy_started_at → shipped_at).
  #
  # This is the board's one stage-duration spine, read the way TaskIntelligence's
  # stage-speed median reads it (median seconds_in_from by from_stage), here
  # windowed to the newest SAMPLE. Review::DurationRoll (a per-repo review-gate
  # span, capped at an hour) and Release::DurationCache (per-release ladders)
  # answer different questions and are not reused.
  #
  # The ETA is what is LEFT: the median less the time the task has already spent
  # on the step. Fewer than MIN_SAMPLES durations and there is no ETA at all (the
  # card shows the sub-label alone): a number from nothing would be a promise.
  #
  # THE COUNTDOWN (task live-build-countdown, Alex 2026-10-20). A step with a
  # real start (entered_at; never a designed task, whose created_at is not a
  # start) also carries its expected finish, `deadline` = entered_at + the usual
  # time. The pill paints it as a clock ("05:48", "1:02:03" from an hour up;
  # #clock) and app/javascript/devops_countdown.js ticks it each second; past
  # the deadline it reads "Any minute now", never a negative.
  #
  # CLIENT BUILDS. A client app's first version (a launch task run by
  # bin/client-build-launcher, devops.client_build) is not a hub task: one
  # builder writes one static bundle, capped at run_minutes, with no PR. The hub's
  # building -> submitted median (~30 min of PR work) does not describe it, and
  # its own move is building -> shipped, which that median never reads. So its
  # building time is the launcher's own record: the median started_at ->
  # finished_at of the last SAMPLE runs that ended preview_ready (the run the
  # launcher wrote, the builder's wall clock, queue wait excluded; a failed or
  # released run built nothing). With no such run yet it is
  # config/client_builds.yml typical_build_minutes. One run is enough: every
  # run is the same builder on the same config, unlike the board's mixed tasks.
  #
  # A DESIGNED task is waiting for someone to start it. Its ETA is minutes only
  # while a build launcher is live (#launcher_live?); with none the card says
  # "waiting for a builder", so it never promises a start nobody will make.
  module Eta
    SAMPLE = 20
    MIN_SAMPLES = 3
    CACHE_FOR = 10.minutes
    # The forward move that ends each task step: its duration is that
    # transition's seconds_in_from.
    NEXT_STAGE = { "designed" => "building", "building" => "submitted", "submitted" => "reviewed",
                   "reviewed" => "assembled", "assembled" => "shipped" }.freeze
    # When the task entered the step it is on (Task#set_stage_timestamp).
    ENTERED_AT = { "designed" => :created_at, "building" => :started_at, "submitted" => :submitted_at,
                   "reviewed" => :reviewed_at, "assembled" => :assembled_at }.freeze
    DEPLOYING = "deploying".freeze

    # THE LAUNCHER SEAM. The client build launcher (task client-build-launcher)
    # claims designed launch tasks and runs builders from Alex's Mac. It is live
    # when a dispatcher ping (AgentDispatcher, POST /api/v1/agent_dispatchers/ping)
    # carrying LAUNCHER_SOUL in its souls has been heard within
    # AgentDispatcher::SILENT_AFTER and is not paused. Until one pings, every
    # designed task reads "waiting for a builder".
    LAUNCHER_SOUL = "client-build-launcher".freeze

    # One step's ETA. `text` is short enough for a pill on a 360px phone;
    # `phrase` is the list row's wording. `kind`: :left (minutes left), :long
    # (past the usual time), :waiting (nobody to start it).
    # `deadline` is the expected finish (THE COUNTDOWN), or nil without a real start.
    Estimate = Struct.new(:text, :phrase, :kind, :seconds, :deadline, keyword_init: true) do
      def countdown? = deadline.present?
      # What the pill paints first: the clock to the deadline, or the rounded text.
      def pill_text(now: Time.current) = countdown? ? Eta.clock(deadline - now) : text
    end

    ANY_MINUTE = "Any minute now".freeze

    WAITING = Estimate.new(text: "no builder", phrase: "waiting for a builder", kind: :waiting).freeze

    module_function

    # The ETA for a task on `step` (a task stage, or DEPLOYING), or nil when the
    # board has too few durations. `entered_at` is when it reached the step;
    # `medians` is #medians' hash; `launcher` is #launcher_live?.
    def estimate(step, entered_at:, medians:, launcher:, now: Time.current)
      return WAITING if step == "designed" && !launcher

      usual = medians[step]
      return nil unless usual

      deadline = (entered_at + usual if entered_at && step != "designed")
      left = usual - (entered_at ? (now - entered_at).to_i : 0)
      return Estimate.new(text: ANY_MINUTE, phrase: "taking longer than usual", kind: :long, seconds: left, deadline: deadline) if left <= 0

      text = "~#{format_duration(left)}"
      Estimate.new(text: text, phrase: "#{text} left", kind: :left, seconds: left, deadline: deadline)
    end

    # The pill's clock: "05:48", "1:02:03" from an hour up; ANY_MINUTE at or past
    # zero. countdownClock in app/javascript/devops_countdown.js; the two must agree.
    def clock(seconds)
      total = seconds.to_f.floor
      return ANY_MINUTE if total <= 0

      hours, rest = total.divmod(3600)
      minutes, secs = rest.divmod(60)
      hours.positive? ? format("%d:%02d:%02d", hours, minutes, secs) : format("%02d:%02d", minutes, secs)
    end

    # A client build's usual seconds (CLIENT BUILDS): the median of the
    # launcher's last SAMPLE preview_ready runs, else the configured default.
    # Cached for CACHE_FOR.
    def client_build_usual
      Rails.cache.fetch([ "app_devops_eta", "client_build" ], expires_in: CACHE_FOR) do
        runs = client_build_durations
        runs.any? ? median(runs).round : Integer(ClientBuilds.config.fetch("typical_build_minutes")) * 60
      end
    end

    def client_build_durations
      run = "tasks.metadata -> 'devops' -> '#{ClientBuilds::KEY}'"
      Task.where("#{run} ->> 'state' = 'preview_ready'")
          .where("#{run} ->> 'started_at' IS NOT NULL AND #{run} ->> 'finished_at' IS NOT NULL")
          .order(Arel.sql("(#{run} ->> 'finished_at')::timestamptz DESC"))
          .limit(SAMPLE)
          .pluck(Arel.sql("EXTRACT(EPOCH FROM (#{run} ->> 'finished_at')::timestamptz - (#{run} ->> 'started_at')::timestamptz)"))
          .map(&:to_f).select(&:positive?)
    end

    # "~5 min", "~25 min", "~2 h", "~3 days": minutes to the nearest 5 past ten,
    # hours to the nearest hour past one.
    def format_duration(seconds)
      minutes = (seconds / 60.0).ceil
      return "#{[ minutes, 1 ].max} min" if minutes < 10
      return "#{((minutes / 5.0).round * 5).clamp(10, 55)} min" if minutes < 58

      hours = (minutes / 60.0).round
      return "#{hours} h" if hours < 24

      "#{(hours / 24.0).round} days"
    end

    # The usual seconds per step, for the steps asked: { "building" => 5400, … }.
    # A step with fewer than MIN_SAMPLES durations is absent. One query for the
    # task steps, one for Deploying; each cached for CACHE_FOR.
    def medians(steps)
      steps = steps.uniq
      task_steps = steps & NEXT_STAGE.keys
      result = task_steps.any? ? Rails.cache.fetch([ "app_devops_eta", "tasks", task_steps.sort ], expires_in: CACHE_FOR) { task_medians(task_steps) } : {}
      if steps.include?(DEPLOYING)
        deploy = Rails.cache.fetch([ "app_devops_eta", DEPLOYING ], expires_in: CACHE_FOR) { deploy_median }
        result = result.merge(DEPLOYING => deploy) if deploy
      end
      result
    end

    def task_medians(steps)
      pairs = steps.map { |step| "(#{TaskEvent.connection.quote(step)}, #{TaskEvent.connection.quote(NEXT_STAGE.fetch(step))})" }.join(", ")
      sql = <<~SQL.squish
        SELECT from_stage, percentile_cont(0.5) WITHIN GROUP (ORDER BY seconds_in_from) AS usual
        FROM (
          SELECT from_stage, seconds_in_from,
                 row_number() OVER (PARTITION BY from_stage ORDER BY occurred_at DESC, id DESC) AS recent
          FROM task_events
          WHERE kind = #{TaskEvent.connection.quote(TaskEvent::TRANSITION)} AND seconds_in_from > 0
            AND (from_stage, to_stage) IN (#{pairs})
        ) durations
        WHERE recent <= #{SAMPLE.to_i}
        GROUP BY from_stage
        HAVING count(*) >= #{MIN_SAMPLES.to_i}
      SQL
      TaskEvent.connection.select_rows(sql).to_h { |stage, usual| [ stage, usual.to_f.round ] }
    end

    def deploy_median
      durations = Release.where.not(shipped_at: nil).where.not(prod_deploy_started_at: nil)
                         .where("shipped_at > prod_deploy_started_at")
                         .order(shipped_at: :desc).limit(SAMPLE)
                         .pluck(Arel.sql("EXTRACT(EPOCH FROM shipped_at - prod_deploy_started_at)")).map(&:to_f)
      durations.size >= MIN_SAMPLES ? median(durations).round : nil
    end

    def median(list)
      sorted = list.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    # See THE LAUNCHER SEAM.
    def launcher_live?(now: Time.current)
      AgentDispatcher.where(last_seen_at: (now - AgentDispatcher::SILENT_AFTER)..)
                     .where("souls @> ?", [ LAUNCHER_SOUL ].to_json)
                     .where("paused_until IS NULL OR paused_until < ?", now)
                     .exists?
    end
  end
end
