require "test_helper"
require "mailscore/server"
require "net/http"
require "open3"
require "socket"

class MailScore::ServerTest < MailScore::TestCase
  EXE = File.expand_path("../exe/mailscore", __dir__)

  def setup
    @dir = Dir.mktmpdir
  end

  def test_prepare_sets_a_global_regexp_timeout_and_creates_the_database
    previous = Regexp.timeout
    config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3")), env: TOKENS)

    MailScore::Server.new(config).prepare

    assert_equal config.regexp_timeout, Regexp.timeout
    assert File.exist?(config.database)
  ensure
    Regexp.timeout = previous
    MailScore.nameservers = nil
  end

  def test_prepare_warns_once_of_a_short_token_without_logging_it
    settings = SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"))

    MailScore::Server.new(MailScore::Config.parse(settings, env: TOKENS)).prepare
    assert_empty log

    MailScore::Server.new(MailScore::Config.parse(settings, env: { "MAILSCORE_READ_TOKEN" => "short-token" })).prepare
    assert_equal 1, log.scan("WARN -- : a token is shorter than 32 characters").size
    refute_includes log, "short-token"
  ensure
    MailScore.nameservers = nil
  end

  def test_puma_refuses_a_body_past_the_message_size_cap_before_reading_it
    config = MailScore::Config.parse(SETTINGS.merge("message_size_cap" => 1000), env: TOKENS)

    options = MailScore::Server.new(config).send(:puma_configuration, Object.new).clamp

    assert_equal 1000 + MailScore::Server::BODY_HEADROOM, options[:http_content_length_limit]
  end

  def test_puma_listens_on_the_bind_address_and_port
    config = MailScore::Config.parse(SETTINGS.merge("bind" => "::1", "port" => 9090), env: TOKENS)

    assert_equal [ "tcp://[::1]:9090" ], MailScore::Server.new(config).send(:puma_configuration, Object.new).clamp[:binds]
  end

  def test_a_model_that_cannot_be_loaded_stops_the_daemon_at_boot
    database = File.join(@dir, "mailscore.sqlite3")
    { { "language_model" => File.join(@dir, "lid.176.ftz") } => "language_model: cannot load #{@dir}/lid.176.ftz",
      { "fasttext" => true, "fasttext_model" => "#{@dir}/missing/fasttext.bin" } => "fasttext_model: no such directory: #{@dir}/missing" }.each do |settings, message|
      config = MailScore::Config.parse(SETTINGS.merge("database" => database, **settings), env: TOKENS)

      error = assert_raises(MailScore::ConfigError) { MailScore::Server.new(config).prepare }
      assert_equal message, error.message
    end
  ensure
    MailScore.nameservers = nil
  end

  def test_training_runs_in_a_child_process
    config = MailScore::Config.parse(SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"), "fasttext" => true,
      "fasttext_min_samples" => 1), env: TOKENS)
    database = MailScore::Database.new(config.database, busy_timeout: 5).tap(&:prepare)
    samples = MailScore::Classifier::Samples.new(config, database)
    %w[ spam ham ].each { |klass| 6.times { samples.add(MailScore::Message.new("Subject: #{klass} #{it}\n\n#{klass} words"), klass, "#{klass} #{it}") } }

    server = MailScore::Server.new(config)
    server.define_singleton_method(:fork) { |*| raise "forked the worker" }
    server.send(:train)

    assert_predicate $?, :success?
    assert File.exist?(config.fasttext_model)
    assert_equal 1, database.execute("SELECT count(*) FROM fasttext_trainings").dig(0, 0)
  ensure
    database&.close
  end

  def test_a_background_loop_logs_an_error_by_its_class_and_goes_on
    config = MailScore::Config.parse(SETTINGS.merge("expire_every" => 0.01), env: TOKENS)
    database = Object.new
    calls = Queue.new
    database.define_singleton_method(:expire) { calls << :expire; raise ArgumentError, "secret" if calls.size == 1 }
    database.define_singleton_method(:execute) { |*| [ [ 0 ] ] }

    thread = MailScore::Server.new(config).send(:expire_in_the_background, database)
    2.times { calls.pop(timeout: 5) || flunk("expiry stopped") }

    assert_match(/expiry failed: ArgumentError\n/, log)
    refute_match(/secret/, log)
  ensure
    thread&.kill
  end

  def test_the_daemon_serves_from_several_workers
    port = TCPServer.open("127.0.0.1", 0) { it.addr[1] }
    pid = spawn(TOKENS, RbConfig.ruby, "-Ilib", EXE, write_config("port" => port, "workers" => 2), out: File::NULL, err: File::NULL)

    assert_equal [ "pong", 2 ], wait_for_workers(port, pid)
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{port}/health"), "Authorization" => "Bearer read-token-000000000000000000000")
    assert_equal "200", response.code
  ensure
    if pid
      Process.kill("TERM", pid)
      Process.wait(pid)
    end
  end

  def test_a_bad_setting_stops_the_daemon_at_boot
    _, error, status = Open3.capture3(TOKENS, RbConfig.ruby, "-Ilib", EXE, write_config("scan_budget" => 0))

    refute_predicate status, :success?
    assert_equal "mailscore: scan_budget must be a positive number\n", error
  end

  def test_a_config_named_but_missing_stops_the_daemon_at_boot
    _, error, status = Open3.capture3(TOKENS, RbConfig.ruby, "-Ilib", EXE, File.join(@dir, "missing.yml"))

    refute_predicate status, :success?
    assert_match(/\Amailscore: No such file or directory/, error)
  end

  def test_a_database_in_a_missing_directory_stops_the_daemon_at_boot
    database = File.join(@dir, "missing", "mailscore.sqlite3")

    _, error, status = Open3.capture3(TOKENS, RbConfig.ruby, "-Ilib", EXE, write_config("database" => database))

    refute_predicate status, :success?
    assert_equal "mailscore: database: unable to open database file: #{database}\n", error
  end

  def test_a_nameserver_that_does_not_resolve_stops_the_daemon_at_boot
    _, error, status = Open3.capture3(TOKENS, RbConfig.ruby, "-Ilib", EXE, write_config("nameservers" => [ "unbound.invalid" ]))

    refute_predicate status, :success?
    assert_match(/\Amailscore: nameservers: /, error)
  end

  private
    def write_config(settings = {})
      File.join(@dir, "mailscore.yml").tap do |path|
        File.write(path, SETTINGS.merge("database" => File.join(@dir, "mailscore.sqlite3"), **settings).to_yaml)
      end
    end

    def wait_for_workers(port, pid)
      50.times do
        workers = IO.popen([ "pgrep", "-P", pid.to_s ], &:readlines).size
        return [ Net::HTTP.get(URI("http://127.0.0.1:#{port}/ping")), workers ] if workers == 2
        sleep 0.1
      rescue Errno::ECONNREFUSED
        sleep 0.1
      end
      flunk "the daemon did not boot two workers"
    end
end
