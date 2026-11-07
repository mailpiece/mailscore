require "test_helper"

class MailScore::Rules::TestStringTest < MailScore::TestCase
  STRING = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"

  def test_the_test_string_in_the_body
    hit = run_rule("Subject: test\n\nThis is the test string:\n#{STRING}\n")

    assert_equal [ "SPAM_TEST_STRING", 0.0, { action: "reject" } ], [ hit.name, hit.weight, hit.data ]
    assert run_rule("Content-Type: text/plain\nContent-Transfer-Encoding: base64\n\n#{[ STRING ].pack("m")}")
    assert run_rule("Content-Type: text/html\n\n<p>#{STRING}</p>")
  end

  def test_the_test_string_past_8_kb
    assert run_rule("Subject: test\n\n#{"x" * 100_000}\n#{STRING}\n")
  end

  def test_the_test_string_in_the_headers
    assert run_rule("Subject: #{STRING}\n\nbody")
    assert run_rule("Subject: =?UTF-8?B?#{[ STRING ].pack("m0")}?=\n\nbody")
    assert run_rule("X-Test: #{STRING}\n\nbody")
  end

  def test_another_string
    assert_nil run_rule("Subject: test\n\n#{STRING.sub("X", "Y")}\n")
    assert_nil run_rule("Content-Type: application/octet-stream; name=a.bin\n\n#{STRING}\n")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::TestString.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
