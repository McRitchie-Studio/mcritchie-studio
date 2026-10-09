require "test_helper"
require "yaml"

# A ratchet on the two things this app is moving out of its templates: Alpine
# x-data bindings and script tags. Behaviour belongs in app/javascript, as a
# module or a Stimulus controller a template names.
#
# inline_script_and_x_data_pins.yml, beside this file, pins each template's
# count of both. The counts only go down:
#
#   - a template that gains one fails here: write the module instead;
#   - a template that loses one fails here until its pin is lowered to match,
#     so a removal cannot be spent on a new one later;
#   - a template with either that has no pin fails here.
#
# What counts, per template under app/views and app/components, after ERB
# comments, HTML comments and // comment lines are taken out:
#
#   x_data  an x-data binding: the attribute, bare or with a value, and the
#           "x-data" key of a helper's html options
#   script  a script element: a <script> tag of any type, javascript_tag and
#           tag.script
class InlineScriptAndXDataRatchetTest < ActiveSupport::TestCase
  PINS_FILE = Pathname(__dir__).join("inline_script_and_x_data_pins.yml")
  TEMPLATES = "app/{views,components}/**/*.erb".freeze

  X_DATA = /(?<![\w-])x-data(?![\w-])/
  SCRIPT = /<script\b|\bjavascript_tag\b|\btag\.script\b/i
  COMMENTS = [ /<%#.*?%>/m, /<!--.*?-->/m, %r{^\s*//.*$} ].freeze

  def self.count(source)
    code = COMMENTS.reduce(source) { |text, comment| text.gsub(comment, "") }
    { "x_data" => code.scan(X_DATA).size, "script" => code.scan(SCRIPT).size }
  end

  # { "app/views/tasks/_board.html.erb" => { "x_data" => 1, "script" => 1 } },
  # for every template with at least one of either.
  def self.census(root = Rails.root)
    Dir.glob(root.join(TEMPLATES).to_s).sort.each_with_object({}) do |file, found|
      counts = count(File.read(file))
      found[Pathname(file).relative_path_from(root).to_s] = counts if counts.values.any?(&:positive?)
    end
  end

  # One sentence per template whose counts differ from its pin.
  def self.drift(census, pins)
    (census.keys | pins.keys).sort.flat_map do |file|
      counted = census.fetch(file, { "x_data" => 0, "script" => 0 })
      pinned = pins[file]
      next "#{file}: has no pin (#{counted.inspect}); move the behaviour to app/javascript" if pinned.nil?

      %w[x_data script].filter_map do |kind|
        if counted[kind] > pinned[kind]
          "#{file}: #{kind} rose #{pinned[kind]} -> #{counted[kind]}; move the behaviour to app/javascript"
        elsif counted[kind] < pinned[kind]
          "#{file}: #{kind} fell #{pinned[kind]} -> #{counted[kind]}; lower its pin in #{PINS_FILE.basename}" \
            "#{' (remove the entry)' if counted.values.sum.zero?}"
        end
      end
    end
  end

  def pins = YAML.load_file(PINS_FILE)

  test "no template has more x-data bindings or script tags than its pin, or fewer" do
    drift = self.class.drift(self.class.census, pins)

    assert_empty drift, "templates drifted from their pins:\n  #{drift.join("\n  ")}"
  end

  test "the pins hold only templates that still carry something" do
    empty = pins.select { |_file, pinned| pinned.values.sum.zero? }.keys

    assert_empty empty, "pins at zero are finished: remove them"
    assert_operator pins.size, :>, 0, "an empty pin file would pass everything"
  end

  test "the counter sees each spelling of a binding and of a script, and no comment" do
    counted = ->(source) { self.class.count(source) }

    assert_equal({ "x_data" => 1, "script" => 0 }, counted.call('<div x-data="{ open: false }">'))
    assert_equal({ "x_data" => 1, "script" => 0 }, counted.call("<body x-data class=\"page\">"))
    assert_equal({ "x_data" => 1, "script" => 0 }, counted.call('<%= form_with html: { "x-data": "composer()" } do %>'))
    assert_equal({ "x_data" => 0, "script" => 1 }, counted.call("<script>\n  go();\n</script>"))
    assert_equal({ "x_data" => 0, "script" => 1 }, counted.call('<script type="module">import "x"</script>'))
    assert_equal({ "x_data" => 0, "script" => 1 }, counted.call(%(<%= javascript_tag 'import "x"', type: "module" %>)))
    assert_equal({ "x_data" => 0, "script" => 1 }, counted.call("<%= tag.script(nonce: true) do %>go()<% end %>"))

    # Controls: prose about either is not one, and neither is a longer name.
    assert_equal({ "x_data" => 0, "script" => 0 }, counted.call("<%# x-data and a <script> tag, in an ERB comment %>"))
    assert_equal({ "x_data" => 0, "script" => 0 }, counted.call("<!-- x-data and a <script> tag -->"))
    assert_equal({ "x_data" => 0, "script" => 0 }, counted.call("  // Alpine evaluates x-data before the <script> below"))
    assert_equal({ "x_data" => 0, "script" => 0 }, counted.call('<div data-x-data-source="1" class="description">'))
  end

  test "a gained binding, a lost one and an unpinned template each fail the ratchet" do
    pins = { "app/views/a.html.erb" => { "x_data" => 1, "script" => 1 } }
    drift = ->(census) { self.class.drift(census, pins) }

    assert_empty drift.call("app/views/a.html.erb" => { "x_data" => 1, "script" => 1 }), "control: at its pin"
    assert_match(/x_data rose 1 -> 2/, drift.call("app/views/a.html.erb" => { "x_data" => 2, "script" => 1 }).sole)
    assert_match(/script fell 1 -> 0; lower its pin/, drift.call("app/views/a.html.erb" => { "x_data" => 1, "script" => 0 }).sole)
    assert_match(/remove the entry/, drift.call({}).first, "a template cleared of both")
    assert_match(%r{app/views/b.html.erb: has no pin},
                 drift.call("app/views/a.html.erb" => { "x_data" => 1, "script" => 1 },
                            "app/views/b.html.erb" => { "x_data" => 1, "script" => 0 }).sole)
  end
end
