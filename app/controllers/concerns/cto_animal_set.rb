# "New set" in the CTO avatar picker (build/_animal_picker; build_chat.js
# #newAnimalSet), for BuildController#cto_animals and CtoChatsController#avatars:
# the next set's locals from the request. KEEP (the visitor's pick) leads the set
# when it is choosable; EXCEPT (the set on screen) is left out while the bank
# allows (CtoAvatarHelper#cto_avatar_set).
module CtoAnimalSet
  extend ActiveSupport::Concern

  private

  def render_animal_set(palette)
    keep = params[:keep].to_s
    keep = nil unless BuildIntake::Portraits.choosable?(keep)
    except = Array(params[:except]).grep(String).first(BuildIntake::Animals::IDS.size)
    render partial: "build/animal_options",
           locals: { avatars: helpers.cto_avatar_set(keep, except: except), picked: keep, palette: palette }
  end
end
