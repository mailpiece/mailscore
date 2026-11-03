require "test_helper"

class MailScore::GreylisterTest < MailScore::TestCase
  GREYLISTED = [ "soft_reject", MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "greylisted") ].freeze
  PASS = [ "add_header", MailScore::Hit.new(name: "GREYLISTED", weight: 0, detail: "pass") ].freeze
  T0 = 1_800_000_000

  def setup
    @path = File.join(Dir.mktmpdir, "mailscore.sqlite3")
    @database = MailScore::Database.new(@path, busy_timeout: 5).tap(&:prepare)
    @greylister = greylister(@database)
  end

  def teardown
    @database.close
  end

  def test_a_new_message_is_greylisted
    assert_equal GREYLISTED, greylist(at: 0)
  end

  def test_a_retry_before_the_timeout_is_greylisted
    greylist(at: 0)

    assert_equal GREYLISTED, greylist(at: 299)
  end

  def test_a_pass_keeps_the_action_and_a_greylisting_soft_rejects_it
    assert_equal "soft_reject", greylist(at: 0, action: "rewrite_subject").first
    assert_equal "rewrite_subject", greylist(at: 300, action: "rewrite_subject").first
    assert_equal "greylist", greylist(at: 300, action: "greylist").first
    assert_equal "soft_reject", greylist(at: 300, action: "soft_reject").first
  end

  def test_a_retry_after_the_timeout_passes
    greylist(at: 0)
    greylist(at: 100)

    assert_equal PASS, greylist(at: 300)
    assert_equal PASS, greylist(at: 600)
  end

  def test_the_envelope_key_alone_passes
    greylist(at: 0)

    assert_equal PASS, greylist(at: 300, body: "a new body", rcpt: [ "C@example.net", "b@example.net", "c@example.net" ])
    assert_equal GREYLISTED, greylist(at: 300, body: "another body", from: "z@example.org")
  end

  def test_the_body_key_alone_passes
    greylist(at: 0)

    assert_equal PASS, greylist(at: 300, from: "z@example.org", ip: "198.51.100.7")
    assert_equal GREYLISTED, greylist(at: 300, from: "z@example.org", body: "another body")
  end

  def test_the_body_key_is_the_body_start_with_the_subject_recipients_and_mime_from
    body = "x" * 10_240
    greylist(at: 0, body:, mime_from: "News <News@example.org>")

    assert_equal PASS, greylist(at: 300, from: "z@example.org", body: "#{body}tail", mime_from: "news@example.org", rcpt: [ "C@example.net", "b@example.net" ])
    [ { subject: "other" }, { mime_from: "x@example.org" }, { rcpt: [ "b@example.net" ] }, { body: "y#{body}" } ].each do |change|
      assert_equal GREYLISTED, greylist(at: 300, from: "z@example.org", body:, mime_from: "news@example.org", **change)
    end
  end

def test_the_body_key_reads_the_decoded_subject
  greylist(at: 0, subject: "=?UTF-8?B?aGVsbG8=?=")

  assert_equal PASS, greylist(at: 300, from: "z@example.org", subject: "hello")
