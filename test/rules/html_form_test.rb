require "test_helper"

class MailScore::Rules::HtmlFormTest < MailScore::TestCase
  def test_a_form
    hit = run_rule(%(<p>Verify</p><form action=" https://evil.example/login " method="post"><input type="password"></form>))

    assert_equal "HTML_FORM", hit.name
    assert_equal 1.5, hit.weight
    assert_equal "https://evil.example/login", hit.detail
  end

  def test_no_form_or_the_word_in_text_does_not_fire
    assert_nil run_rule("<p>Fill in the form &lt;form&gt; online</p>")
  end

  private
    def run_rule(html)
      message = MailScore::Message.new("Content-Type: text/html\n\n#{html}")
      MailScore::Rules::HtmlForm.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
