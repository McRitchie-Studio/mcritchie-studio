# frozen_string_literal: true

# DreamBank — reads the dream bank (docs/agents/dreams/) and renders its two
# sequences. The PLATFORM sequence is every approved dream with no `soul` tag;
# bin/session-insights prints it at session start. A SOUL's sequence is every
# approved dream tagged with that soul; bin/dream prints it when the soul is
# invoked.
#
# A dream is one worked decision from a past session: the question the session
# faced, the good answer it gave, and why that answer was right. The bank is
# tracked files, read locally: no token, no board, no network.
#
# Only `status: approved` dreams load (docs/agents/modules/dream.md).
#
# Every reader returns a value and rescues its own file errors: the callers are a
# session-start hook and claim commands that a dream may not break.

require "yaml"

module DreamBank
  DEFAULT_DIR = File.expand_path("../../docs/agents/dreams", __dir__)
  SOULS_PATH = File.expand_path("../../config/souls.yml", __dir__)
  APPROVED = "approved"
  PLATFORM = "platform"
  FRONTMATTER = /\A---\s*\n(.*?)\n---\s*\n?/m
  # The bank's own pages; the reader skips them in every directory.
  SKIPPED = %w[README.md INDEX.md].freeze
  FIELDS = %w[question answer why status source].freeze
  TAGS = %w[soul repo shape risk stage topic].freeze
  TAG_VALUE = /\A[a-z0-9][a-z0-9+-]*\z/
  SOUL_ALIASES = { "alex" => "xan" }.freeze

  Dream = Struct.new(:slug, :question, :answer, :why, :status, :tags, :home, keyword_init: true) do
    def approved?
      status == APPROVED
    end

    def complete?
      !question.empty? && !answer.empty?
    end

    def souls
      tags.fetch("soul", [])
    end

    def platform?
      souls.empty?
    end

    # The directory the dream belongs in: its first soul, or platform.
    def sequence
      souls.first || PLATFORM
    end
  end

  module_function

  # Every parseable dream under the directory, in path order.
  def all(dir: DEFAULT_DIR)
    Dir.glob(File.join(dir, "**", "*.md")).sort.filter_map do |path|
      next if SKIPPED.any? { |name| File.basename(path).casecmp?(name) }

      home = File.dirname(path).delete_prefix(dir).delete_prefix("/")
      parse(File.read(path), slug: File.basename(path, ".md"), home: home)
    end
  rescue StandardError
    []
  end

  def approved(dir: DEFAULT_DIR)
    all(dir: dir).select(&:approved?)
  end

  def platform(dir: DEFAULT_DIR)
    approved(dir: dir).select(&:platform?)
  end

  def soul(name, dir: DEFAULT_DIR)
    slug = canonical_soul(name)
    approved(dir: dir).select { |dream| dream.souls.include?(slug) }
  end

  # `turf_monster` and `alex` name the souls.yml slugs `turf-monster` and `xan`.
  def canonical_soul(name)
    slug = name.to_s.strip.downcase.tr("_", "-")
    SOUL_ALIASES.fetch(slug, slug)
  end

  # souls.yml as { slug => record }; {} when it cannot be read.
  def roster(path: SOULS_PATH)
    YAML.safe_load_file(path).fetch("souls").to_h { |record| [ record["slug"], record ] }
  rescue StandardError
    {}
  end

  # One dream from a file's text, or nil when its front matter is unusable.
  def parse(text, slug:, home: "")
    match = FRONTMATTER.match(text.to_s)
    return nil unless match

    data = YAML.safe_load(match[1])
    return nil unless data.is_a?(Hash) && errors(data).empty?

    dream = Dream.new(slug: slug,
                      question: field(data, "question"),
                      answer: field(data, "answer"),
                      why: field(data, "why"),
                      status: field(data, "status").downcase,
                      tags: tags(data),
                      home: home.to_s)
    dream.complete? ? dream : nil
  rescue StandardError
    nil
  end

  # { tag => [values] } for the tags a dream carries.
  def tags(data)
    TAGS.to_h { |tag| [ tag, Array(data[tag]).map { |value| value.to_s.strip } ] }.reject { |_, values| values.empty? }
  end

  # Why a front matter hash is refused; [] when it is sound. An unknown soul is
  # judged only while the roster can be read.
  def errors(data, souls: roster)
    found = (data.keys.map(&:to_s) - FIELDS - TAGS).map { |key| "unknown front matter key `#{key}`" }
    tags(data).each do |tag, values|
      values.grep_v(TAG_VALUE).each { |value| found << "#{tag} value `#{value}` is not one lowercase token" }
    end
    unless souls.empty?
      (tags(data).fetch("soul", []) - souls.keys).each { |name| found << "unknown soul `#{name}`" }
    end
    found
  end

  HEADER = "## Dreams: good answers from past sessions\n" \
           "Each dream is a decision worth repeating, signed off by Alex. Some record what a session got " \
           "right; some record the answer a wrong call taught. Read them all before your first decision; " \
           "when a situation here matches yours, answer it the same way. A dream never overrides a First " \
           "Rule or an SOP. Full story: `docs/agents/dreams/platform/<slug>.md`.\n\n"

  # The platform sequence for a session start: the dreams, then the helper roster
  # when both fit the budget. The roster never costs a dream or a Why line.
  def platform_context(dreams, budget: nil, souls: roster)
    body = context(dreams, budget: budget)
    helpers = helpers_block(souls)
    return body if body.empty? || helpers.empty?

    with_helpers = "#{body}\n\n#{helpers}"
    fits?(with_helpers, budget) ? with_helpers : body
  end

  # Which soul does which work, and how to hand one a task.
  def helpers_block(souls = roster)
    return "" if souls.empty?

    "### Helper agents\n" \
      "Each soul has its own dream sequence: `bin/dream <soul>` prints it, and a soul launched as a subagent " \
      "reads it with its role page before it works. Brief a helper with the task slug, the desk and what is " \
      "ruled out; its report is testimony until your own tool calls confirm it.\n" +
      souls.map { |slug, record| "`#{slug}` #{record["title"]}" }.join(" · ")
  end

  # One soul's sequence with every Why, or "" when the soul is unknown or has no
  # approved dream.
  def soul_context(name, dreams, task: nil, souls: roster)
    slug = canonical_soul(name)
    record = souls[slug]
    mine = Array(dreams).select { |dream| dream.approved? && dream.souls.include?(slug) }
    return "" if record.nil? || mine.empty?

    heading = "## #{record["name"]}'s dream sequence"
    heading += " · task #{task}" unless task.to_s.strip.empty?
    "#{heading}\n" \
      "Worked decisions for this seat, signed off by Alex. Your skills are this sequence plus " \
      "`docs/agents/agents/#{slug.tr("-", "_")}/role.md`. When a situation here matches yours, answer it " \
      "the same way. A dream never overrides a First Rule or an SOP. " \
      "Full stories: `docs/agents/dreams/INDEX.md`.\n\n" +
      mine.map { |dream| dream_block(dream) }.join("\n\n")
  end

  # Prints a soul's sequence to `io`; prints nothing when there is none. Never raises.
  def announce(name, io: $stderr, task: nil, dir: DEFAULT_DIR)
    text = soul_context(name, soul(name, dir: dir), task: task)
    io.puts(text) unless text.empty?
  rescue StandardError
    nil
  end

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

  # docs/agents/dreams/INDEX.md: every dream under each sequence it loads in.
  def index(dir: DEFAULT_DIR, souls: roster)
    dreams = all(dir: dir)
    sections = [ index_section("Platform", "every session start", dreams.select(&:platform?)) ]
    souls.each do |slug, record|
      mine = dreams.select { |dream| dream.souls.include?(slug) }
      sections << index_section(record["name"], "`bin/dream #{slug}`", mine) unless mine.empty?
    end
    "# Dream index\n\n" \
      "Generated by `bin/dream index --write`; do not edit. #{dreams.size} dreams.\n\n" +
      sections.join("\n")
  end

  def index_section(name, loader, dreams)
    rows = dreams.map do |dream|
      labels = dream.tags.except("soul").map { |tag, values| "#{tag}: #{values.join(", ")}" }.join("; ")
      "| [`#{dream.slug}`](#{dream.home}/#{dream.slug}.md) | #{dream.question.gsub("|", "\\|")} | #{labels} | #{dream.status} |"
    end
    "## #{name} (#{dreams.size})\n\nLoads at: #{loader}\n\n" \
      "| Dream | Question | Tags | Status |\n|---|---|---|---|\n#{rows.join("\n")}\n"
  end

  def field(data, key)
    data[key].to_s.strip.gsub(/\s+/, " ")
  end
end
