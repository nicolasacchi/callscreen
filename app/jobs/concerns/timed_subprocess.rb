# Runs an external command (argv array) with a hard wall-clock timeout so a
# hung TTS/render process can never block a job queue forever. A stuck
# render_phrase.py would otherwise freeze the single-threaded :rendering queue,
# and a stuck clone_render.py would consume one of the 3 shared :default
# threads (starving call processing) — exactly what the queue split prevents.
module TimedSubprocess
  extend ActiveSupport::Concern

  class TimeoutError < StandardError; end

  # Captures combined stdout+stderr; kills the process if it exceeds `timeout`
  # seconds. Returns the captured output on a zero exit; raises TimeoutError on
  # timeout or RuntimeError on a non-zero exit. A reader thread drains the pipe
  # continuously so a chatty child can't deadlock on a full pipe buffer.
  def run_timed(cmd, timeout:, label: File.basename(cmd[1].to_s.presence || cmd[0].to_s))
    require "open3"
    Open3.popen2e(*cmd) do |_stdin, out, wait_thr|
      reader = Thread.new { out.read }
      unless wait_thr.join(timeout)
        Process.kill("KILL", wait_thr.pid)
        reader.join(2)
        raise TimeoutError, "#{label} exceeded #{timeout}s and was killed"
      end
      output = reader.value.to_s
      status = wait_thr.value
      unless status.success?
        raise "#{label} exit=#{status.exitstatus}: #{output.last(2_000)}"
      end
      output
    end
  end
end
