require "test_helper"

class StatusToneHelperTest < ActionView::TestCase
  # A token class: an engine status role, the primary scale, or the surface,
  # text and border ladders. Nothing from a fixed palette (red-700, mint-300)
  # and no dark: variant.
  TOKEN_CLASS = /\A(border|bg-(success|warning|danger|primary)(\/\d+)?|text-(success|warning|danger)-ink|text-primary|text-heading|text-muted|bg-surface-alt|bg-inset|border-(success|warning|danger|primary)\/\d+|border-subtle)\z/

  test "[unit] each role maps to itself and returns its chip by default" do
    assert_equal "bg-success/10 text-success-ink border border-success/40", status_tone(:success)
    assert_equal "bg-warning/10 text-warning-ink border border-warning/40", status_tone(:warning)
    assert_equal "bg-danger/10 text-danger-ink border border-danger/40", status_tone(:danger)
    assert_equal "bg-primary/10 text-heading border border-primary/40", status_tone(:primary)
    assert_equal "bg-surface-alt text-muted border border-subtle", status_tone(:muted)
  end

  test "[unit] status words map onto the five roles" do
    {
      "shipped" => :success, "passed" => :success, "merged" => :success,
      "submitted" => :warning, "pending" => :warning, "qa_feedback" => :warning,
      "blocked" => :danger, "failed" => :danger, "error" => :danger,
      "designed" => :primary, "building" => :primary, "info" => :primary,
      "archived" => :muted, "abandoned" => :muted, "neutral" => :muted
    }.each do |word, role|
      assert_equal role, status_tone_role(word), "#{word} should read as #{role}"
    end
  end

  test "[unit] words are matched case- and separator-insensitively" do
    assert_equal :warning, status_tone_role("QA Feedback")
    assert_equal :primary, status_tone_role("in-progress")
    assert_equal :danger, status_tone_role(:Blocked)
  end

  test "[unit] an unknown or blank status is muted, never an alarm" do
    assert_equal :muted, status_tone_role("frobnicated")
    assert_equal :muted, status_tone_role(nil)
    assert_equal status_tone(:muted), status_tone("")
  end

  test "[unit] parts return the text, panel, fill and border classes" do
    assert_equal "text-danger-ink", status_tone("failed", :text)
    assert_equal "bg-warning/10 border border-warning/40", status_tone(:pending, :panel)
    assert_equal "bg-success", status_tone(:shipped, :fill)
    assert_equal "border-primary/40", status_tone(:info, :border)
  end

  test "[unit] an unknown part raises rather than rendering unstyled" do
    assert_raises(KeyError) { status_tone(:success, :glow) }
  end

  test "[unit] every class is an engine token: no palette colour, no dark: variant, no bare role text" do
    StatusToneHelper::STATUS_TONE_PARTS.each do |role, parts|
      parts.each do |part, classes|
        classes.split.each do |klass|
          assert_match TOKEN_CLASS, klass, "#{role}.#{part} emits #{klass}, which is not an engine token"
        end
      end
    end
  end

  # Tailwind compiles only class names it finds as text in the source. This
  # holds the helper to that: every class it can return is spelled out whole in
  # the helper file, so none is assembled at runtime and purged.
  test "[unit] every class string appears literally in the helper source" do
    source = Rails.root.join("app/helpers/status_tone_helper.rb").read
    StatusToneHelper::STATUS_TONE_PARTS.each_value do |parts|
      parts.each_value { |classes| assert_includes source, %("#{classes}") }
    end
  end

  test "[unit] every role has every part" do
    assert_equal StatusToneHelper::STATUS_TONE_ROLES.sort, StatusToneHelper::STATUS_TONE_PARTS.keys.sort
    parts = StatusToneHelper::STATUS_TONE_PARTS.values.map(&:keys)
    assert_equal 1, parts.uniq.size
  end

  test "[unit] the seven task stages give seven distinct stage chips" do
    stages = %w[designed building submitted reviewed assembled shipped blocked]
    chips = stages.map { |stage| stage_tone(stage) }
    assert_equal 7, chips.uniq.size, "each stage needs its own rung: #{stages.zip(chips).to_h}"
    assert_equal stages.sort, StatusToneHelper::STAGE_TONES.keys.sort
  end

  test "[unit] the stage ladder uses tokens only and falls back to muted" do
    StatusToneHelper::STAGE_TONES.each do |stage, chip|
      assert_no_match(/\bdark:|\b(?:bg|text|border)-(?:red|amber|green|emerald|blue|violet|mint)-\d/, chip, stage)
      assert_includes Rails.root.join("app/helpers/status_tone_helper.rb").read, %("#{chip}"), "#{stage} is spelled out whole"
    end
    assert_equal status_tone(:muted), stage_tone("archived")
    assert_equal status_tone(:muted), stage_tone(nil)
  end
end
