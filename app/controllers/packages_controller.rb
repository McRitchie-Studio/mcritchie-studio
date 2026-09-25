# The public Basic vs Pro comparison. Customers see what each package delivers;
# admins also see the SOP map — which registered SOP delivers each item — so the
# operator can see how the SOP library is organized.
class PackagesController < ApplicationController
  skip_before_action :require_authentication

  def index
    @packages = WorkspacePackage.all
    @launch_sop_path = WorkspacePackage.sop_paths["workspace-launch"]
  end
end
