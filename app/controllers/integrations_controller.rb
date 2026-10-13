# /integrations — public: the free integrations every plan can connect and the
# add-on services we run on top, rendered from config/integrations.yml.
class IntegrationsController < ApplicationController
  def index
    @groups = Integration.groups
  end

  # /integrations/discord — the guide the Discord card's Connect opens: what a
  # McRitchie Studio bot in the client's server would do, and how setup would
  # go. The bot does not exist yet, so its one button requests it.
  def discord
    @entry = Integration.find(:discord)
  end
end
