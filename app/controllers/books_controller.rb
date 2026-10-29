# frozen_string_literal: true

# /books (Finance → Books): review and confirm the book lines, per entity in
# config/books.yml. Admin-only (the admin wall is default-deny, and the page is
# audience: admin in config/navigation.yml).
#
# index     the lines no rule could classify, each with a category picker, a
#           purpose (for distributions) and a note; the latest close; and the
#           answers recorded most recently, each with an undo
# classify  records one line's answer (PATCH /books/:entity/entries/:id)
#           through Books::Classify, the same write path as `bin/books classify`,
#           with the signed-in admin as `by`. `category=none` is the undo.
#
# Account numbers never reach the page: an account shows as its label and last
# four digits, and a long digit run in bank text is cut to its last four.
# SOP: docs/agents/agents/mack/sops/close-the-month.md.
class BooksController < ApplicationController
  before_action :require_admin
  before_action :set_entity

  RECENT = 25
  # The purposes the SOP names, offered even before any line uses them.
  PURPOSES = [ "Owner draws", "Acquisition costs", "Equity injection to Industries" ].freeze

  def index
    scope = BookEntry.for_entity(@entity.key)
    @waiting = scope.unclassified.chronological.to_a
    @recent = scope.where.not(classified_at: nil).order(classified_at: :desc, id: :desc).limit(RECENT).to_a
    @waiting_counts = BookEntry.unclassified.group(:entity).count
    @purposes = (PURPOSES + BookEntry.where.not(purpose: [ nil, "" ]).distinct.pluck(:purpose)).uniq(&:downcase)
    @last_close = BookClose.where(entity: @entity.key).order(:month).last
  end

  def classify
    category = params[:category].to_s.strip
    if category.empty?
      return redirect_to(books_path(entity: @entity.key, anchor: "line-#{params[:id]}"),
                         alert: "Line ##{params[:id]} not saved: pick a category.", status: :see_other)
    end

    # A purpose belongs to a distribution only; the form always offers the
    # field, so one typed beside another category is dropped, not recorded.
    category = nil if category == "none"
    purpose = params[:purpose] if category && @config.categories[category]&.kind == "distribution"
    refusal = nil
    entries = rescue_and_log do
      Books::Classify.call(@entity, ids: [ params[:id] ], category: category,
                                    purpose: purpose, note: params[:note], by: current_user.email, config: @config)
    rescue Books::Classify::Error => e
      refusal = e.message
      nil
    end
    return redirect_to(books_path(entity: @entity.key, anchor: "line-#{params[:id]}"),
                       alert: "Line ##{params[:id]} not saved: #{refusal}.", status: :see_other) if refusal

    entry = entries.first
    said = entry.classified? ? "recorded as #{@config.category(entry.category).label}#{" (#{entry.purpose})" if entry.purpose}" : "returned to the lines waiting"
    redirect_to books_path(entity: @entity.key), notice: "Line ##{entry.id} #{said}.", status: :see_other
  end

  private

  def set_entity
    @config = Books::Config.current
    @entities = @config.entities
    @entity = @config.entity(params[:entity].presence || @entities.first.key)
  rescue Books::Config::Error
    raise ActionController::RoutingError, "no such books entity"
  end
end
