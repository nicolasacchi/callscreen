class RecordingsController < ApplicationController
  RECORDINGS_ROOT = Rails.root.join("storage", "recordings")
  # Same character set as TelnyxController::CALL_SID_FORMAT; admin can only serve
  # files whose name matches a Telnyx-shaped call_sid + literal .wav.
  FILENAME_FORMAT = /\A[A-Za-z0-9_:=\-]{1,256}\z/

  before_action :authenticate_tenant!

  def show
    # Tenants can only access recordings of their own calls. Super-admins
    # bypass the scope (they may impersonate any tenant for triage).
    scope = current_tenant&.super_admin? ? Call.all : current_tenant.calls
    call = scope.find(params[:id])
    return head :not_found unless call.call_sid.to_s.match?(FILENAME_FORMAT)

    path = RECORDINGS_ROOT.join("#{call.call_sid}.wav")
    return head :not_found unless path.exist?

    send_file path, type: "audio/wav", disposition: :inline
  end

  private

  def current_tenant
    @current_tenant ||= warden.user(:tenant)
  end
end
