require "uri"

# Downloads a Telnyx recording to local storage and returns the absolute
# path. Used by both ScreeningJob (post-greeting capture) and the legacy
# TranscribeRecordingJob (whitelisted-voicemail path).
#
# Hosts where Telnyx legitimately serves recording URLs:
#   *.telnyx.com:        their API endpoints (used during call control)
#   s3.amazonaws.com:    legacy path-style for the telephony-recorder S3 bucket
#   *.s3.amazonaws.com:  virtual-hosted style (e.g. telephony-recorder-prod.s3.amazonaws.com)
#   *.s3.<region>.amazonaws.com: region-specific S3 endpoints
# AWS pre-signed URLs carry their own auth in query params; we don't add
# the TELNYX_API_KEY header to S3 hosts to avoid leaking it.
class RecordingDownloader
  TRUSTED_HOST_PATTERNS = [
    /\A[a-z0-9.-]+\.telnyx\.com\z/i,
    /\As3\.amazonaws\.com\z/i,
    /\A[a-z0-9.-]+\.s3\.amazonaws\.com\z/i,
    /\A[a-z0-9.-]+\.s3\.[a-z0-9-]+\.amazonaws\.com\z/i
  ].freeze

  TELNYX_API_HOST = /\A[a-z0-9.-]+\.telnyx\.com\z/i

  RECORDINGS_DIR = Rails.root.join("storage", "recordings")

  def self.fetch(call)
    new(call).fetch
  end

  def initialize(call)
    @call = call
  end

  def fetch
    FileUtils.mkdir_p(RECORDINGS_DIR)
    path = RECORDINGS_DIR.join("#{@call.call_sid}.wav")
    expanded = File.expand_path(path)
    raise "Path traversal blocked for call_sid #{@call.call_sid.inspect}" \
      unless expanded.start_with?(RECORDINGS_DIR.to_s + "/")

    uri = URI.parse(@call.recording_url.to_s)
    raise "Invalid recording URL host: #{uri.host.inspect}" \
      unless uri.host && TRUSTED_HOST_PATTERNS.any? { |re| uri.host.match?(re) }

    headers = {}
    # Only attach the Telnyx API key when the host is actually Telnyx's API.
    # S3 pre-signed URLs already carry auth in their query string; sending the
    # header anywhere else would leak it.
    if uri.host.match?(TELNYX_API_HOST) && ENV["TELNYX_API_KEY"].present?
      headers["Authorization"] = "Bearer #{ENV['TELNYX_API_KEY']}"
    end

    response = HTTParty.get(@call.recording_url, headers: headers, timeout: 60)
    raise "Download failed: HTTP #{response.code}" unless response.success?

    File.binwrite(expanded, response.body)
    expanded
  end
end
