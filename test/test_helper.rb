$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "mailscore"

module MailScore
  class TestCase < Minitest::Test
    TOKENS = { "MAILSCORE_READ_TOKEN" => "read-token-000000000000000000000", "MAILSCORE_WRITE_TOKEN" => "write-token-00000000000000000000" }.freeze

    SETTINGS = {
      "database" => "/data/mailscore.sqlite3",
      "message_size_cap" => 1024,
      "scan_budget" => 8,
      "greylist_timeout" => 300,
      "greylist_expiry" => 86_400,
      "actions" => { "greylist" => 4, "add_header" => 6, "rewrite_subject" => false, "soft_reject" => false, "reject" => 15 }
    }.freeze

    # Each test logs to its own buffer, read back through +log+.
    def before_setup
      super
      @log = StringIO.new
      MailScore.logger = Logger.new(@log)
    end

    def log
      @log.string
    end

    # Runs the block within +seconds+ and +objects+ allocated, loose enough
    # for a slow CI runner but far below what a hostile message once cost.
    def assert_cheap(seconds:, objects:)
      allocated = GC.stat(:total_allocated_objects)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = yield
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_operator elapsed, :<, seconds, "took #{elapsed.round(2)}s"
      assert_operator GC.stat(:total_allocated_objects) - allocated, :<, objects, "allocated too many objects"
      result
    end
  end
end
