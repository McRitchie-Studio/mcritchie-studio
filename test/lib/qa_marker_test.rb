# frozen_string_literal: true

# [unit] bin/qa-server's loader stamps QA_ENV=true on every QA environment, so no
# entry in config/qa_environments.yml can boot as production by omitting it.
#
#   ruby -Itest test/lib/qa_marker_test.rb

require "minitest/autorun"
require "yaml"
require_relative "../../bin/lib/qa_server_cli"

class QaMarkerTest < Minitest::Test
  REGISTRY = File.expand_path("../../config/qa_environments.yml", __dir__)

  def test_unit_an_entry_that_declares_nothing_gets_the_marker
    stamped = QaServerCli.with_qa_marker("probe" => { "heroku_app" => "probe-qa" })

    assert_equal({ "QA_ENV" => "true" }, stamped.dig("probe", "required_config"))
    assert_equal "probe-qa", stamped.dig("probe", "heroku_app"), "the rest of the entry rides through"
  end

  def test_unit_a_falsy_declaration_is_overwritten_and_other_keys_survive
    stamped = QaServerCli.with_qa_marker(
      "probe" => { "required_config" => { "QA_ENV" => "false", "APP_HOST" => "qa.example.test" } }
    )

    assert_equal({ "QA_ENV" => "true", "APP_HOST" => "qa.example.test" }, stamped.dig("probe", "required_config"))
  end

  def test_unit_the_loader_does_not_mutate_the_parsed_registry
    raw = { "probe" => { "required_config" => { "APP_HOST" => "qa.example.test" } } }
    QaServerCli.with_qa_marker(raw)

    refute raw.dig("probe", "required_config").key?("QA_ENV")
  end

  def test_integration_every_real_entry_reaches_the_app_with_the_marker
    entries = QaServerCli.with_qa_marker(YAML.load_file(REGISTRY).fetch("qa_environments"))

    assert_operator entries.size, :>=, 3, "the registry parsed to too few entries to be the real file"
    entries.each do |slug, config|
      assert_equal "true", config.dig("required_config", "QA_ENV"), "#{slug} would boot as production"
    end
  end

  def test_integration_bin_qa_server_loads_the_registry_through_the_marker
    source = File.read(File.expand_path("../../bin/qa-server", __dir__))
    loader = source[/^def qa_environments\n.*?^end$/m]

    refute_nil loader, "bin/qa-server no longer defines qa_environments"
    assert_includes loader, "QaServerCli.with_qa_marker(", "the loader must stamp the marker"
  end
end
