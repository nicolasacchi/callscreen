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
  # Raised for retryable download failures (HTTP 5xx/429, timeouts, connection
  # errors) so ScreeningJob/TranscribeRecordingJob retry rather than
  # dead-lettering the recording. Permanent failures (bad host, path
  # traversal, 4xx) keep raising plain RuntimeError and are NOT retried.
  class TransientError < StandardError; end

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

    # Reuse an already-persisted copy (PersistRecordingJob races ScreeningJob
    # to this same path). Crucial when the pre-signed URL has since expired:
    # a re-download would 403 even though the audio is safe on disk.
    return expanded if File.size?(expanded)

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

    response =
      begin
        # follow_redirects: false — the host allowlist above only validates the
        # ORIGINAL URL. HTTParty follows redirects by default, so a trusted-host
        # 30x to an internal target (cloud metadata IP, sidecars) would be
        # followed AND re-send the Telnyx bearer header on the cross-host hop —
        # an SSRF + credential-leak path. A redirect is treated as a hard
        # failure below instead.
        HTTParty.get(@call.recording_url, headers: headers, timeout: 60, follow_redirects: false)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET => e
        raise TransientError, "#{e.class}: #{e.message}"
      end

    unless response.success?
      code = response.code.to_i
      # 5xx / 429 are transient (Telnyx or S3 hiccup) → retryable. A 3xx is an
      # un-followed redirect (see above) and any other 4xx (expired URL, gone)
      # are permanent → hard failure, not retried.
      raise TransientError, "Download failed: HTTP #{code}" if code >= 500 || code == 429
      raise "Download failed: HTTP #{code}"
    end

    # Write-then-rename so two concurrent fetchers (or a killed worker) can
    # never leave a truncated WAV at the final path — rename within the same
    # directory is atomic, and last-complete-write wins.
    tmp = "#{expanded}.#{SecureRandom.hex(4)}.tmp"
    begin
      File.binwrite(tmp, response.body)
      File.rename(tmp, expanded)
    ensure
      FileUtils.rm_f(tmp)
    end
    expanded
  end
end
