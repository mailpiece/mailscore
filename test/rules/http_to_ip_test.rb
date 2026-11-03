require "test_helper"

class MailScore::Rules::HttpToIpTest < MailScore::TestCase
  def test_a_url_to_a_bare_ip
    hit = run_rule("Content-Type: text/html\n\n<a href='http://198.51.100.7/login'>log in</a>")

    assert_equal "LINK_TO_IP_ADDRESS", hit.name
    assert_equal 1.0, hit.weight
    assert_equal "198.51.100.7", hit.detail
    assert_equal "[2001:db8::1]", run_rule("Subject: x\n\nsee http://[2001:db8::1]/x").detail
  end

  def test_a_url_to_a_name_does_not_fire
    assert_nil run_rule("Subject: x\n\nsee http://198.51.100.7.example.com/ and 198.51.100.7")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::HttpToIp.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
