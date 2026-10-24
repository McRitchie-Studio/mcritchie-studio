# Keeps Turbo::StreamsChannel to admins now that /cable admits any signed-in
# user (app/channels/application_cable/connection.rb). After every code load,
# so a development reload cannot drop it.
Rails.application.config.to_prepare do
  unless Turbo::StreamsChannel.ancestors.include?(ApplicationCable::TurboStreamsAdminOnly)
    Turbo::StreamsChannel.prepend(ApplicationCable::TurboStreamsAdminOnly)
  end
end
