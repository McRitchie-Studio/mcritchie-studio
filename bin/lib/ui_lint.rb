# frozen_string_literal: true

require "shellwords"
require "yaml"

# UiLint: the front-end house rules, counted over one repo tree's templates.
#
# The rules are the forbidden lists of studio-engine/docs/FRONT_END_STANDARD.md, the
# five a line scan can decide:
#
#   inline_style     a style attribute: static `style="..."`, Alpine's bound
#                    `:style` / `x-bind:style`, and a helper's `style:` option
#   raw_hex          a hex colour (#abc, #aabbcc, #aabbccdd) inside a class or style
#                    value: `bg-[#0f172a]`, `style="color: #fff"`
#   px_utility       an arbitrary pixel utility: `text-[14px]`, `w-[320px]`,
#                    `md:max-w-[1200px]`; the type scale and spacing tokens cover these
#   unnonced_script  a script element with no CSP nonce: a `<script>` tag, and the
#                    `javascript_tag` / `tag.script` helpers. A tag that names
#                    `nonce` (the `content_security_policy_nonce` helper, or a
#                    helper's `nonce: true`) is nonced; a JSON data block is not a
#                    script CSP governs (config `data_block_types`)
#   long_x_data      an `x-data` value longer than `max_length` characters
#
# WHY A PLAIN SCANNER AND NOT erb_lint. erb_lint 0.9.0 loads custom linters from
# `.erb_linters/**/*.rb` under Dir.pwd (ERBLint::LinterRegistry.load_custom_linters,
# whose CUSTOM_LINTERS_DIR is relative and expanded against the cwd), not from the
# directory of the --config it was given. Linting Turf's app/views with the hub's
# linters would mean running from the hub with every path absolute, and it would
# put erb_lint, better_html and their native extension into the bundle of a script
# that runs in no bundle at all: the fixed-path tooling (/Users/alex/projects/.agents/bin)
# is a `git archive` of bin/ and config/ with no Gemfile. This file needs only the
# standard library, so it runs from any cwd against any tree.
#
# HOW A FILE IS READ. ERB, HTML and whole-line `//` comments are blanked first,
# character for character, so a commented-out offence does not count and every
# offset still maps to its real line. An attribute value is read with ERB tags as
# atoms, so `class="<%= x ? "a" : "b" %> p-4"` is one value, not three.
#
# IT COUNTS; IT DOES NOT PIN. The two ratchets that guard templates today
# (test/views/inline_script_and_x_data_pins.yml here, Turf's
# test/views/alpine_and_inline_script_ceilings.yml) stay as they are. This is the
# wide, report-only view across every repo; a rule becomes a gate by its own card.
module UiLint
  RULES = %w[inline_style raw_hex px_utility unnonced_script long_x_data].freeze
  DEFAULT_CONFIG = File.expand_path("../../config/ui_lint.yml", __dir__)
  SCRIPT = File.expand_path("../ui-lint", __dir__)
  TEMPLATE_DIRS = %w[app/views app/components].freeze
  FNM = File::FNM_PATHNAME | File::FNM_EXTGLOB

  Offense = Struct.new(:rule, :file, :line, :snippet, keyword_init: true)

  # One scan of one tree: every offense, and the files it read and skipped.
  Report = Struct.new(:root, :offenses, :scanned, :exempt, keyword_init: true) do
    def by_rule = RULES.to_h { |rule| [rule, offenses.count { |o| o.rule == rule }] }
    def files_by_rule = RULES.to_h { |rule| [rule, offenses.select { |o| o.rule == rule }.map(&:file).uniq.size] }
    def total = offenses.size

    # { "app/views/x.html.erb" => { "inline_style" => 3, ... } } for each file with any.
    def by_file
      offenses.group_by(&:file).transform_values do |list|
        RULES.to_h { |rule| [rule, list.count { |o| o.rule == rule }] }.select { |_, n| n.positive? }
      end
    end
  end

  # ERB comments, HTML comments, and whole-line `//` comments (a script's prose, which
  # names `<script>` often), as test/views/inline_script_and_x_data_ratchet_test.rb
  # strips them.
  COMMENTS = [/<%#.*?%>/m, /<!--.*?-->/m, %r{^[ \t]*//.*$}].freeze
  ERB_TAG = /<%(?!#).*?%>/m

  # A quoted attribute value, ERB tags taken whole so their own quotes do not end it.
  VALUE = /"((?:<%.*?%>|[^"])*)"|'((?:<%.*?%>|[^'])*)'/m

  # An HTML attribute starts after whitespace; the optional prefix is Alpine's bind.
  def self.attr(name) = /(?<=\s)(?:x-bind:|:)?#{name}\s*=\s*(?:#{VALUE})/m

  STYLE_ATTR = attr("style")
  CLASS_ATTR = attr("class")
  X_DATA_ATTR = /(?<=\s)x-data\s*=\s*(?:#{VALUE})/m

  # A helper's option inside an ERB tag: `style: "..."`, `"style" => "..."`.
  def self.option(name)
    /(?:(?<![\w-])#{name}:|["']#{name}["']\s*=>)\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/m
  end

  STYLE_OPTION = option("style")
  CLASS_OPTION = option("class")
  X_DATA_OPTION = /(?:["']x-data["']\s*(?::|=>)|(?<![\w-])x_data:)\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)')/m

  # `(?<!&)`: `&#128274;` is an HTML entity, not a colour.
  HEX = /(?<!&)#(?:\h{8}|\h{6}|\h{3,4})(?!\h)/
  PX_UTILITY = /(?<![\w\[-])(?:[\w-]+:)*[a-z][\w-]*-\[-?\d*\.?\d+px\]/
  SCRIPT_TAG = /<script\b((?:<%.*?%>|"[^"]*"|'[^']*'|[^>])*)>/mi
  SCRIPT_HELPER = /\b(?:javascript_tag|tag\.script)\b/
  # A nonce ATTRIBUTE or OPTION (`nonce="..."`, `nonce: true`, `"nonce" => x`) or the
  # helper itself, never the bare word: `javascript_tag "say('no nonce')"` has none.
  NONCE = /\bnonce["']?\s*(?:=|:|=>)|\bcontent_security_policy_nonce\b/
  TYPE_ATTR = /\btype\s*=\s*["']([^"']*)["']/i

  module_function

  # --- bin/fast-check's advisory lane --------------------------------------------
  # The lane runs when the tree has templates to read, and runs THIS hub's script
  # against that tree, so a satellite desk is linted by the hub's rules and config.

  def applies_to?(root) = TEMPLATE_DIRS.any? { |dir| File.directory?(File.join(root, dir)) }

  def advisory_command(root, script: SCRIPT) = "#{script.shellescape} #{root.to_s.shellescape}"

  def load_config(path = DEFAULT_CONFIG)
    YAML.safe_load_file(path) || {}
  end

  # The templates under `root` the config includes, split into [scanned, exempt],
  # each a sorted list of root-relative paths.
  def files(root, config)
    found = Array(config["include"]).flat_map { |glob| Dir.glob(glob, base: root) }.uniq.sort
    found = found.select { |rel| File.file?(File.join(root, rel)) }
    found.partition { |rel| !exempt?(rel, config) }
  end

  def exempt?(rel, config)
    Array(config["exempt"]).any? { |pattern| File.fnmatch?(pattern, rel, FNM) }
  end

  def scan(root, config = load_config)
    root = File.expand_path(root)
    scanned, exempt = files(root, config)
    offenses = scanned.flat_map { |rel| check(File.read(File.join(root, rel), encoding: "UTF-8"), rel, config) }
    Report.new(root: root, offenses: offenses, scanned: scanned, exempt: exempt)
  end

  # Every offense in one template's source.
  def check(source, file, config = load_config)
    text = blank_comments(source.scrub)
    found = []
    add = ->(rule, offset, snippet) { found << Offense.new(rule: rule, file: file, line: line_at(text, offset), snippet: snippet.gsub(/\s+/, " ").strip[0, 80]) }

    erb = text.to_enum(:scan, ERB_TAG).map { [Regexp.last_match[0], Regexp.last_match.begin(0)] }

    # inline_style + raw_hex inside style values
    each_match(text, STYLE_ATTR) do |m, value|
      add.call("inline_style", m.begin(0), m[0])
      hexes(value).each { add.call("raw_hex", m.begin(0), m[0]) }
    end
    erb.each do |code, at|
      each_match(code, STYLE_OPTION) do |m, value|
        add.call("inline_style", at + m.begin(0), m[0])
        hexes(value).each { add.call("raw_hex", at + m.begin(0), m[0]) }
      end
    end

    # raw_hex inside class values
    each_match(text, CLASS_ATTR) do |m, value|
      hexes(value).each { add.call("raw_hex", m.begin(0), m[0]) }
    end
    erb.each do |code, at|
      each_match(code, CLASS_OPTION) do |m, value|
        hexes(value).each { add.call("raw_hex", at + m.begin(0), m[0]) }
      end
    end

    # px_utility, anywhere a class name can be written
    text.to_enum(:scan, PX_UTILITY).each { add.call("px_utility", Regexp.last_match.begin(0), Regexp.last_match[0]) }

    # unnonced_script
    data_types = Array(config.dig("rules", "unnonced_script", "data_block_types")).map(&:downcase)
    each_match(text, SCRIPT_TAG) do |m, _|
      attrs = m[1]
      next if attrs.match?(NONCE)
      next if (type = attrs[TYPE_ATTR, 1]) && data_types.include?(type.strip.downcase)

      add.call("unnonced_script", m.begin(0), m[0])
    end
    erb.each do |code, at|
      next unless (hit = code.match(SCRIPT_HELPER))
      next if code.match?(NONCE)

      add.call("unnonced_script", at + hit.begin(0), code)
    end

    # long_x_data
    max = Integer(config.dig("rules", "long_x_data", "max_length") || 80)
    each_match(text, X_DATA_ATTR) do |m, value|
      add.call("long_x_data", m.begin(0), "x-data (#{value.length} chars)") if value.length > max
    end
    erb.each do |code, at|
      each_match(code, X_DATA_OPTION) do |m, value|
        add.call("long_x_data", at + m.begin(0), "x-data (#{value.length} chars)") if value.length > max
      end
    end

    found.sort_by { |o| [o.line, RULES.index(o.rule)] }
  end

  # Yields each match and its quoted value (whichever quote style matched).
  def each_match(text, regex)
    text.to_enum(:scan, regex).each do
      m = Regexp.last_match
      yield m, m.captures.compact.first.to_s
    end
  end

  def hexes(value) = value.scan(HEX)

  # Comments become spaces of the same length, newlines kept, so offsets keep lines.
  def blank_comments(source)
    COMMENTS.reduce(source) { |text, comment| text.gsub(comment) { |hit| hit.gsub(/[^\n]/, " ") } }
  end

  def line_at(text, offset) = text[0, offset].count("\n") + 1

  # --- the report ---------------------------------------------------------------

  # The printable report. `changed` is the diff's root-relative paths, or nil when no
  # diff is known (said so, never shown as an empty diff).
  def render(report, changed: nil, top: 20, verbose: false)
    lines = []
    lines << "ui-lint: #{report.root}"
    lines << "  #{report.scanned.size} template(s) scanned, #{report.exempt.size} exempt by path (config/ui_lint.yml)"
    lines << ""
    lines << format("  %-17s %8s %7s", "rule", "offenses", "files")
    files = report.files_by_rule
    report.by_rule.each { |rule, n| lines << format("  %-17s %8d %7d", rule, n, files[rule]) }
    lines << format("  %-17s %8d %7d", "total", report.total, report.by_file.size)
    lines << ""

    ranked = report.by_file.sort_by { |file, counts| [-counts.values.sum, file] }
    lines << "  top #{[top, ranked.size].min} file(s) of #{ranked.size} with an offense:"
    ranked.first(top).each { |file, counts| lines << format("  %6d  %s  (%s)", counts.values.sum, file, breakdown(counts)) }
    lines << "    (none)" if ranked.empty?
    lines << ""

    lines.concat(diff_lines(report, changed))
    if verbose
      lines << ""
      report.offenses.sort_by { |o| [o.file, o.line] }.each { |o| lines << "  #{o.file}:#{o.line}  #{o.rule}  #{o.snippet}" }
    end
    lines
  end

  def diff_lines(report, changed)
    return ["  diff: none known (pass --changed, or run inside a git checkout)"] if changed.nil?

    in_scope = changed.map { |p| p.sub(%r{\A\./}, "") }.uniq & report.scanned
    counts = report.by_file
    hit = in_scope.select { |file| counts.key?(file) }.sort
    total = hit.sum { |file| counts[file].values.sum }
    lines = ["  diff: #{changed.size} changed file(s), #{in_scope.size} scanned template(s), " \
             "#{total} offense(s) in #{hit.size} file(s)"]
    hit.each { |file| lines << format("  %6d  %s  (%s)", counts[file].values.sum, file, breakdown(counts[file])) }
    lines
  end

  def breakdown(counts) = counts.map { |rule, n| "#{rule} #{n}" }.join(", ")
end
