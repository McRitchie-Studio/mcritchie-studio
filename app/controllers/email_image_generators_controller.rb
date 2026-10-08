# frozen_string_literal: true

# THE EMAIL IMAGE GENERATOR PAGE (epic email-image-builder, task
# email-image-generator-page): where Alex lands from Turf's /admin/emails. One
# page per brand kit shows the character model, a few example headers, and the
# `email-image` SOP's name plus a simple prompt to copy into a Claude Code
# session. `/email_images/generator` lists the kits.
#
# ADMIN ONLY, READS INCLUDED, for EmailImagesController's reason: hub signup is
# open and the page shows unapproved art. It writes nothing and calls no
# generator.
class EmailImageGeneratorsController < ApplicationController
  before_action :require_admin

  def index
    @kits = EmailImages::BrandKit.all
    @characters = Character.live.where(brand: @kits.map(&:key)).order(:created_at, :id)
                           .group_by(&:brand).transform_values(&:first)
  end

  def show
    kit = EmailImages::BrandKit.find(params[:kit])
    raise ActiveRecord::RecordNotFound, "No email brand kit #{params[:kit].inspect}" if kit.nil?

    @page = EmailImages::GeneratorPage.new(kit)
  end
end
