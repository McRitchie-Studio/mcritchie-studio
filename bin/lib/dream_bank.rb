# frozen_string_literal: true

# DreamBank — reads the dream bank (docs/agents/dreams/*.md) and renders the
# approved dreams as a SessionStart context block.
#
# A dream is one worked decision from a past session: the question the session
# faced, the good answer it gave, and why that answer was right. The bank is
# tracked files, so it is LOCAL: no token, no board, no network. That is the
# difference from the Insight Bank beside it in bin/session-insights, and why a
# session still dreams when the board is unreachable.
#
# Only `status: approved` dreams load. A `proposed` dream is a candidate waiting
# for Alex's sign-off (docs/agents/modules/dream.md) and reaches no session.
#
# Pure and side-effect free: every method returns a value and rescues its own
# file errors, because the caller is a hook that must never block a session start.

require "yaml"

module DreamBank
  DEFAULT_DIR = File.expand_path("../../docs/agents/dreams", __dir__)
  APPROVED = "approved"
  FRONTMATTER = /\A---\s*\n(.*?)\n---\s*\n?/m

  Dream = Struct.new(:slug, :question, :answer, :why, :status, keyword_init: true) do
    def approved?
      status == APPROVED
    end

    # A dream with no question or no answer has nothing to teach; skip it rather
    # than print half a lesson.
    def complete?
      !question.empty? && !answer.empty?
    end
  end

  module_function

  # Every parseable dream in the directory, in filename order. README.md is the
  # bank's own format page, not a dream.
  def all(dir: DEFAULT_DIR)
    Dir.glob(File.join(dir, "*.md")).sort.filter_map do |path|
      next if File.basename(path).casecmp?("README.md")

      parse(File.read(path), slug: File.basename(path, ".md"))
    end
  rescue StandardError
    []
  end

  def approved(dir: DEFAULT_DIR)
    all(dir: dir).select(&:approved?)
  end

  # One dream from a file's text, or nil when it has no usable frontmatter.
  def parse(text, slug:)
    match = FRONTMATTER.match(text.to_s)
    return nil unless match

    data = YAML.safe_load(match[1])
    return nil unless data.is_a?(Hash)

    dream = Dream.new(slug: slug,
                      question: field(data, "question"),
                      answer: field(data, "answer"),
                      why: field(data, "why"),
                      status: field(data, "status").downcase)
    dream.complete? ? dream : nil
  rescue StandardError
    nil
  end

  HEADER = "## Dreams: good answers from past sessions\n" \
           "Each dream is a decision worth repeating, signed off by Alex. Some record what a session got " \
           "right; some record the answer a wrong call taught. Read them all before your first decision; " \
           "when a situation here matches yours, answer it the same way. A dream never overrides a First " \
           "Rule or an SOP. Full story: `docs/agents/dreams/<slug>.md`.\n\n"

  # The SessionStart block for a list of dreams, or "" when none are approved.
  #
  # `budget` is the most characters the block may take. Claude Code caps a hook's
  # additionalContext at 10,000 characters and, over that, hands the model a file
  # path and a 2,000-character preview instead: nearly every dream would be lost,
  # silently. So the block degrades on purpose, in three steps, and says so:
  #
  #   1. every dream with its Why
  #   2. every dream, question and answer only
  #   3. as many question-and-answer dreams as fit, then one line naming how many
  #      were left out and where to read them
  def context(dreams, budget: nil)
    approved = Array(dreams).select(&:approved?)
    return "" if approved.empty?

    full = render(approved, why: true)
    return full if fits?(full, budget)

    brief = render(approved, why: false)
    return brief if fits?(brief, budget)

    truncated(approved, budget)
  end

  def render(dreams, why:)
    HEADER + dreams.map { |d| dream_block(d, why: why) }.join("\n\n")
  end

  def dream_block(dream, why: true)
    lines = [ "**Q: #{dream.question}** (`#{dream.slug}`)", "A: #{dream.answer}" ]
    lines << "Why: #{dream.why}" if why && !dream.why.empty?
    lines.join("\n")
  end

  def fits?(text, budget)
    budget.nil? || text.size <= budget
  end

  # Step 3. Keeps whole dreams only, in bank order, and always leaves room for the
  # line that says the block is incomplete. "" when not even the header fits.
  def truncated(dreams, budget)
    kept = []
    dreams.each do |dream|
      candidate = kept + [ dream ]
      break unless fits?(render(candidate, why: false) + "\n\n" + overflow_line(dreams.size - candidate.size), budget)

      kept = candidate
    end
    return "" if kept.empty?

    render(kept, why: false) + "\n\n" + overflow_line(dreams.size - kept.size)
  end

  def overflow_line(left_out)
    "**#{left_out} more approved dream(s) did not fit this block.** " \
      "Read `docs/agents/dreams/` before your first decision."
  end

  def field(data, key)
    data[key].to_s.strip.gsub(/\s+/, " ")
  end
end
