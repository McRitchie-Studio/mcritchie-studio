# frozen_string_literal: true

# EMAIL BRAND KITS (epic email-image-builder, task email-brand-asset-page): the
# page Alex opens with an agent before a generation run (the `email-image` SOP,
# step 1). Each kit's base assets (references, palette, font, style and
# "never" rules), every header approved for the brand, its open briefs, and
# the form that adds a reference image.
#
# ADMIN ONLY, READS INCLUDED, for EmailImagesController's reason: hub signup is
# open, the page shows unapproved art, and two actions write to our bucket.
class EmailBrandKitsController < ApplicationController
  before_action :require_admin
  before_action :set_kit, except: :index

  def index
    @kits = EmailImages::BrandKit.all
    keys = @kits.map(&:key)
    @upload_counts = EmailBrandReference.active.where(brand_kit: keys).group(:brand_kit).count
    briefs = EmailImageBrief.where(brand_kit: keys).pluck(:brand_kit, :approved_artifact_slug)
    @approved_counts = briefs.select { |_, slug| slug.present? }.map(&:first).tally
    @open_counts = briefs.reject { |_, slug| slug.present? }.map(&:first).tally
  end

  def show
    load_show
    @reference = EmailBrandReference.new(brand_kit: @kit.key, role: "mascot")
  end

  def create_reference
    attrs = reference_params
    rescue_and_log do
      @reference = EmailImages::UploadReference.call(kit: @kit.key, file: attrs[:file], role: attrs[:role],
                                                     label: attrs[:label], note: attrs[:note], by: current_user&.email)
      if @reference.persisted?
        redirect_to email_brand_kit_path(@kit.key), notice: "Reference added. The next round can use it."
      else
        load_show
        render :show, status: :unprocessable_content
      end
    end
  end

  def archive_reference
    reference = EmailBrandReference.active.find_by!(brand_kit: @kit.key, slug: params[:slug])
    rescue_and_log(target: reference) { reference.archive! }
    redirect_to email_brand_kit_path(@kit.key), notice: "Archived #{reference.label}. No round will send it."
  end

  private

  def set_kit
    @kit = EmailImages::BrandKit.find(params[:kit])
    raise ActiveRecord::RecordNotFound, "No email brand kit #{params[:kit].inspect}" if @kit.nil?
  end

  def load_show
    @references = @kit.references
    row = ImageGeneration::Registry.preferred(EmailImages::Generate::CAPABILITY)
    @generator_row = row
    @reference_limit = EmailImages::BrandKit.reference_limit(row)
    @sent = @kit.generator_references(limit: @reference_limit)
    @archived = EmailBrandReference.archived.where(brand_kit: @kit.key).order(archived_at: :desc).limit(20).to_a
    briefs = EmailImageBrief.where(brand_kit: @kit.key).ordered.to_a
    approved = briefs.select { |b| b.approved_artifact_slug.present? }
    artifacts = Artifact.where(slug: approved.map(&:approved_artifact_slug)).approved.index_by(&:slug)
    @approved_headers = approved.filter_map { |b| (a = artifacts[b.approved_artifact_slug]) && [b, a] }
                                .sort_by { |_, a| a.approved_at }.reverse
    @open_briefs = briefs.reject { |b| b.approved_artifact_slug.present? }
  end

  def reference_params
    params.fetch(:email_brand_reference, {}).permit(:file, :role, :label, :note)
  end
end
