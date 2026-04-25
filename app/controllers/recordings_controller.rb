class RecordingsController < ApplicationController
  RECORDINGS_ROOT = Rails.root.join("storage", "recordings")
  FILENAME_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

  before_action :authenticate_admin_user!

  def show
    call = Call.find(params[:id])
    return head :not_found unless call.call_sid.to_s.match?(FILENAME_FORMAT)

    path = RECORDINGS_ROOT.join("#{call.call_sid}.wav")
    return head :not_found unless path.exist?

    send_file path, type: "audio/wav", disposition: :inline
  end
end
