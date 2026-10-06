# The public pricing pages, both rendered from config/workspace_packages.yml:
#
#   /packages        the marketing page — one card per tier, its promise, its
#                    highlights and a call to action
#   /packages/stack  the full stack — every feature row, grouped by category,
#                    one column per tier. Admins also see the SOP map there:
#                    which registered SOP delivers each row.
class PackagesController < ApplicationController
  def index
    @packages = WorkspacePackage.all
  end

  def stack
    @packages = WorkspacePackage.all
    @launch_sop_path = WorkspacePackage.sop_paths["workspace-launch"]
  end
end
