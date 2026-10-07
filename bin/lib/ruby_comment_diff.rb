# frozen_string_literal: true

require "ripper"

# RubyCommentDiff — did an edit to a Ruby file change anything but its comments?
#
# Guard catalog row 2.4 (decision 2): the `docs` shape's claim classifies a Ruby file
# by HUNK, so correcting only the comments in a `.rb` file can ride a docs claim. The
# test is the Ripper token stream with comments dropped: equal before and after means
# nothing Ruby executes changed.
#
# THE NORMALIZATION, and why each step is safe:
#   * comments, `=begin`/`=end` blocks and spaces are dropped;
#   * every line break (a statement newline, an ignored newline, or the newline a
#     comment token swallows) becomes ONE :nl marker, and runs of them collapse, so
#     adding or deleting a comment line moves nothing while `a\nb` and `a b` still
#     differ;
#   * a MAGIC comment (`# frozen_string_literal:`, `# encoding:`, …) changes how Ruby
#     reads the file, so those are kept as tokens and a change to one is a code change.
#
# FAIL CLOSED. Source that does not lex cleanly, carries an `__END__` DATA section
# (which Ripper does not tokenize), or a side that cannot be read, is
# never comment-only: the caller then treats the file as code, which is the old rule.
module RubyCommentDiff
  MAGIC_COMMENT = /\A#\s*-\*-.*-\*-|\A#\s*(?:frozen_string_literal|encoding|coding|warn_indent|shareable_constant_value)\s*:/i
  DROPPED = %i[on_sp on_embdoc_beg on_embdoc on_embdoc_end].freeze
  BREAKS = %i[on_nl on_ignored_nl].freeze
  RUBY_SHEBANG = /\A#!.*\bruby\b/

  module_function

  # Is this file Ruby source? `.rb`, or an extensionless script with a ruby shebang.
  def ruby_source?(path, content)
    return true if path.to_s.end_with?(".rb")

    File.extname(path.to_s).empty? && RUBY_SHEBANG.match?(content.to_s.lines.first.to_s)
  end

  # The comment-free token stream of `source`, or nil when it does not lex cleanly.
  def code_tokens(source)
    lexer = Ripper::Lexer.new(source.to_s)
    tokens = lexer.lex
    return nil if lexer.respond_to?(:error?) && lexer.error?
    # Text after `__END__` is DATA, which Ripper does not tokenize: fail closed.
    return nil if tokens.any? { |(_, type, _, _)| type == :on___end__ }

    stream = tokens.each_with_object([]) do |(_, type, text, _), out|
      next if DROPPED.include?(type)

      if type == :on_comment
        out << [:magic, text.strip] if MAGIC_COMMENT.match?(text)
        out << [:nl] if text.end_with?("\n") && out.last != [:nl]
      elsif BREAKS.include?(type)
        out << [:nl] unless out.last == [:nl]
      else
        out << [type, text]
      end
    end
    # A break at either end separates nothing.
    stream.shift while stream.first == [:nl]
    stream.pop while stream.last == [:nl]
    stream
  rescue StandardError
    nil
  end

  # True only when the two sides DIFFER, both lex, and their comment-free token
  # streams are equal. An unchanged file is not a comment-only change: the caller
  # read the wrong tree, and that answer must not grant anything.
  def comment_only_change?(old_source, new_source)
    return false if old_source.nil? || new_source.nil? || old_source == new_source

    old_tokens = code_tokens(old_source)
    new_tokens = code_tokens(new_source)
    !old_tokens.nil? && old_tokens == new_tokens
  end
end
