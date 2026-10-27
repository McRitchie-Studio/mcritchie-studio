module Integrations
  # The Drive files a signed-in user picks for their OWN Google connection
  # (/tasks/drive-files-you-pick), from the Google Drive card on /integrations.
  #
  #   POST   /integrations/google/drive/token      a short-lived access token for
  #                                                the Picker (JSON, no-store)
  #   POST   /integrations/google/drive/picks      record the picked file ids
  #   DELETE /integrations/google/drive/picks/:id  forget one pick
  #
  # OWNERSHIP. Every action finds the connection among current_user's own rows,
  # so a token is never minted for, and a pick never lands on, another person's
  # account (the household's included): anything else answers 404. Only a
  # drive.file connection takes picks; a legacy drive.readonly row reconnects first.
  #
  # TRUST NOTHING THE BROWSER SAYS ABOUT A FILE. #create takes ids only and reads
  # each file's metadata with the connection's own token: under drive.file Google
  # answers only for a file the person really picked, so a guessed id is refused
  # and the stored name is Google's. A folder is refused (GoogleDrivePick).
  class DrivePicksController < ApplicationController
    MAX_PER_PICK = 50

    before_action { response.headers["Cache-Control"] = "no-store" }

    def token
      return render(json: { error: GoogleConnect::Picker::NOT_SET }, status: :service_unavailable) unless GoogleConnect::Picker.configured?

      connection = own_drive_connection
      render json: { access_token: GoogleConnect::OAuthClient.access_token(connection),
                     api_key: GoogleConnect::Picker.api_key, app_id: GoogleConnect::Picker.app_id }
    rescue GoogleConnect::OAuthClient::Revoked
      render json: { error: "Google no longer accepts this connection. Disconnect Google Drive, then connect it again." }, status: :conflict
    rescue GoogleConnect::OAuthClient::Error => e
      render json: { error: e.message }, status: :bad_gateway
    end

    def create
      connection = own_drive_connection
      ids = Array(params[:file_ids]).map(&:to_s).uniq
      return render(json: { error: "Pick at least one file." }, status: :unprocessable_entity) if ids.empty?
      return render(json: { error: "Pick at most #{MAX_PER_PICK} files at a time." }, status: :unprocessable_entity) if ids.size > MAX_PER_PICK

      picked, refused = record(connection, ids)
      flash[:notice] = pick_notice(picked, refused)
      render json: { picked: picked.map(&:name), refused: }
    rescue GoogleConnect::OAuthClient::Revoked
      render json: { error: "Google no longer accepts this connection. Disconnect Google Drive, then connect it again." }, status: :conflict
    end

    def destroy
      pick = GoogleDrivePick.joins(:google_connection).merge(current_user.google_connections).find(params[:id])
      pick.destroy!
      redirect_to integrations_path, notice: "#{pick.name} is no longer shared with your agents.", status: :see_other
    end

    private

    def own_drive_connection
      connection = current_user.google_connections.find(params[:connection_id])
      raise ActiveRecord::RecordNotFound unless connection.readable? && connection.drive_picked?

      connection
    end

    # Reads each id's metadata with the connection's token and stores the
    # files Google answers for. Returns [picks, refused names or ids].
    def record(connection, ids)
      reader = GoogleConnect::DriveReader.new(connection)
      ids.each_with_object([ [], [] ]) do |id, (picked, refused)|
        file = reader.file(id, missing: nil)
        next refused << id if file.nil?

        pick = connection.drive_picks.find_or_initialize_by(file_id: file.id)
        pick.assign_attributes(name: file.name, mime_type: file.mime_type, url: file.url, picked_by: current_user.slug, picked_at: Time.current)
        pick.save ? picked << pick : refused << file.name
      rescue ArgumentError, GoogleConnect::OAuthClient::Error => e
        Rails.logger.info("[google_connect] drive pick refused: #{e.class}")
        refused << id
      end
    end

    def pick_notice(picked, refused)
      notice = picked.any? ? "#{pluralize_files(picked.size)} shared with your agents." : "No file was shared."
      refused.any? ? "#{notice} Not shared: #{refused.size} #{refused.one? ? 'item' : 'items'} Google did not hand over, or a folder." : notice
    end

    def pluralize_files(count) = "#{count} #{count == 1 ? 'file' : 'files'}"
  end
end
