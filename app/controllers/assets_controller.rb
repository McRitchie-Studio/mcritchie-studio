# frozen_string_literal: true

# /assets — the hub's object store as a folder tree (AssetBrowser). Admin-only:
# buckets hold private material, and previews are short-lived signed URLs.
class AssetsController < ApplicationController
  before_action :require_admin

  def index
    @prefix = AssetBrowser.normalize_prefix(params[:prefix])
    @query = params[:q].to_s.strip
    @token = params[:token].presence
    @key = params[:key].presence
    @store = AssetBrowser.source.label

    if @query.present?
      @search = AssetBrowser.search(query: @query, prefix: @prefix)
    else
      @listing = AssetBrowser.list(prefix: @prefix, token: @token)
    end
    @preview = AssetBrowser.preview(@key) if @key
  rescue AssetBrowser::Unavailable => e
    @error = e.message
  end
end
