# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  def index
    @groups = Integration.groups
  end
end
