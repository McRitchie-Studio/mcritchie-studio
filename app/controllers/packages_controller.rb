# The public pricing pages, both rendered from config/workspace_packages.yml:
#
#   /packages        the marketing page — one card per tier, its promise, its
#                    highlights and a call to action, then the "Talk to us" line
#                    for the tier drawn without a card (Enterprise)
#   /packages/stack  the full stack — every feature row, grouped by category,
#                    one column per tier, Enterprise included, then the same
#                    "Talk to us" line. Admins also see the SOP map there:
#                    which registered SOP delivers each row.
class PackagesController < ApplicationController
  def index
    @packages = WorkspacePackage.cards
    @talk_to_us = WorkspacePackage.talk_to_us
  end

  def stack
    @packages = WorkspacePackage.all
    @talk_to_us = WorkspacePackage.talk_to_us
    @launch_sop_path = WorkspacePackage.sop_paths["workspace-launch"]
  end
end
