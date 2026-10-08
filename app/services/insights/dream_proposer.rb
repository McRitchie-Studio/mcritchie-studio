# frozen_string_literal: true

require Rails.root.join("bin/lib/dream_bank").to_s

module Insights
  # Drafts ONE proposed dream for a graded task whose notes carry a signal, and
  # files it as the triage finding dream-proposal-<task-slug>. The finding's body
  # is the dream file; `bin/dream propose --materialize` writes it into a desk.
  #
  # Note text is read to DETECT a signal and never reaches a draft. A draft is a
  # template filled from: the task's slug, title, shape, repositories and risk
  # tags; each source activity's slug; soul slugs; the ruling's verdict word.
  #
  # A draft the privacy screen flags is dropped. `.propose` never raises.
  class DreamProposer
    SLUG_PREFIX = "dream-proposal-"
    FINDING_SOURCE = "task-grader"
    CONTEST_PREFIX = "CONTEST:"
    RULING = /\ARULING:\s*(ACCEPT|OVERRULE|SPLIT)\b/
    SCOUT_KIND = "scout_report"
    LEARNING_KIND = "learning"
    TITLE_LIMIT = 80
    ACTIVITY_SLUG = /\bactivity-\d+\b/

    # What the privacy screen refuses, by reason key.
    PRIVACY_PATTERNS = {
      "email" => /[\w.+-]+@[\w-]+\.[a-z]{2,}/i,
      "phone" => /\(?\b\d{3}\)?[\s.-]\d{3}[\s.-]\d{4}\b/,
      "money" => /[$€£]\s?\d|\b\d[\d,.]*\s?(?:usdc?|dollars?|bucks|sol)\b/i,
      "digit_run" => /\d{6,}|\b\d{1,3}(?:,\d{3})+\b/
    }.freeze

    TEMPLATES = {
      "overruled_block" => {
        question: "A reviewer blocks my PR and I can show the block names no reachable regression: do I fix it anyway?",
        answer: "Contest it with the evidence, through the session that spawned me, and let the arbiter rule.",
        why: "A fix for a finding that is not reachable costs a bounce and teaches the wrong rule."
      },
      "corrected_block" => {
        question: "The builder contests my block: do I withdraw it to keep the PR moving?",
        answer: "Hold the block when the regression is reachable, and let the arbiter measure it.",
        why: "A reachable regression that merges costs more than the bounce that stops it."
      },
      "ruling" => {
        question: "A builder and a reviewer disagree about a block: how do I settle it?",
        answer: "Reproduce both claims on the PR head and rule on what the tree shows.",
        why: "A ruling from prose alone settles nothing the next review can check."
      },
      "operator_praise" => {
        question: "The obvious move is in front of me and I think another is better: do I say so?",
        answer: "Recommend the better move with its reason and let the operator choose.",
        why: "The operator accepted the recommendation on this task."
      },
      "review_praise" => {
        question: "I am about to make a judgment call the task does not spell out: how do I make it reviewable?",
        answer: "Make the call, and state it and its reason where the reviewer reads.",
        why: "The review named the decision as the right one."
      }
    }.freeze

    Signal = Struct.new(:key, :soul, :sources, :verdict, keyword_init: true)

    # The TriageFinding it created, or nil. Never raises.
    def self.propose(task, config: TaskGrader.config)
      new(task, config: config).propose
    rescue StandardError => e
      Rails.logger.error("[dream-proposer] #{task&.slug}: failed (#{e.class})")
      nil
    end

    def self.finding_slug(task_slug)
      "#{SLUG_PREFIX}#{task_slug}"
    end

    def initialize(task, config: TaskGrader.config)
      @task = task
      @config = (config["dream"] || {}).to_h
    end

    def propose
      slug = self.class.finding_slug(@task.slug)
      return nil if TriageFinding.exists?(slug: slug)

      found = signal
      return nil unless found

      text = draft(found)
      reasons = privacy_reasons(text)
      reasons << "invalid_draft" unless valid?(text)
      if reasons.any?
        Rails.logger.info("[dream-proposer] #{@task.slug}: dropped (#{reasons.join(", ")})")
        return nil
      end

      TriageFinding.transaction(requires_new: true) do
        TriageFinding.create!(slug: slug, title: "Dream proposal for #{found.soul}: #{@task.slug}",
                              body: text, source: FINDING_SOURCE, repo: repositories.first)
      end
    end

    # The first configured signal the task's notes carry with a known soul, or nil.
    def signal
      Array(@config["signals"]).each do |key|
        next unless TEMPLATES.key?(key)

        found = send(:"detect_#{key}")
        return found if found&.soul
      end
      nil
    end

    # The dream file for a signal.
    def draft(found)
      template = TEMPLATES.fetch(found.key)
      front = {
        "question" => template[:question], "answer" => template[:answer], "why" => template[:why],
        "status" => "proposed",
        "source" => "task #{@task.slug} · #{found.key} · #{found.sources.join(", ")}",
        "soul" => found.soul
      }.merge(task_tags)
      lines = front.map { |key, value| "#{key}: #{value.is_a?(Array) ? "[#{value.join(", ")}]" : value.to_json}" }
      <<~DREAM
        ---
        #{lines.join("\n")}
        ---

        # #{title}

        ## Situation

        Task `#{@task.slug}` carried the signal `#{found.key}`. The decision is `#{found.soul}`'s.

        ## The pull

        Name the tempting move before sign-off.

        ## What happened

        #{story(found)}

        Before sign-off, read the source activities and rewrite the question, answer and why to the decision this task made.
      DREAM
    end

    # Reason keys for every privacy rule the draft trips; [] when it is clean.
    def privacy_reasons(text)
      screened = text.gsub(ACTIVITY_SLUG, "activity")
      reasons = PRIVACY_PATTERNS.select { |_, pattern| screened.match?(pattern) }.keys
      reasons << "person_name" if person_named?(title)
      reasons
    end

    private

    def notes
      @notes ||= Activity.where(task_slug: @task.slug, activity_type: Activity::TASK_CONVERSATION_TYPES)
                         .conversation_order.to_a
                         .reject { |note| note.metadata.to_h["kind"] == LEARNING_KIND }
    end

    def contest
      @contest ||= notes.find { |note| note.activity_type == "clarification" && text_of(note).start_with?(CONTEST_PREFIX) }
    end

    # [ruling note, verdict] for the newest RULING, or nil.
    def ruling
      @ruling ||= notes.reverse.filter_map { |note| (m = RULING.match(text_of(note))) && [ note, m[1] ] }.first
    end

    def detect_overruled_block
      return nil unless contest && ruling && ruling.last == "OVERRULE" && after?(ruling.first, contest)

      block = block_before(contest)
      return nil unless block

      Signal.new(key: "overruled_block", soul: soul_of(contest) || builder, verdict: ruling.last,
                 sources: slugs(block, contest, ruling.first))
    end

    def detect_corrected_block
      return nil unless contest && ruling && %w[ACCEPT SPLIT].include?(ruling.last) && after?(ruling.first, contest)

      block = block_before(contest)
      return nil unless block

      Signal.new(key: "corrected_block", soul: soul_of(block), verdict: ruling.last,
                 sources: slugs(block, contest, ruling.first))
    end

    def detect_ruling
      return nil unless ruling

      Signal.new(key: "ruling", soul: soul_of(ruling.first), verdict: ruling.last, sources: slugs(ruling.first))
    end

    def detect_operator_praise
      praise = notes.reverse.find { |note| phrase?(note, "operator_phrases") }
      praise && praised(praise, "operator_praise")
    end

    def detect_review_praise
      praise = notes.reverse.find do |note|
        verdict = note.metadata.to_h["kind"] == SCOUT_KIND || note.activity_type == "handoff"
        verdict && soul_of(note) && soul_of(note) != builder && phrase?(note, "review_phrases")
      end
      praise && praised(praise, "review_praise")
    end

    # The decision a praise names is the newest handoff before it by another soul;
    # with none, the task's builder.
    def praised(praise, key)
      decision = notes.reverse.find do |note|
        note.activity_type == "handoff" && after?(praise, note) && soul_of(note) && soul_of(note) != soul_of(praise)
      end
      Signal.new(key: key, soul: (decision && soul_of(decision)) || builder, sources: slugs(decision, praise))
    end

    def phrase?(note, list)
      text = text_of(note).downcase
      Array(@config[list]).any? { |phrase| text.include?(phrase.to_s.downcase) }
    end

    def block_before(note)
      notes.reverse.find { |other| other.activity_type == "qa_feedback" && after?(note, other) }
    end

    def after?(later, earlier)
      notes.index(later) > notes.index(earlier)
    end

    def text_of(note)
      note.description.to_s.lstrip
    end

    def slugs(*activities)
      activities.compact.map(&:slug)
    end

    # The souls.yml slug of a note's actor, or nil when it is not a soul.
    def soul_of(note)
      known_soul(note.agent_slug)
    end

    def builder
      known_soul(@task.devops["built_by"])
    end

    def known_soul(slug)
      soul = DreamBank.canonical_soul(slug)
      Task::SOUL_ROSTER.include?(soul) ? soul : nil
    end

    def repositories
      Array(@task.devops["repositories"]).map(&:to_s)
    end

    # The task's repo, shape and risk tags, keeping only single-token values.
    def task_tags
      {
        "repo" => repositories, "shape" => [ @task.devops["shape"].to_s ],
        "risk" => Array(@task.devops["risk_tags"]).map(&:to_s)
      }.transform_values { |values| values.grep(DreamBank::TAG_VALUE) }.reject { |_, values| values.empty? }
    end

    def title
      @task.title.to_s.squish.truncate(TITLE_LIMIT)
    end

    def story(found)
      case found.key
      when "overruled_block"
        "A reviewer blocked the task. `#{found.soul}` contested the block with evidence. The arbiter ruled OVERRULE."
      when "corrected_block"
        "`#{found.soul}` blocked the task. The builder contested the block. The arbiter ruled #{found.verdict}."
      when "ruling"
        "A block on the task was disputed. `#{found.soul}` ruled #{found.verdict}. The ruling is recorded on the task."
      when "operator_praise"
        "`#{found.soul}` made a call on the task. A note on the task praised it in the operator's words. The task shipped."
      else
        "`#{found.soul}` made a call on the task. A review verdict praised it. The task shipped."
      end
    end

    # A full name on the people table, souls excepted.
    def person_named?(text)
      pairs = text.downcase.scan(/[a-z][a-z'-]*/).each_cons(2).map { |pair| pair.join(" ") }.uniq
      pairs -= Task::SOUL_ROSTER.map { |slug| slug.tr("-_", "  ") }
      return false if pairs.empty?

      Person.where("lower(first_name || ' ' || last_name) IN (?)", pairs).exists?
    end

    def valid?(text)
      dream = DreamBank.parse(text, slug: @task.slug)
      !dream.nil? && dream.status == "proposed" && dream.souls.size == 1
    end
  end
end
