class RecordingsController < ApplicationController
  before_action :authenticate_admin_user!

  def show
    call = Call.find(params[:id])
    if call.recording_local_path.present? && File.exist?(call.recording_local_path)
      send_file call.recording_local_path, type: "audio/wav", disposition: :inline
    else
      head :not_found
    end
  end
end
