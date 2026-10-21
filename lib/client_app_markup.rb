# frozen_string_literal: true

# The tags of a client app's HTML page, found the way a browser's tokenizer finds
# them (docs/agents/system/client-app-host.md, "The Studio template").
#
# PURE RUBY, like ClientAppBundle beside it: bin/client-bundle and the build
# launcher load it without Rails. The publish check (ClientAppBundle
# .template_errors) and the host's wrap (ClientApps::StudioKit::Wrap) both read a
# page through THIS scanner, so a page the check accepts is a page the host
# places the shell in correctly: the two can never disagree about where <body>
# is.
#
# What it skips, as the HTML tokenizer does, so a `<body>` written inside any of
# them is text, never a tag:
#   - comments (<!-- ... -->), the doctype and other markup declarations;
#   - quoted attribute values (<meta content="<body>">);
#   - the contents of the raw-text and RCDATA elements (script, style, title,
#     textarea, and the rest of RAW_TEXT), up to their own end tag.
#
#   tags = ClientAppMarkup.tags(html)
#   tags.first { |t| t.name == "body" && t.start? }   # the real <body> start tag
class ClientAppMarkup
  # Elements whose content the tokenizer reads as text up to their end tag.
  RAW_TEXT = %w[script style title textarea xmp iframe noembed noframes plaintext].freeze
  NAME = %r{\G[A-Za-z][^\s/>]*}
  ATTR_NAME = %r{\G[^\s/>=]+}
  UNQUOTED = /\G[^\s>]*/

  # One tag: its lowercased name, whether it is an end tag, its attributes
  # (lowercased names => raw values; a bare attribute is ""), and its byte range
  # in the page ([from, to) as String indices).
  Tag = Struct.new(:name, :end_tag, :attributes, :from, :to) do
    def start? = !end_tag
  end

  def self.tags(html) = new(html).tags

  def initialize(html)
    @html = html.to_s
  end

  def tags
    @tags ||= scan
  end

  # The first start tag NAME, or nil.
  def first_start(name) = tags.find { |tag| tag.start? && tag.name == name }

  # The first end tag NAME, or nil.
  def first_end(name) = tags.find { |tag| tag.end_tag && tag.name == name }

  # The last end tag NAME, or nil.
  def last_end(name) = tags.reverse_each.find { |tag| tag.end_tag && tag.name == name }

  private

  def scan
    found = []
    i = 0
    length = @html.length
    while (lt = @html.index("<", i))
      if @html[lt, 4] == "<!--"
        close = @html.index("-->", lt + 4)
        i = close ? close + 3 : length
      elsif @html[lt + 1] == "!" || @html[lt + 1] == "?"
        close = @html.index(">", lt + 2)
        i = close ? close + 1 : length
      elsif @html[lt + 1] == "/" && (name = @html.match(NAME, lt + 2)&.[](0))
        close = @html.index(">", lt + 2 + name.length)
        to = close ? close + 1 : length
        found << Tag.new(name.downcase, true, {}, lt, to)
        i = to
      elsif (name = @html.match(NAME, lt + 1)&.[](0))
        attributes, to = read_attributes(lt + 1 + name.length)
        tag = Tag.new(name.downcase, false, attributes, lt, to)
        found << tag
        i = to
        i = skip_raw_text(tag.name, to) if RAW_TEXT.include?(tag.name)
      else
        i = lt + 1 # a lone "<" is text
      end
    end
    found
  end

  # The attributes from index I to the tag's closing ">", honouring quotes, and
  # the index just past it.
  def read_attributes(i)
    attributes = {}
    length = @html.length
    while i < length
      i += 1 while i < length && @html[i].match?(/[\s\/]/)
      return [ attributes, i + 1 ] if @html[i] == ">"
      break if i >= length

      name = @html.match(ATTR_NAME, i)&.[](0)
      if name.nil?
        i += 1
        next
      end
      i += name.length
      i += 1 while i < length && @html[i].match?(/\s/)
      value = ""
      if @html[i] == "="
        i += 1
        i += 1 while i < length && @html[i].match?(/\s/)
        if [ '"', "'" ].include?(@html[i])
          close = @html.index(@html[i], i + 1) || length
          value = @html[i + 1...close].to_s
          i = close + 1
        else
          value = @html.match(UNQUOTED, i)[0]
          i += value.length
        end
      end
      attributes[name.downcase] ||= value
    end
    [ attributes, length ]
  end

  # Past the end tag of a raw-text element NAME opened before index I.
  def skip_raw_text(name, i)
    return @html.length if name == "plaintext"

    close = @html.index(%r{</#{Regexp.escape(name)}(?=[\s/>])}i, i)
    close || @html.length
  end
end
