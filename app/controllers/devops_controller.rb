class DevopsController < ApplicationController
  before_action :require_admin

  def index
    @apps = devops_test_suites.fetch("apps", {})
    @worktree_registry = params[:refresh] ? WorktreeRegistry.refresh! : WorktreeRegistry.load
  end

  private

  def devops_test_suites
    YAML.load_file(Rails.root.join("config/devops_test_suites.yml"))
  end
end
