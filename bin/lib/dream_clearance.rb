# frozen_string_literal: true

# DreamClearance — the one rule for Alex's quoted words on a dream ruling given in
# chat (docs/agents/modules/dream.md, Act 3, "In chat").
#
# `bin/dream approve|drop|retire <slug> --clearance "<his words>"` checks it before
# it posts, and DreamRuling checks it again on the board, so an agent token that
# skips the CLI meets the same refusal. It mirrors `bin/release ship --mode cleared
# --clearance`: the words are an audit trail the session asserts, not a signature.
#
# A clearance passes when it is one of:
#   - at least MIN_WORDS words that are not just the dream's slug; or
#   - a reply in the card grammar (dream.md, "The card standard"): `yes`, which
#     takes every call the session made, or per-number answers such as `1 ✓ 2 ✗`.
#     Those are complete answers to numbered cards, so their brevity is the grammar,
#     not a missing quote.
# It refuses an empty clearance, the slug alone (with or without its home or
# backticks), and anything shorter.
module DreamClearance
  MIN_WORDS = 3
  # `yes`, alone, in any case, with trailing punctuation.
  YES = /\A\s*yes\s*[.!]*\s*\z/i
  # One or more `<n> ✓|✗|✎ …` answers; ✎ carries the edit after it.
  NUMBERED = /\A\s*(?:\d+\s*[✓✗]\s*,?\s*)*\d+\s*(?:[✓✗]|✎\s*\S.*)\s*\z/m

  module_function

  # nil when `words` may stand as Alex's clearance for `slug`; else the reason.
  def problem(words, slug: nil)
    text = words.to_s.strip
    return "a clearance is Alex's exact words in this session; none was given" if text.empty?
    return nil if grammar_reply?(text)

    bare = text.delete("`\"'").sub(%r{\A.*/}, "").strip.downcase
    if slug && bare == slug.to_s.downcase
      return "the clearance is only the slug `#{slug}`; quote Alex's own words"
    end
    if text.split(/\s+/).size < MIN_WORDS
      return "the clearance #{text.inspect} is shorter than #{MIN_WORDS} words; quote Alex's whole reply " \
             "(a bare `yes` or `1 ✓` from the card grammar is accepted as it stands)"
    end

    nil
  end

  def grammar_reply?(text) = YES.match?(text) || NUMBERED.match?(text)
end
