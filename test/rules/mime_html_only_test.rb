require "test_helper"

class MailScore::Rules::MimeHtmlOnlyTest < MailScore::TestCase
  def test_html_with_no_text_part
    hit = run_rule("Content-Type: text/html\n\n<p>hi</p>")

    assert_equal "HTML_ONLY", hit.name
    assert_equal 0.2, hit.weight
    assert run_rule("Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/html\n\n<p>hi</p>\n--b\nContent-Type: text/plain; name=notes.txt\n\nnotes\n--b--\n")
  end

  def test_a_text_part_or_plain_mail_does_not_fire
    assert_nil run_rule("Content-Type: multipart/alternative; boundary=b\n\n--b\nContent-Type: text/plain\n\nhi\n--b\nContent-Type: text/html\n\n<p>hi</p>\n--b--\n")
    assert_nil run_rule("Subject: x\n\nhi")
  end

  private
    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::MimeHtmlOnly.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