end

  def test_the_body_key_reads_a_message_without_a_from_or_subject
    greylist(at: 0, subject: nil, mime_from: nil)

    assert_equal PASS, greylist(at: 300, from: "z@example.org", subject: nil, mime_from: nil)
    assert_equal GREYLISTED, greylist(at: 300, from: "z@example.org", subject: nil, mime_from: "a@example.org")
  end

  def test_ipv4_is_masked_to_a_19
    greylist(at: 0, ip: "203.0.96.1")

    assert_equal PASS, greylist(at: 300, ip: "203.0.127.254", body: "one")
    assert_equal PASS, greylist(at: 300, ip: "::ffff:203.0.100.1", body: "two")
    assert_equal GREYLISTED, greylist(at: 300, ip: "203.0.128.1", body: "three")
  end

  def test_ipv6_is_masked_to_a_64
    greylist(at: 0, ip: "2001:db8:1:2::1")

    assert_equal PASS, greylist(at: 300, ip: "2001:db8:1:2:ffff:ffff:ffff:ffff", body: "one")
    assert_equal GREYLISTED, greylist(at: 300, ip: "2001:db8:1:3::1", body: "two")
  end

  def test_mail_without_a_client_ip_is_keyed_without_a_network
    greylist(at: 0, ip: nil)

    assert_equal PASS, greylist(at: 300, ip: "not an address", body: "one")
  end

  def test_local_networks_pass_without_an_entry
    assert_equal PASS, greylist(at: 0, ip: "10.1.2.3")
    assert_equal PASS, greylist(at: 0, ip: "::1")
    assert_equal PASS, greylist(at: 0, ip: "::ffff:192.168.0.1")
    assert_equal GREYLISTED, greylist(at: 0, ip: "10.1.2.3", local_networks: [])
    assert_equal 2, rows
  end

  def test_authenticated_senders_pass_without_an_entry
    assert_equal PASS, greylist(at: 0, user: "alice")
    assert_equal 0, rows
  end

  def test_entries_expire
    greylist(at: 0)
    @database.expire(now: Time.at(T0 + 86_400))

    assert_equal 0, rows
    assert_equal GREYLISTED, greylist(at: 86_400)
  end

  def test_an_entry_past_its_expiry_starts_over_before_the_sweep
    greylist(at: 0)

    assert_equal GREYLISTED, greylist(at: 86_400)
    assert_equal PASS, greylist(at: 86_700)
  end

  def test_a_pass_pushes_the_expiry_back
    greylist(at: 0)
    greylist(at: 300)

    assert_equal PASS, greylist(at: 86_500)
    assert_equal [ [ 86_400 + 86_500 ] ] * 2, @database.execute("SELECT expires_at - #{T0} FROM greylist")
  end

  def test_a_retry_inside_the_timeout_leaves_the_expiry
    greylist(at: 0)
    greylist(at: 200)

    assert_equal [ [ 0, 86_400 ] ] * 2, @database.execute("SELECT first_seen - #{T0}, expires_at - #{T0} FROM greylist")
    assert_equal GREYLISTED, greylist(at: 86_400)
    assert_equal [ [ 86_400, 172_800 ] ] * 2, @database.execute("SELECT first_seen - #{T0}, expires_at - #{T0} FROM greylist")
  end

  def test_a_pass_on_one_key_leaves_the_other_alone
    greylist(at: 0)

    assert_equal PASS, greylist(at: 300, body: "a new body")
    assert_equal 2, rows
    assert_equal GREYLISTED, greylist(at: 600, from: "z@example.org", body: "a new body")
  end

  def test_concurrent_workers_share_one_entry_per_key
    databases = Array.new(8) { MailScore::Database.new(@path, busy_timeout: 5) }
    answers = databases.map { |database| Thread.new { greylist(at: 0, greylister: greylister(database)) } }.map(&:value)

    assert_equal [ GREYLISTED ], answers.uniq
    assert_equal 2, rows
    assert_equal PASS, greylist(at: 300)
  ensure
    databases&.each(&:close)
  end

  private
    def greylister(database, settings = {})
      MailScore::Greylister.new(MailScore::Config.parse(SETTINGS.merge(settings), env: TOKENS), database)
    end

    def greylist(at:, ip: "203.0.113.9", from: "a@example.org", rcpt: [ "b@example.net", "c@example.net" ], body: "body", user: nil,
      subject: "hello", mime_from: nil, action: "add_header", local_networks: MailScore::Config.parse(SETTINGS, env: TOKENS).local_networks, greylister: @greylister)
      headers = { "Subject" => subject, "From" => mime_from }.compact.map { |name, value| "#{name}: #{value}\n" }.join
      message = MailScore::Message.new("#{headers}\n#{body}")
      envelope = MailScore::Envelope.new(ip:, helo: nil, hostname: nil, from:, recipients: rcpt, deliver_to: nil, user:,
        tls_version: nil, tls_cipher: nil, queue_id: nil, deadline: nil, mail_from: from, local_networks:)
      greylister.greylist(message, envelope, action, now: Time.at(T0 + at))
    end

    def rows
      @database.execute("SELECT count(*) FROM greylist").dig(0, 0)
    end
end
