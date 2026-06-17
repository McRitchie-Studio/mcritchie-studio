class DevopsController < ApplicationController
  before_action :require_admin

  def index
    @apps = devops_test_suites.fetch("apps", {})
  end

  private

  def devops_test_suites
    YAML.load_file(Rails.root.join("config/devops_test_suites.yml"))
  end
end
