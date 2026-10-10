# frozen_string_literal: true

require "yaml"

module Devops
  # The production Google OAuth client ids (config/google_oauth_clients.yml) and
  # the one rule built on them: a development or test boot never signs in with a
  # production client. Rails-free, like Devops::Windows, so bin/dev-google-client
  # reads the same list without booting the app.
  module GoogleOAuthClients
    class ProductionClientInDevelopment < StandardError; end

    CONFIG_PATH = File.expand_path("../../../config/google_oauth_clients.yml", __dir__)
    LOCAL_ENVS = %w[development test].freeze

    module_function

    # {app => client id} for every deployed app the file lists.
    def production(path = CONFIG_PATH)
      data = YAML.safe_load_file(path).to_h
      data.fetch("production").to_h.transform_values(&:to_s)
    end

    def production_ids(path = CONFIG_PATH)
      production(path).values.uniq
    end

    # The app(s) a client id belongs to, or an empty list for a dev client.
    def apps_for(client_id, path = CONFIG_PATH)
      production(path).select { |_, id| id == client_id.to_s.strip }.keys
    end

    def production?(client_id, path = CONFIG_PATH)
      apps_for(client_id, path).any?
    end

    # Raises when `env` is a local environment, `client_id` is a production client
    # AND a client secret is set beside it. The id alone is an identifier every
    # browser sees, and a local file that carries it with no secret cannot sign in
    # as production (Google refuses the callback), so it boots; the pair is the
    # exposure this guard exists for. A blank id passes: an unset client fails
    # later, at sign-in, where the cause is plain.
    def refuse_production_in_development!(client_id:, client_secret:, env:, path: CONFIG_PATH)
      return unless LOCAL_ENVS.include?(env.to_s)
      return if client_secret.to_s.strip.empty?

      apps = apps_for(client_id, path)
      return if apps.empty?

      raise ProductionClientInDevelopment,
            "GOOGLE_CLIENT_ID is the production client of #{apps.join(' and ')}, with its secret, in a #{env} " \
            "environment. Local sign-in uses the dev-only client: run bin/dev-google-client --write " \
            "(it reads the agent vault and rewrites every local env file), or bin/dev-secret-key fix to drop the secret."
    end
  end
end
