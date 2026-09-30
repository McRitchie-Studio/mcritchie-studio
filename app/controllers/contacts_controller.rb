# /contacts — the mailing list, watched live (admin; task contacts-admin-page).
# The stat tiles and verification breakdown poll #stats while the page is open;
# the table is Contacts::Directory; #show is one contact's sends and events,
# loaded into the row it expands. Full addresses are shown here, to admins only.
class ContactsController < ApplicationController
  before_action :require_admin

  # GET /contacts
  def index
    @directory = Contacts::Directory.new(params.permit(:q, :list, :subscribed, :status, :emailed, :page))
    @dashboard = Contacts::Dashboard.new(list: @directory.params[:list])
    @stats = @dashboard.stats
    @lists = Contacts::Dashboard.lists
  end

  # GET /contacts/stats?list=<tag> — the stats frame alone, for the poll.
  def stats
    @dashboard = Contacts::Dashboard.new(list: params[:list])
    @stats = @dashboard.stats
    render partial: "contacts/stats", locals: { dashboard: @dashboard, stats: @stats }
  end

  # GET /contacts/:id — the detail frame: every delivery and its events.
  def show
    @contact = Contact.find(params[:id])
    @deliveries = @contact.deliveries.includes(:broadcast, :events).order(created_at: :desc)
    render partial: "contacts/detail", locals: { contact: @contact, deliveries: @deliveries }
  end
end
