# frozen_string_literal: true

# A person's jewelry, added, edited and removed on the person page. Admin only,
# like every write on that page: hub signup is open, and these rows become the
# text of a paid prompt (the iced-out sheet, Appearances::CharacterSheetPrompt).
# A validation refusal is an answer (a flash), not an ErrorLog.
class PersonJewelriesController < ApplicationController
  before_action :require_admin
  before_action :set_person
  before_action :set_jewelry, only: [:update, :destroy]

  def create
    jewelry = @person.jewelries.new(jewelry_params)
    return back(alert: refusal(jewelry)) unless jewelry.valid?

    rescue_and_log(target: @person) { jewelry.save! }
    back(notice: "#{jewelry.name} added to #{@person.full_name}'s jewelry.")
  end

  def update
    @jewelry.assign_attributes(jewelry_params)
    return back(alert: refusal(@jewelry)) unless @jewelry.valid?

    rescue_and_log(target: @person) { @jewelry.save! }
    back(notice: "#{@jewelry.name} saved.")
  end

  def destroy
    rescue_and_log(target: @person) { @jewelry.destroy! }
    back(notice: "#{@jewelry.name} removed.")
  end

  private

  def set_person
    @person = Person.find_by!(slug: params[:person_slug])
  end

  def set_jewelry
    @jewelry = @person.jewelries.find_by!(slug: params[:jewelry_slug])
  end

  def jewelry_params
    params.require(:person_jewelry).permit(:kind, :name, :year, :description, :image_url, :source)
  end

  def refusal(jewelry) = "Jewelry not saved: #{jewelry.errors.full_messages.to_sentence}."

  def back(**flash)
    redirect_to person_path(@person.slug, anchor: "jewelry"), **flash
  end
end
