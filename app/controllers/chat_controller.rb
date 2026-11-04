# /chat moved to /contact, which now holds the chat with Alex (Alex McRitchie, 2026-11-03).
#
#   GET  /chat   301 to /contact, for any visitor, dropping the query string.
#   POST /chat   the old session-only Chat::AlexResponder. Admin-only behind the wall,
#                with no caller in the app; the rack-attack tests probe its throttles.
class ChatController < ApplicationController
  def index
    redirect_to contact_form_path, status: :moved_permanently
  end

  def create
    message = params[:message]
    return render json: { error: "Message required" }, status: :unprocessable_entity if message.blank?

    session[:chat_messages] ||= []
    session[:chat_messages] << { "role" => "user", "content" => message }
    session[:chat_messages] = session[:chat_messages].last(10)

    responder = Chat::AlexResponder.new(session[:chat_messages])
    response_text = responder.respond

    session[:chat_messages] << { "role" => "assistant", "content" => response_text }
    session[:chat_messages] = session[:chat_messages].last(10)

    render json: { response: response_text }
  rescue StandardError => e
    create_error_log(e)
    render json: { error: "Something went wrong. Please try again." }, status: :internal_server_error
  end
end
