require "test_helper"

# [unit] Insights::DreamProposer: which trajectories propose a dream, for which
# soul, what a draft holds, and what the privacy screen drops.
class Insights::DreamProposerTest < ActiveSupport::TestCase
  NoLines = Struct.new(:lines) do
    def lines_for(_url) = lines
  end

  setup do
    %w[carl avi pokemon].each { |slug| Agent.find_or_create_by!(slug: slug) { |agent| agent.name = slug.capitalize } }
  end

  def shipped_task(slug, title: "Guard The Nil Reader")
    task = Task.create!(title: title, slug: slug,
                        metadata: { "devops" => { "built_by" => "pokemon", "shape" => "backend",
                                                  "repositories" => [ "mcritchie-studio" ], "risk_tags" => [ "none" ] } })
    task.update!(stage: "building")
    task.update!(stage: "submitted")
    task.update!(stage: "shipped")
    task.reload
  end

  def note(task, type, text, by: nil, kind: nil)
    Activity.create!(task_slug: task.slug, activity_type: type, description: text, agent_slug: by,
                     metadata: kind ? { "kind" => kind } : {})
  end

  # A block, a contest and a ruling; returns the three notes.
  def contested(task, verdict)
    [ note(task, "qa_feedback", "The reader raises on nil.", by: "carl", kind: "rework"),
      note(task, "clarification", "CONTEST: the reader is never handed nil; the caller guards it.", by: "pokemon"),
      note(task, "comment", "RULING: #{verdict} — measured on the PR head.", by: "avi") ]
  end

  def propose(task)
    Insights::DreamProposer.propose(task)
  end

  def finding_for(task)
    TriageFinding.find_by(slug: "dream-proposal-#{task.slug}")
  end

  def logged
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end

  def test_proposes_on_overruled_block
    task = shipped_task("dream-overruled")
    block, contest, ruling = contested(task, "OVERRULE")

    finding = propose(task)

    assert_equal "dream-proposal-dream-overruled", finding.slug
    assert_equal "open", finding.status
    dream = DreamBank.parse(finding.body, slug: task.slug)
    assert_equal "proposed", dream.status
    assert_equal [ "pokemon" ], dream.souls, "the contest's actor made the decision"
    assert_equal({ "soul" => [ "pokemon" ], "repo" => [ "mcritchie-studio" ], "shape" => [ "backend" ], "risk" => [ "none" ] }, dream.tags)
    assert_includes finding.body, %(source: "task dream-overruled · overruled_block · #{block.slug}, #{contest.slug}, #{ruling.slug}")
    assert_not_empty dream.question
    assert_not_empty dream.answer
    assert_not_empty dream.why
    assert_equal 3, finding.body[/## What happened\n\n(.*)\n/, 1].scan(/\.(?:\s|\z)/).size, "the story is three sentences"
    assert_not_includes finding.body, "never handed nil", "note text never reaches a draft"
  end

  def test_proposes_on_a_corrected_block_for_the_reviewer
    task = shipped_task("dream-corrected")
    contested(task, "ACCEPT")

    assert_equal [ "carl" ], DreamBank.parse(propose(task).body, slug: task.slug).souls
  end

  def test_proposes_on_a_ruling_with_no_contest_for_the_arbiter
    task = shipped_task("dream-ruling")
    note(task, "comment", "RULING: SPLIT — half stands.", by: "avi")

    assert_equal [ "avi" ], DreamBank.parse(propose(task).body, slug: task.slug).souls
  end

  def test_proposes_on_accepted_contrarian_note
    task = shipped_task("dream-contrarian")
    handoff = note(task, "handoff", "Kept the old reader; the new one loses the retry.", by: "pokemon")
    praise = note(task, "comment", "Alex: Good call. He accepted the recommendation against the obvious move.")

    finding = propose(task)

    assert_equal [ "pokemon" ], DreamBank.parse(finding.body, slug: task.slug).souls
    assert_includes finding.body, "operator_praise · #{handoff.slug}, #{praise.slug}"
  end

  def test_proposes_on_a_review_verdict_that_praises_a_decision
    task = shipped_task("dream-praised")
    note(task, "comment", "Scout report: merge-ready - fail-open is the right call here.", by: "carl", kind: "scout_report")

    assert_includes propose(task).body, "review_praise"
  end

  def test_silent_on_plain_task
    task = shipped_task("dream-plain")
    note(task, "qa_feedback", "Missing the regression test.", by: "carl", kind: "rework")
    note(task, "handoff", "Added the regression test.", by: "pokemon")
    note(task, "comment", "Carl review approved; merged into accepted.", by: "carl")

    assert_no_difference -> { TriageFinding.count } do
      assert_nil propose(task)
    end
  end

  def test_silent_when_the_deciding_actor_is_not_a_soul
    task = shipped_task("dream-no-soul")
    note(task, "comment", "RULING: ACCEPT — the block stands.")

    assert_nil propose(task)
  end

  def test_the_builders_own_praise_is_not_a_review_verdict
    task = shipped_task("dream-self-praise")
    note(task, "handoff", "Fail-open is the right call here.", by: "pokemon")

    assert_nil propose(task)
  end

  def test_a_souls_praise_of_its_own_call_proposes_nothing
    task = shipped_task("dream-own-praise")
    note(task, "handoff", "Kept the old reader; a good call on the retry.", by: "pokemon")

    assert_nil propose(task)
  end

  # Each title trips one rule; the control beside them is kept.
  PRIVATE_TITLES = {
    "person_name" => "Pay lionel messi On Time",
    "email" => "Mail pat@example.com The Report",
    "phone" => "Call 303-555-0142 Back",
    "money" => "Refund $250 To The Entrant",
    "digit_run" => "Close Account 12345678"
  }.freeze

  def test_drops_a_draft_quoting_a_person_or_figure
    kept = shipped_task("dream-kept", title: "Soul Carl Holds Block 2")
    contested(kept, "OVERRULE")
    assert propose(kept), "a soul's name and a short number are not private"

    PRIVATE_TITLES.each do |reason, title|
      task = shipped_task("dream-private-#{reason.tr("_", "-")}", title: title)
      contested(task, "OVERRULE")

      log = logged do
        assert_no_difference -> { TriageFinding.count }, reason do
          assert_nil propose(task), reason
        end
      end

      assert_includes log, "[dream-proposer] #{task.slug}: dropped (#{reason})"
      title.split.each { |word| assert_not_includes log.sub(task.slug, ""), word, "the log quotes nothing" }
    end
  end

  def test_drops_a_draft_whose_slug_names_a_person_the_title_does_not
    task = shipped_task("pay-lionel-messi-on-time", title: "Pay The Entrant Now")
    contested(task, "OVERRULE")

    assert_nil propose(task)
    hyphened = shipped_task("dream-hyphened-name", title: "Pay Lionel-Messi On Time")
    contested(hyphened, "OVERRULE")
    assert_nil propose(hyphened)
  end

  def test_an_unsound_tag_is_left_off_the_draft
    task = shipped_task("dream-tags")
    task.update!(metadata: task.metadata.deep_merge("devops" => { "shape" => "Not A Token", "risk_tags" => [ "money", "two words" ] }))
    contested(task, "OVERRULE")

    tags = DreamBank.parse(propose(task).body, slug: task.slug).tags
    assert_equal [ "money" ], tags["risk"]
    assert_not tags.key?("shape")
  end

  def test_one_per_task
    task = shipped_task("dream-once")
    contested(task, "OVERRULE")

    first = assert_difference -> { TriageFinding.count }, 1 do
      Insights::TaskGrader.grade!(task.slug, pr_reader: NoLines.new(nil))
    end
    assert first
    assert_no_difference -> { TriageFinding.count } do
      Insights::TaskGrader.grade!(task.slug, pr_reader: NoLines.new(nil))
      assert_nil propose(task), "a direct second call adds none either"
    end
  end

  def test_a_dismissed_proposal_is_not_proposed_again
    task = shipped_task("dream-dismissed")
    contested(task, "OVERRULE")
    propose(task).dismiss!

    assert_no_difference -> { TriageFinding.count } do
      assert_nil propose(task)
    end
  end

  def test_every_configured_signal_has_a_template
    assert_equal Insights::DreamProposer::TEMPLATES.keys, Insights::TaskGrader.config.dig("dream", "signals")
  end

  def test_never_reads_the_facts_tier
    source = Rails.root.join("app/services/insights/dream_proposer.rb").read
    assert_no_match(/\bFact\b/, source)
  end
end
