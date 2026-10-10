# frozen_string_literal: true

require "yaml"

# bin/lib/ci_suite_workflow.rb — reads the two shapes a repo's `CI` workflow takes:
#
#   INLINE  every lane is a job in the repo's own ci.yml (`jobs.test.steps[].run`).
#   CALLER  a job in ci.yml is `uses: …/reusable-ci.yml`, and the lanes are the hub's
#           .github/workflows/reusable-ci.yml, run with that job's `with:` inputs.
#
# Pure: text in, values out. Callers do the reading.
#
# Unit tests: test/lib/ci_suite_workflow_test.rb
module CiSuiteWorkflow
  # The hub repo that hosts the reusable workflows, and the suite file in it.
  HUB_NWO = "McRitchie-Studio/mcritchie-studio"
  SUITE_PATH = ".github/workflows/reusable-ci.yml"
  # The input that carries a caller's suite command (the `system` lane's `run:`).
  SUITE_COMMAND_INPUT = "system-command"

  # `./.github/workflows/x.yml`, or `<owner>/<repo>/.github/workflows/x.yml@<ref>`.
  CALL = %r{\A(?:\./|(?<nwo>[^/\s]+/[^/\s]+)/)(?<path>\.github/workflows/[^/@\s]+\.ya?ml)(?:@(?<ref>\S+))?\z}
  INPUT_REF = /inputs\.([A-Za-z_][A-Za-z0-9_-]*)/
  EXPRESSION = /\$\{\{(.*?)\}\}/

  class UndeclaredInput < StandardError; end

  module_function

  # A `uses:` value as { nwo:, path:, ref: }, or nil when it is not a workflow call.
  # nwo and ref are nil for a call into the caller's own tree.
  def call(uses)
    match = CALL.match(uses.to_s.strip)
    return nil unless match
    return nil if match[:nwo].nil? != match[:ref].nil? # local carries neither, remote both

    { nwo: match[:nwo], path: match[:path], ref: match[:ref] }
  end

  # TRUE when `uses` calls the hub's suite: locally (the hub's own ci.yml) or by name
  # from another repo.
  def suite_call?(uses)
    target = call(uses)
    !target.nil? && target[:path] == SUITE_PATH && [nil, HUB_NWO].include?(target[:nwo])
  end

  # The [name, job] of the first job in `ci_yaml` that calls the suite, or nil.
  def caller_job(ci_yaml)
    jobs(ci_yaml).find { |_name, job| job.is_a?(Hash) && suite_call?(job["uses"]) }
  end

  # The declared `workflow_call` inputs of a called workflow: { name => { "type" =>,
  # "default" => } }. Empty for a bare `workflow_call:`.
  def inputs(suite_yaml)
    doc = load(suite_yaml)
    on = doc[true] || doc["on"]
    declared = on.is_a?(Hash) && on["workflow_call"].is_a?(Hash) ? on["workflow_call"]["inputs"] : nil
    (declared || {}).transform_values { |spec| spec.is_a?(Hash) ? spec.slice("type", "default") : {} }
  end

  # The workflow text as a call with these `with:` values runs it: every `inputs.<name>`
  # reference replaced by the caller's value, or by the declared default. An expression
  # that is exactly one input becomes its raw value (`run: ${{ inputs.system-command }}`
  # becomes the command); inside a longer expression it becomes a literal. A reference
  # to an input the file does not declare raises.
  #
  # With no `with:` this is what the hub's bare call executes, which is the text the
  # lane guards judge.
  def as_called(suite_yaml, with: {})
    declared = inputs(suite_yaml)
    value_of = lambda do |name|
      raise UndeclaredInput, "inputs.#{name} is not a declared workflow_call input" unless declared.key?(name)

      with.to_h.key?(name) ? with.to_h[name] : declared[name]["default"]
    end

    suite_yaml.to_s.gsub(EXPRESSION) do
      body = Regexp.last_match(1).strip
      whole = body.match(/\A#{INPUT_REF.source}\z/)
      next value_of.call(whole[1]).to_s if whole
      next Regexp.last_match(0) unless body.match?(INPUT_REF)

      "${{ #{body.gsub(INPUT_REF) { literal(value_of.call(Regexp.last_match(1))) }} }}"
    end
  end

  # The `run:` bodies of one job, stripped, nil-free.
  def runs(yaml_text, job)
    steps = jobs(yaml_text).dig(job, "steps")
    Array(steps).grep(Hash).filter_map { |step| step["run"]&.to_s&.strip }.reject(&:empty?)
  end

  # The `run:` bodies of the lane that carries a repo's suite command, in either shape:
  # the inline `job`'s steps, or (for a caller) the `system` lane as its `with:` runs it.
  # Empty when the workflow has neither, or when a caller's suite text is not at hand.
  def suite_runs(ci_yaml, suite_yaml: nil, job: "test")
    inline = runs(ci_yaml, job)
    return inline if inline.any?

    _name, caller = caller_job(ci_yaml)
    return [] if caller.nil? || suite_yaml.to_s.empty?
    return [] if (caller["with"] || {})["system"] == false

    runs(as_called(suite_yaml, with: caller["with"] || {}), "system")
  rescue UndeclaredInput, Psych::Exception
    []
  end

  def jobs(yaml_text)
    found = load(yaml_text)["jobs"]
    found.is_a?(Hash) ? found : {}
  end

  def load(yaml_text)
    doc = YAML.safe_load(yaml_text.to_s, aliases: true)
    doc.is_a?(Hash) ? doc : {}
  end

  def literal(value)
    [true, false].include?(value) ? value.to_s : "'#{value.to_s.gsub("'", "''")}'"
  end
end
