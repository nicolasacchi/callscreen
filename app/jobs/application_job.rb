class ApplicationJob < ActiveJob::Base
  around_perform :set_current_request_id

  private

  def set_current_request_id
    Current.request_id ||= "job-#{job_id}"
    yield
  ensure
    Current.clear_all
  end
end
