require "test_helper"

class MailScore::EnvelopeTest < MailScore::TestCase
  MESSAGE = MailScore::Message.new("From: Sender <sender@example.com>\nTo: one@example.net, two@example.net\n\nbody")

  def test_the_request_headers_make_the_envelope
    envelope = read(
      "HTTP_IP" => "203.0.113.9", "HTTP_HELO" => "mx.example.com", "HTTP_HOSTNAME" => "unknown",
      "HTTP_FROM" => "<bounce@example.com>", "HTTP_RCPT" => "<a@example.net>, b@example.net",
      "HTTP_DELIVER_TO" => "<a@example.net>", "HTTP_USER" => "alice", "HTTP_TLS_VERSION" => "TLSv1.3",
      "HTTP_TLS_CIPHER" => "TLS_AES_256_GCM_SHA384", "HTTP_QUEUE_ID" => "4Xyz")

    assert_equal "203.0.113.9", envelope.ip
    assert_equal "mx.example.com", envelope.helo
    assert_equal "unknown", envelope.hostname
    assert_equal "bounce@example.com", envelope.from
    assert_equal "bounce@example.com", envelope.mail_from
    assert_equal [ "a@example.net", "b@example.net" ], envelope.recipients
    assert_equal "a@example.net", envelope.deliver_to
    assert_equal "alice", envelope.user
    assert_equal "TLSv1.3", envelope.tls_version
    assert_equal "TLS_AES_256_GCM_SHA384", envelope.tls_cipher
    assert_equal "4Xyz", envelope.queue_id
  end

  def test_the_reverse_dns_status_is_one_of_the_known_values
    assert_equal "temporary_failure", read("HTTP_REVERSE_DNS_STATUS" => " Temporary_Failure ").reverse_dns_status
    assert_equal "confirmed", read("HTTP_REVERSE_DNS_STATUS" => "confirmed").reverse_dns_status
    assert_nil read("HTTP_REVERSE_DNS_STATUS" => "timeout").reverse_dns_status
    assert_nil read({}).reverse_dns_status
  end

  def test_the_reverse_dns_status_is_optional_when_built_by_position
    envelope = MailScore::Envelope.new("203.0.113.9", "mx.example.com", nil, "a@example.com", nil, [ "b@example.net" ], nil, nil, nil, nil, nil, [], nil)

    assert_nil envelope.reverse_dns_status
    assert_nil envelope.unconfirmed_hostname
    assert_equal({}, envelope.lookups)
  end

  def test_an_unconfirmed_hostname_is_kept_only_as_a_full_host_name
    assert_equal "host-203-0-113-9.example.net", read("HTTP_UNCONFIRMED_HOSTNAME" => "Host-203-0-113-9.Example.NET.").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "localhost").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "[203.0.113.9]").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "mx-1.").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "bad_name.example.com").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "_dmarc.example.com").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "#{"a" * 64}.example.com").unconfirmed_hostname
    assert_nil read("HTTP_UNCONFIRMED_HOSTNAME" => "#{"a." * 126}com").unconfirmed_hostname
    assert_nil read({}).unconfirmed_hostname
  end

  def test_an_unconfirmed_hostname_is_never_the_hostname
    envelope = read("HTTP_IP" => "203.0.113.9", "HTTP_HOSTNAME" => "unknown", "HTTP_UNCONFIRMED_HOSTNAME" => "mx.example.com")

    assert_equal "unknown", envelope.client_hostname(nil)
    assert_equal "mx.example.com", envelope.unconfirmed_hostname
  end

  def test_repeated_rcpt_headers_arrive_joined_and_blanks_are_dropped
    assert_equal [ "a@example.net", "b@example.net" ], read("HTTP_RCPT" => " <a@example.net> ,, b@example.net, ").recipients
    assert_equal [ "one@example.net", "two@example.net" ], read("HTTP_RCPT" => ", ,").recipients
  end

  def test_a_null_sender
    envelope = read("HTTP_FROM" => "<>")

    assert_equal "", envelope.from
    assert_equal "", envelope.mail_from
    assert_predicate envelope, :null_sender?
  end

  def test_without_from_or_rcpt_the_message_speaks
    envelope = read("HTTP_FROM" => " ")

    assert_equal "sender@example.com", envelope.from
    assert_nil envelope.mail_from
    assert_equal [ "one@example.net", "two@example.net" ], envelope.recipients
    refute_predicate envelope, :null_sender?
    assert_nil envelope.ip
  end

  def test_an_authenticated_sender_or_a_local_client_is_trusted
    networks = [ IPAddr.new("10.0.0.0/8"), IPAddr.new("::1/128") ]

    assert_predicate read("HTTP_USER" => "alice"), :trusted?
    assert_predicate read({ "HTTP_IP" => "10.1.2.3" }, networks), :trusted?
    assert_predicate read({ "HTTP_IP" => "::ffff:10.1.2.3" }, networks), :trusted?
    refute_predicate read({ "HTTP_IP" => "203.0.113.9" }, networks), :trusted?
    refute_predicate read({ "HTTP_IP" => "not an address" }, networks), :trusted?
    refute_predicate read({}, networks), :trusted?
  end

  def test_the_time_left_runs_down_to_zero
    envelope = read({})

    assert_equal Float::INFINITY, envelope.remaining
    assert_in_delta 5, envelope.with(deadline: MailScore::Envelope.now + 5).remaining, 0.1
    assert_equal 0, envelope.with(deadline: MailScore::Envelope.now - 1).remaining
  end

  private
    def read(env, local_networks = [])
      MailScore::Envelope.read(env, MESSAGE, local_networks:)
    end
end
