# frozen_string_literal: true

# DocReferenceScanner — every reference one agent doc makes to another.
#
# WHY THIS EXISTS. Nine role.md files carried `![... Avatar](avatar.png)` pointing at
# a committed docs/agents/agents/<slug>/avatar.png. DocsController#show only ever
# reads `<path>.md`, and its path guard rejects the dot before that branch is even
# reached — so the docs route cannot serve an image at ALL, and every one of those
# nine embeds rendered broken from the day it landed. Nothing failed, because no test
# had ever asked whether a doc's own references were reachable through the route that
# serves docs. This scanner is the half of that guard that reads the corpus;
# test/integration/doc_reference_servability_test.rb is the half that asks the route.
#
# RESOLUTION IS FILESYSTEM-RELATIVE, DELIBERATELY. These links are authored for the
# repo tree — an SOP tells an agent to open `../../modules/heartbeats.md` and the agent
# opens that FILE — and that is also how GitHub renders them. The web viewer's URL
# space is one segment shallower than the tree (DOCS_ROOT is `docs/agents`, mounted at
# `/docs`), so a browser resolves `../` one level differently. Guarding the browser
# semantics instead would fail ~100 correctly-authored links and say nothing about the
# defect above. The rule here is the one that matches how the links are written and
# read: resolve against the tree, then require that what you land on is a doc the route
# will actually serve.
require "pathname"

module DocReferenceScanner
  module_function

  # A fence opens or closes a code block. Its content is never a reference.
  FENCE = /\A\s*(?:```|~~~)/

  # `[text](target)` and `![alt](target)`. Targets with whitespace are not links.
  LINK = /!?\[[^\]]*\]\(([^)\s]+)\)/

  # Inline code: a run of backticks, then anything that is not that same run, then it
  # again. Intentionally NOT /m — a code span does not cross a newline, and letting it
  # would let one stray backtick swallow the rest of the file and hide every reference
  # after it (a scanner that silently finds nothing is the failure mode this whole
  # guard exists to prevent).
  CODE_SPAN = /(?<ticks>`+)(?:(?!\k<ticks>).)*\k<ticks>/

  # Anything addressed to somewhere other than this tree: http:, mailto:, //host, and
  # bare `#anchor` jumps within the current page.
  EXTERNAL = %r{\A(?:[a-z][a-z0-9+.-]*:|//|#)}i

  # The reference targets in one markdown string, in source order, with duplicates
  # kept — the caller decides what to do about repeats.
  #
  # Skips fenced blocks and inline code because the corpus documents its own link
  # syntax: modules/memory-maintenance.md and skills/wrap/SKILL.md both contain
  # `- [Title](topic_file.md)` inside backticks as an EXAMPLE of the format. Redcarpet
  # renders those as literal text, so they are not references and must not be graded
  # as broken ones.
  def references(markdown)
    targets = []

    in_fence = false
    markdown.each_line do |line|
      if line.match?(FENCE)
        in_fence = !in_fence
        next
      end
      next if in_fence

      line.gsub(CODE_SPAN, "").scan(LINK) do |(target)|
        next if target.match?(EXTERNAL)

        bare = target.split("#").first.to_s
        next if bare.empty?

        targets << bare
      end
    end

    targets
  end

  # Where `target`, written inside the doc at `source` (a path relative to the docs
  # root), lands in the tree — again relative to the docs root. A result starting with
  # ".." has escaped the root, which the route refuses outright; it is returned as-is
  # rather than clamped, so the caller can say so.
  def resolve(source, target)
    (Pathname.new(source).dirname + target).cleanpath.to_s
  end

  # Every reference in the corpus as {source:, target:, resolved:}.
  #
  # `skip` holds path prefixes (relative to `root`) to leave alone. The caller passes
  # the frozen audit snapshots under archive/: AGENTS.md says historical snapshots
  # stay as written, and several of them cross-reference docs that were archived or
  # renamed AFTER the snapshot was taken. Re-pointing those links would falsify the
  # record of what was true on the day of the audit.
  def scan(root, skip: [])
    root = Pathname.new(root)

    Dir.glob(root.join("**", "*.md")).sort.filter_map do |file|
      source = Pathname.new(file).relative_path_from(root).to_s
      next if skip.any? { |prefix| source.start_with?(prefix) }

      references(File.read(file)).map do |target|
        { source: source, target: target, resolved: resolve(source, target) }
      end
    end.flatten
  end
end
