require "test_helper"

class MailScore::Rules::TestStringTest < MailScore::TestCase
  STRING = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"

  def test_the_test_string_in_the_body
    hit = run_rule("Subject: test\n\nThis is the test string:\n#{STRING}\n")

    assert_equal [ "SPAM_TEST_STRING", 0.0, { action: "reject" } ], [ hit.name, hit.weight, hit.data ]
    assert run_rule("Content-Type: text/plain\nContent-Transfer-Encoding: base64\n\n#{[ STRING ].pack("m")}")
    assert run_rule("Content-Type: text/html\n\n<p>#{STRING}</p>")
  end

  def test_a_long_part_or_another_string
    assert_nil run_rule("Subject: test\n\n#{"x" * 8192}\n#{STRING}\n")
    assert_nil run_rule("Subject: test\n\n#{STRING.sub("X", "Y")}\n")
    assert_nil run_rule("Subject: #{STRING}\n\nbody")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::TestString.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
