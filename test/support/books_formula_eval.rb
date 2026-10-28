# frozen_string_literal: true

require "cgi"

# Evaluates the formulas Books::Workbook writes, straight off the caxlsx
# package, so the suite can hold the Sheet's figures to the Ruby summary without
# LibreOffice. It knows exactly the grammar the workbook uses and raises on
# anything else, so a new formula shape fails loudly here rather than evaluating
# to something plausible:
#
#   numbers, "strings", A1 / $A$1 / Sheet!A1 / 'Sheet name'!$B$4 refs,
#   A1:B9 and $D:$D ranges, + - & and unary minus, parentheses,
#   SUM, ROUND, and SUMIFS with = <> < <= > >= criteria.
class BooksFormulaEval
  Unsupported = Class.new(StandardError)
  Range = Struct.new(:sheet, :c1, :r1, :c2, :r2)

  TOKEN = /\s*(?:(?<num>\d+(?:\.\d+)?)|(?<str>"[^"]*")|(?<ref>(?:'[^']+'|[A-Za-z]+)!\$?[A-Z]+\$?\d*(?::\$?[A-Z]+\$?\d*)?|\$?[A-Z]{1,3}\$?\d+(?::\$?[A-Z]{1,3}\$?\d+)?|\$?[A-Z]{1,3}:\$?[A-Z]{1,3})|(?<fn>[A-Z]+)\(|(?<op><=|>=|<>|[-+&(),<>=]))/

  def initialize(package)
    # caxlsx keeps a sheet's name XML-escaped ("P&amp;L"); formulas use the real name.
    @sheets = package.workbook.worksheets.to_h { |ws| [ CGI.unescapeHTML(ws.name), ws ] }
    @cache = {}
  end

  # The value of one cell, its formula evaluated.
  def value(sheet, ref)
    col, row = split(ref)
    key = [ sheet, col, row ]
    return @cache[key] if @cache.key?(key)

    raw = @sheets.fetch(sheet).rows[row - 1]&.cells&.[](col)&.value
    @cache[key] = raw.is_a?(String) && raw.start_with?("=") ? evaluate(sheet, raw[1..]) : raw
  end

  # The first row whose column A reads `label`, as an A1 row number.
  def row_of(sheet, label)
    idx = @sheets.fetch(sheet).rows.index { |r| r.cells.first&.value == label } or raise KeyError, "no row #{label.inspect} on #{sheet}"
    idx + 1
  end

  private

  # A reference can point at another formula cell, so evaluation nests: each
  # call keeps its own parse state and restores the caller's.
  def evaluate(sheet, text)
    saved = [ @tokens, @pos, @sheet ]
    evaluate!(sheet, text)
  ensure
    @tokens, @pos, @sheet = saved
  end

  def evaluate!(sheet, text)
    @tokens = []
    rest = text.dup
    until rest.strip.empty?
      m = TOKEN.match(rest) or raise Unsupported, "cannot read #{rest.inspect} in =#{text}"
      raise Unsupported, "gap before #{m[0].inspect} in =#{text}" unless m.begin(0).zero?

      kind = %i[num str ref fn op].find { |k| m[k] }
      @tokens << [ kind, m[kind] ]
      rest = m.post_match
    end
    @sheet = sheet
    @pos = 0
    result = concat
    raise Unsupported, "trailing tokens in =#{text}" if @pos < @tokens.size

    result
  end

  def peek = @tokens[@pos]

  def take(value = nil)
    tok = @tokens[@pos]
    raise Unsupported, "expected #{value.inspect}, got #{tok.inspect}" if value && tok&.last != value

    @pos += 1
    tok
  end

  def concat
    left = additive
    while peek&.last == "&"
      take
      left = "#{text_of(left)}#{text_of(additive)}"
    end
    left
  end

  def additive
    left = unary
    while %w[+ -].include?(peek&.last) && peek.first == :op
      op = take.last
      right = unary
      left = op == "+" ? num(left) + num(right) : num(left) - num(right)
    end
    left
  end

  def unary
    if peek&.last == "-" && peek.first == :op
      take
      return -num(unary)
    end
    primary
  end

  def primary
    kind, text = take
    case kind
    when :num then text.to_f
    when :str then text[1..-2]
    when :ref then reference(text)
    when :fn then call(text)
    when :op
      raise Unsupported, "unexpected #{text}" unless text == "("

      inner = concat
      take(")")
      inner
    else raise Unsupported, "unexpected end"
    end
  end

  def call(name)
    args = []
    unless peek&.last == ")"
      loop do
        args << concat
        break unless peek&.last == ","

        take
      end
    end
    take(")")
    case name
    when "SUM" then args.sum { |a| a.is_a?(Range) ? cells(a).sum { |v| v.is_a?(Numeric) ? v : 0 } : num(a) }
    when "ROUND" then num(args[0]).round(num(args[1]).to_i)
    when "SUMIFS" then sumifs(*args)
    else raise Unsupported, "function #{name}"
    end
  end

  def sumifs(sum_range, *pairs)
    sums = cells(sum_range)
    tests = pairs.each_slice(2).map { |range, crit| [ cells(range), crit ] }
    sums.each_index.sum do |i|
      next 0 unless sums[i].is_a?(Numeric)

      tests.all? { |values, crit| matches?(values[i], crit) } ? sums[i] : 0
    end
  end

  def matches?(value, crit)
    m = crit.to_s.match(/\A(<=|>=|<>|<|>|=)?(.*)\z/)
    op = m[1] || "="
    target = m[2]
    if value.is_a?(Numeric) && target.match?(/\A-?\d+(\.\d+)?\z/)
      return value.public_send({ "=" => :==, "<>" => :!= }.fetch(op, op.to_sym), target.to_f)
    end
    raise Unsupported, "text comparison #{op} on #{value.inspect}" unless %w[= <>].include?(op)

    same = value.to_s.casecmp?(target)
    op == "=" ? same : !same
  end

  def reference(text)
    sheet = @sheet
    if text.include?("!")
      sheet, text = text.split("!", 2)
      sheet = sheet.delete_prefix("'").delete_suffix("'")
    end
    a, b = text.delete("$").split(":")
    return value(sheet, a) if b.nil?

    c1, r1 = split_loose(a)
    c2, r2 = split_loose(b)
    rows = @sheets.fetch(sheet).rows.size
    Range.new(sheet, c1, r1 || 1, c2, r2 || rows)
  end

  def cells(range)
    raise Unsupported, "expected a range" unless range.is_a?(Range)

    (range.r1..range.r2).flat_map { |r| (range.c1..range.c2).map { |c| value(range.sheet, "#{col_name(c)}#{r}") } }
  end

  def split(ref)
    c, r = split_loose(ref.delete("$"))
    [ c, r ]
  end

  def split_loose(ref)
    m = ref.match(/\A([A-Z]+)(\d*)\z/) or raise Unsupported, "ref #{ref}"
    col = m[1].chars.reduce(0) { |acc, ch| (acc * 26) + (ch.ord - 64) } - 1
    [ col, m[2].empty? ? nil : m[2].to_i ]
  end

  def col_name(index) = Axlsx.col_ref(index)

  def num(v) = v.nil? ? 0.0 : (v.is_a?(Numeric) ? v.to_f : (raise Unsupported, "not a number: #{v.inspect}"))

  def text_of(v) = v.is_a?(Float) && v == v.floor ? v.to_i.to_s : v.to_s
end
