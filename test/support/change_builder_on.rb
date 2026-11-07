# The headless change builder ships OFF (config/client_builds.yml, task
# safety-floor-settings, 2026-11-06). A test that exercises the builder running
# includes this module: it swaps in an in-memory config with the section switched
# on, and puts the shipped file back after each test. It never writes the file.
module ChangeBuilderOn
  def self.included(base)
    base.setup { ChangeBuilderOn.switch_on! }
    base.teardown { ChangeBuilderOn.restore! }
  end

  def self.switch_on!
    shipped = YAML.safe_load_file(ClientBuilds::CONFIG_PATH)
    on = shipped.merge("change_builder" => shipped.fetch("change_builder", {}).merge("enabled" => true))
    ClientBuilds.instance_variable_set(:@config, on.freeze)
  end

  # Drop the memo so the next read loads the shipped file again.
  def self.restore! = ClientBuilds.instance_variable_set(:@config, nil)
end
