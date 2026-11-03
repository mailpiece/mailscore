require "test_helper"

class MailScore::Rules::HtmlMetaRefreshUrlTest < MailScore::TestCase
  def test_a_meta_refresh_to_a_url
    hit = run_rule(%(<html><head><META HTTP-EQUIV="Refresh" content="0; URL=http://evil.example/"></head></html>))

    assert_equal "HTML_AUTO_REDIRECT", hit.name
    assert_equal 5.0, hit.weight
    assert_equal "0; URL=http://evil.example/", hit.detail
  end

  def test_other_meta_tags_do_not_fire
    assert_nil run_rule(%(<meta http-equiv="refresh" content="30"><meta name="url" content="url=http://a.example/">))
  end

  private
    def run_rule(html)
      message = MailScore::Message.new("Content-Type: text/html\n\n#{html}")
      MailScore::Rules::HtmlMetaRefreshUrl.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
