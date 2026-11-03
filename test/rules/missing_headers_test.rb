require "test_helper"

class MailScore::Rules::MissingHeadersTest < MailScore::TestCase
  RAW = <<~MAIL
    From: alice@example.com
    To: bob@example.net
    Date: Tue, 03 Nov 2026 10:00:00 +0000
    Message-ID: <1@example.com>
    Subject: Hello

    body
  MAIL

  RULES = {
    "DATE_MISSING" => [ MailScore::Rules::MissingDate, "Date", 1.0 ],
    "MESSAGE_ID_MISSING" => [ MailScore::Rules::MissingMid, "Message-ID", 2.5 ],
    "FROM_MISSING" => [ MailScore::Rules::MissingFrom, "From", 2.0 ],
    "TO_MISSING" => [ MailScore::Rules::MissingTo, "To", 2.0 ]
  }.freeze

  def test_each_fires_when_its_header_is_absent
    RULES.each do |name, (rule, header, weight)|
      assert_equal [ name, weight ], run_rule(rule, RAW.sub(/^#{header}:.*\n/, "")).then { [ it.name, it.weight ] }
    end
  end

  def test_an_empty_date_or_from_counts_as_missing
    %w[ DATE_MISSING FROM_MISSING ].each do |name|
      rule, header, _ = RULES.fetch(name)
      assert_equal name, run_rule(rule, RAW.sub(/^#{header}:.*$/, "#{header}: ")).name
    end
  end

  def test_an_empty_message_id_or_to_is_present
    %w[ MESSAGE_ID_MISSING TO_MISSING ].each do |name|
      rule, header, _ = RULES.fetch(name)
      assert_nil run_rule(rule, RAW.sub(/^#{header}:.*$/, "#{header}: "))
    end
  end

  def test_none_fires_on_a_complete_message
    RULES.each_value { |rule, _, _| assert_nil run_rule(rule, RAW) }
  end

  private
    def run_rule(rule, raw)
      message = MailScore::Message.new(raw)
      rule.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
