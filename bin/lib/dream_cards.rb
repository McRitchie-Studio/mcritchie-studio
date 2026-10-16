# frozen_string_literal: true

# DreamCards — the one formatter for putting dream decisions to Alex in chat
# (docs/agents/modules/dream.md, "The card standard"). `bin/dream cards` prints it,
# and both entry points use that command: the `dream-swap` SOP on demand and the
# Dreams step at wrap (wrap-it-up, /wrap).
#
#   <one idea line>
#
#   1 · SWAP · soul/carl · 20 of 20 used
#      Q: "…"
#      A: "…"
#      Why: "…"
#      Evidence: source 2026-10-04 · task x; OUT `carl/old` · mean 0.5 of 2 · 3 fired · last 2026-10-01
#      My call: approve — the reason in one line
#
#   Reply: yes takes every call · 1 ✓ 2 ✗ 3 ✎ <edit> · or plain words. …
#
# Rails-free and side-effect free: `build` turns the bank, the board's layer
# reports and the pending rulings into cards; `render` prints them. The session's
# own call rides in through `calls` (the formatter judges nothing); a card without
# one prints the slot the session must fill.
require_relative "dream_bank"
require_relative "dream_layers"

module DreamCards
  KINDS = %w[ADD SWAP RETIRE].freeze
  VERDICTS = %w[approve change drop].freeze
  # A RETIRE card is offered on demand for an approved dream whose grades say it
  # misleads: a mean under this, over at least RETIRE_MIN_GRADES grades.
  RETIRE_MEAN = 0.5
  RETIRE_MIN_GRADES = 2
  # An answer that opens like a rule is the must-do the test below is about.
  MUST_DO = /\A\s*(?:always|never|must|do not|don't|every time)\b/i
  MUST_DO_TEST = "a must-do belongs in a command, not a dream"
  REPLY = "Reply: `yes` takes every call · `1 ✓ 2 ✗ 3 ✎ <edit>` per number · or plain words. " \
          "Silence changes nothing: a dream never defaults on silence."
  NO_SWAP = "Dreams: no swap this session"

  # kind: ADD|SWAP|RETIRE; layer: a DreamLayers key; dream: the DreamBank::Dream the
  # card asks about (the in, or the dream to retire); out: the swap's out row (the
  # board's candidate hash) or nil; call: [verdict, reason] or nil.
  Card = Struct.new(:kind, :layer, :used, :cap, :dream, :out, :evidence, :call, keyword_init: true)

  module_function

  # The cards for `proposed` (the dreams awaiting a ruling) against the layers.
  #   approved   every approved dream in the bank (the local count when the board
  #              gives no report for a layer)
  #   reports    the board's swap-candidate reports (bin/dream swap-candidates), or []
  #   out_key    the wrap's chosen out for a single swap card, else the top candidate
  #   retire     add data-driven RETIRE cards (the on-demand prompt; never at wrap)
  #   calls      { slug => [verdict, reason] }
  def build(proposed:, approved:, reports: [], out_key: nil, retire: false, calls: {})
    by_layer = Array(reports).to_h { |report| [ report["layer"].to_s, report ] }
    taken = []
    cards = Array(proposed).map do |dream|
      layer = DreamLayers.key(dream)
      used, cap, full = room(layer, by_layer[layer], approved)
      out = full ? pick_out(by_layer[layer], out_key, taken) : nil
      taken << key(out) if out
      Card.new(kind: full ? "SWAP" : "ADD", layer: layer, used: used, cap: cap, dream: dream, out: out,
               evidence: in_evidence(dream, out, full), call: calls[dream.slug])
    end
    cards += retire_cards(by_layer, approved, taken, calls) if retire
    cards
  end

  # [used, cap, full?] for a layer, from the board's report when there is one.
  def room(layer, report, approved)
    cap = DreamLayers.budget(layer)
    return [ report["approved"].to_i, report["budget"].to_i.nonzero? || cap, report["full"] ? true : false ] if report

    used = DreamLayers.members(approved, layer).size
    [ used, cap, used >= cap ]
  end

  def pick_out(report, out_key, taken)
    candidates = Array(report && report["candidates"]).reject { |row| taken.include?(key(row)) }
    return candidates.find { |row| key(row) == out_key } if out_key

    candidates.first
  end

  def key(row) = row ? "#{row["dream_home"]}/#{row["dream_slug"]}" : nil

  def retire_cards(by_layer, approved, taken, calls)
    by_key = Array(approved).to_h { |dream| [ "#{dream.home}/#{dream.slug}", dream ] }
    by_layer.flat_map do |layer, report|
      Array(report["candidates"]).filter_map do |row|
        next if taken.include?(key(row)) || !misleads?(row)

        dream = by_key[key(row)]
        next unless dream

        taken << key(row)
        used, cap, = room(layer, report, approved)
        Card.new(kind: "RETIRE", layer: layer, used: used, cap: cap, dream: dream, out: row,
                 evidence: "Evidence: #{stats(row)} · #{source(dream)}", call: calls[dream.slug])
      end
    end
  end

  def misleads?(row)
    !row["mean_grade"].nil? && row["grades"].to_i >= RETIRE_MIN_GRADES && row["mean_grade"].to_f < RETIRE_MEAN
  end

  def in_evidence(dream, out, full)
    line = "Evidence: #{source(dream)}"
    return line unless full

    out ? "#{line}; OUT `#{key(out)}` · #{stats(out)}" : "#{line}; layer full and no out is eligible (every candidate in grace or retiring)"
  end

  def source(dream)
    text = dream.source.to_s.strip
    "source #{text.empty? ? "not recorded" : text} · #{dream.home}/#{dream.slug}.md"
  end

  # "mean 0.5 of 2 · 3 fired · last 2026-10-01", from a candidate row.
  def stats(row)
    mean = row["mean_grade"].nil? ? "ungraded" : "mean #{row["mean_grade"]} of #{row["grades"]}"
    last = row["last_fired_at"].to_s[0, 10]
    "#{mean} · #{row["fires"].to_i} fired · #{last.empty? ? "never fired" : "last #{last}"}"
  end

  # The whole message: the idea line, the numbered cards, the reply grammar.
  def render(cards, idea: nil)
    return "#{idea || "No dream decisions are waiting."}\n" if cards.empty?

    blocks = cards.each_with_index.map { |card, index| card_text(card, index + 1) }
    [ idea || idea_line(cards), *blocks, REPLY ].join("\n\n") + "\n"
  end

  # "3 dream decisions for you: 1 add, 1 swap, 1 retire."
  def idea_line(cards)
    counts = KINDS.filter_map do |kind|
      n = cards.count { |card| card.kind == kind }
      "#{n} #{kind.downcase}" if n.positive?
    end
    noun = cards.size == 1 ? "decision" : "decisions"
    "#{cards.size} dream #{noun} for you: #{counts.join(", ")}."
  end

  def card_text(card, number)
    dream = card.dream
    lines = [ "#{number} · #{card.kind} · #{card.layer} · #{card.used} of #{card.cap} used" ]
    lines << "   Q: #{quote(dream.question)}"
    lines << "   A: #{quote(dream.answer)}"
    lines << "   Why: #{quote(dream.why)}"
    lines << "   #{card.evidence}"
    lines << "   Must-do test: the answer reads as a rule; #{MUST_DO_TEST}." if card.kind != "RETIRE" && MUST_DO.match?(dream.answer.to_s)
    lines << "   #{call_text(card)}"
    lines.join("\n")
  end

  def call_text(card)
    verdict, reason = card.call
    if verdict
      "My call: #{verdict}#{reason.to_s.strip.empty? ? "" : " — #{reason.strip}"}"
    else
      "My call: <approve|change|drop> — <one line> (test first: #{MUST_DO_TEST})"
    end
  end

  def quote(text) = "\"#{text.to_s.strip}\""

  # { slug => [verdict, reason] } from `--call slug=verdict[:reason]` values; nil
  # names the first bad value.
  def parse_calls(values)
    values.each_with_object({}) do |value, calls|
      slug, rest = value.to_s.split("=", 2)
      verdict, reason = rest.to_s.split(":", 2)
      return [ nil, value ] unless slug.to_s.match?(/\A[a-z0-9][a-z0-9-]*\z/) && VERDICTS.include?(verdict.to_s.strip)

      calls[slug] = [ verdict.strip, reason.to_s.strip ]
    end.then { |calls| [ calls, nil ] }
  end
end
