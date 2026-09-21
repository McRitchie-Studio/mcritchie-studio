require "test_helper"

# [integration] The template against the CODE, across the boundary a fresh
# machine actually crosses: `.env.example` is copied to `.env`, the operator
# fills it in, and a service boots off what it found.
#
# The tripwire in test/lib/env_example_credential_pointers_test.rb checks the
# template against the credential INVENTORY — that a pointer names a live item.
# This checks the other side: that the template DECLARES every variable a
# service refuses to boot without. The two failures are different and neither
# guard sees the other's: a template can name a perfectly live 1Password item
# for a variable the code stopped reading, or omit a variable the code requires.
#
# Higgsfield is the one exercised here because it is the one that just moved,
# and because its client raises on a blank value rather than degrading — so an
# undeclared variable is a hard boot failure on a fresh machine, not a warning.
class EnvExampleCoversRequiredVarsTest < ActionDispatch::IntegrationTest
  TEMPLATE = Rails.root.join(".env.example")

  test "every variable the Higgsfield client refuses to boot without is declared in the template" do
    required = required_env_vars_of(Higgsfield::Client)

    assert_equal %w[HIGGSFIELD_API_KEY HIGGSFIELD_API_SECRET].sort, required.sort,
                 "the client's required variables changed — update this guard with them, " \
                 "and update .env.example in the same pass"

    missing = required.reject { |name| declared?(name) }

    assert_empty missing,
                 "Higgsfield::Client raises without #{missing.inspect}, and .env.example does not " \
                 "declare #{missing.length == 1 ? 'it' : 'them'} — a fresh machine copies this file " \
                 "and boots straight into GenerationError."
  end

  # Not a spelling check: the client is CONSTRUCTED against an environment
  # built from the template's own variable names, and must get past its guard
  # clauses. A declared-but-misspelled name fails here the way it would on a
  # real machine.
  test "the client boots from an environment built out of the template" do
    filled = declared_names.index_with { "value" }

    client = nil
    with_env(filled) { client = Higgsfield::Client.new }

    assert_instance_of Higgsfield::Client, client
  end

  test "and does NOT boot when the template's Higgsfield lines are removed" do
    # The control. Without it the test above passes for any client that never
    # reads the environment at all.
    without_higgsfield = declared_names.grep_v(/\AHIGGSFIELD_/).index_with { "value" }

    error = assert_raises(Higgsfield::Client::GenerationError) do
      with_env(without_higgsfield) { Higgsfield::Client.new }
    end

    assert_match(/HIGGSFIELD_API_KEY not set/, error.message)
  end

  private

  # `raise ... if @x.blank?` guarded by `ENV["NAME"]` — read off the source so
  # a new required variable is picked up without anyone remembering to add it.
  def required_env_vars_of(klass)
    source = Rails.root.join("app/services/higgsfield/client.rb").read
    body   = source[/def initialize.*?\n    end/m].to_s

    body.scan(/ENV\["([A-Z0-9_]+)"\]/).flatten.uniq
  end

  def declared_names
    @declared_names ||= TEMPLATE.each_line.filter_map { |l| l[/\A([A-Z][A-Z0-9_]*)=/, 1] }.uniq
  end

  def declared?(name) = declared_names.include?(name)

  # Replace the environment for the block — the variables under test must be
  # ABSENT, not merely unasserted, or a value already exported in the shell
  # running the suite would satisfy the client and the control would pass
  # for the wrong reason.
  def with_env(values)
    touched = (declared_names + values.keys).uniq
    saved   = touched.index_with { |k| ENV[k] }

    touched.each { |k| ENV.delete(k) }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
