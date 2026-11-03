require "test_helper"

class MailScore::Rules::BounceTest < MailScore::TestCase
  DSN = <<~MAIL
    From: Mail Delivery System <MAILER-DAEMON@mx.example.com>
    Subject: Delivery Status Notification (Failure)
    Content-Type: multipart/report; report-type=delivery-status; boundary=b

    --b
    Content-Type: text/plain

    Delivery failed.
    --b
    Content-Type: message/delivery-status

    Action: failed
    --b--
  MAIL

  RETURNED = <<~MAIL
    From: mailer-daemon@example.com
    Subject: Hello
    Content-Type: multipart/mixed; boundary=b

    --b
    Content-Type: message/rfc822

    Subject: original
    --b--
  MAIL

  def test_a_delivery_or_disposition_report_weighs_in_full
    hit = run_rule(DSN)

    assert_equal [ "BOUNCE", -0.1, "DSN" ], [ hit.name, hit.weight, hit.detail ]
    assert_equal "DSN", run_rule(DSN.sub("delivery-status;", "disposition-notification;").sub("MAILER-DAEMON", "alerts")).detail
  end

  def test_a_null_sender_is_required
    assert_nil run_rule(DSN, from: "<MAILER-DAEMON@mx.example.com>")
    assert_nil run_rule(DSN, from: nil)
    assert_nil run_rule(RETURNED, from: "<mailer-daemon@example.com>")
  end

  def test_a_report_is_read_at_the_top_level_only
    raw = <<~MAIL
      From: someone@example.com
      Content-Type: multipart/mixed; boundary=outer

      --outer
      Content-Type: multipart/report; report-type=disposition-notification; boundary=inner

      --inner--
      --outer--
    MAIL

    assert_nil run_rule(raw)
  end

  def test_a_report_of_another_type_or_spelled_otherwise_is_not_one
    assert_nil run_rule(DSN.sub("delivery-status;", "feedback-report;").sub("MAILER-DAEMON", "alerts").sub("Delivery Status", "Weekly"))
    assert_nil run_rule(DSN.sub("delivery-status;", "Delivery-Status;").sub("MAILER-DAEMON", "alerts").sub("Delivery Status", "Weekly"))
  end

  def test_a_daemon_from_with_bounce_words_weighs_half
    hit = run_rule("From: Postmaster@example.com\nSubject: Undeliverable: hello\n\nbody")

    assert_equal [ -0.05, "postmaster+subj" ], [ hit.weight, hit.detail ]
    assert_equal "mailer-daemon+subj", run_rule("From: mailer-daemon@example.com\nSubject: failure notice\n\nbody").detail
    assert_nil run_rule("From: postmaster@example.com\nSubject: Weekly report\n\nbody")
    assert_equal "postmaster+subj", run_rule("From: postmaster@example.com\nSubject: =?UTF-8?Q?Undeliverable=3A_hello?=\n\nbody").detail
  end

  def test_the_daemon_is_the_whole_local_part_of_the_first_from_address
    assert_nil run_rule("From: x@example.com, postmaster@example.com\nSubject: failure notice\n\nbody")
    assert_nil run_rule("From: postmaster.alerts@example.com\nSubject: failure notice\n\nbody")
  end

  def test_a_daemon_from_returning_a_message_weighs_half
    hit = run_rule(RETURNED)

    assert_equal [ -0.05, "mailer-daemon+message/rfc822" ], [ hit.weight, hit.detail ]
    assert_equal "postmaster+text/rfc822-headers", run_rule(RETURNED.sub("mailer-daemon", "postmaster").sub("message/rfc822", "text/rfc822-headers")).detail
    assert_nil run_rule(RETURNED.sub("mailer-daemon", "newsletter"))
  end

  def test_bounce_words_and_a_returned_message_weigh_a_fifth
    hit = run_rule(RETURNED.sub("mailer-daemon", "newsletter").sub("Subject: Hello", "Subject: Returned mail: see transcript"))

    assert_equal [ -0.02, "message/rfc822+subj" ], [ hit.weight, hit.detail ]
  end

  def test_bounce_words_alone_do_not_fire
    assert_nil run_rule("From: x@example.com\nSubject: Mail delivery failed\n\nbody")
    assert_nil run_rule("From: x@example.com\nSubject: Undeliverables are fine\n\nbody")
  end

  def test_an_old_mdaemon_notice
    hit = run_rule("From: MDaemon@example.com\nX-MDDSN-Message: Yes\nSubject: Zustellung fehlgeschlagen\n\nbody")

    assert_equal [ -0.1, "MDaemon" ], [ hit.weight, hit.detail ]
    assert_nil run_rule("From: MDaemon@example.com\nSubject: Zustellung fehlgeschlagen\n\nbody")
  end

  def test_the_returned_message_is_looked_for_in_the_first_parts
    filler = "--b\nContent-Type: text/plain\n\nx\n" * 8
    raw = RETURNED.sub("--b\nContent-Type: message/rfc822", "#{filler}--b\nContent-Type: message/rfc822")

    assert_nil run_rule(raw)
    assert run_rule(RETURNED.sub("--b\nContent-Type: message/rfc822", "#{"--b\nContent-Type: text/plain\n\nx\n" * 7}--b\nContent-Type: message/rfc822"))
  end

  private
    def run_rule(raw, from: "<>")
      message = MailScore::Message.new(raw)
      MailScore::Rules::Bounce.new(nil, nil).run(message, MailScore::Envelope.read({ "HTTP_FROM" => from }.compact, message))
    end
end
