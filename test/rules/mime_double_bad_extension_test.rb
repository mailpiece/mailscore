require "test_helper"

class MailScore::Rules::MimeDoubleBadExtensionTest < MailScore::TestCase
  def test_a_risky_file_behind_a_document_extension
    hit = run_rule("application/octet-stream; name=\"invoice.pdf .exe\"")

    assert_equal "ATTACHMENT_DISGUISED_EXTENSION", hit.name
    assert_equal 3.0, hit.weight
    assert_equal "invoice.pdf .exe", hit.detail
    assert run_rule("application/octet-stream; name=photo.JPG.scr.")
  end

  def test_a_single_or_harmless_double_extension_does_not_fire
    assert_nil run_rule("application/octet-stream; name=setup.exe")
    assert_nil run_rule("application/octet-stream; name=setup.v2.exe")
    assert_nil run_rule("application/pdf; name=report.final.pdf")
  end

  private
    def run_rule(content_type)
      message = MailScore::Message.new("Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: #{content_type}\n\nx\n--b--\n")
      MailScore::Rules::MimeDoubleBadExtension.new(MailScore::Config.parse(SETTINGS, env: TOKENS), nil).run(message, MailScore::Envelope.read({}, message))
    end
end
