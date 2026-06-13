require "test_helper"

# TimedSubprocess is the hard wall-clock guard that stops a hung TTS/render
# process from freezing the single-threaded :rendering queue (or starving the
# 3 shared :default threads). Its timeout/kill and non-zero-exit paths were
# previously untested — a regression there is silent and load-bearing.
class TimedSubprocessTest < ActiveSupport::TestCase
  class Runner
    include TimedSubprocess
  end

  setup { @runner = Runner.new }

  test "returns combined stdout+stderr on a zero exit" do
    out = @runner.run_timed([ "sh", "-c", "echo out; echo err 1>&2" ], timeout: 5, label: "echo")
    assert_match "out", out
    assert_match "err", out
  end

  test "raises TimeoutError and kills a process that exceeds the timeout" do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    err = assert_raises(TimedSubprocess::TimeoutError) do
      @runner.run_timed([ "sh", "-c", "sleep 10" ], timeout: 1, label: "sleeper")
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_match(/sleeper exceeded 1s/, err.message)
    assert_operator elapsed, :<, 5, "should kill at the timeout, not wait for the child"
  end

  test "raises with the exit status and output on a non-zero exit" do
    err = assert_raises(RuntimeError) do
      @runner.run_timed([ "sh", "-c", "echo boom 1>&2; exit 3" ], timeout: 5, label: "failer")
    end
    assert_match(/failer exit=3/, err.message)
    assert_match "boom", err.message
  end
end
