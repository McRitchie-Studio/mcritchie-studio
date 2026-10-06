class UsagesController < ApplicationController
  def index
    @usages = Usage.recent
    @usages = @usages.for_agent(params[:agent]) if params[:agent].present?
    @usages = @usages.limit(100)
  end
end
