require "test_helper"

class MailScore::Rules::MimeBadExtensionTest < MailScore::TestCase
  def test_a_risky_attachment
    hit = run_rule(attachment(%(application/octet-stream\nContent-Disposition: attachment; filename="Invoice.EXE. ")))

    assert_equal "ATTACHMENT_RISKY_EXTENSION", hit.name
    assert_equal 2.0, hit.weight
    assert_equal "Invoice.EXE. ", hit.detail
    assert_equal "pay.html", run_rule(attachment("text/html; name=pay.html")).detail
  end

  def test_a_risky_file_inside_a_zip
    zip = "PK\x03\x04".b + "\0" * 22 + [ 9 ].pack("v") + "\0\0" + "setup.vbs"

    assert_equal "setup.vbs", run_rule(attachment("application/zip; name=a.zip\nContent-Transfer-Encoding: base64", [ zip ].pack("m"))).detail
  end

  def test_a_control_character_in_a_name_hides_nothing
    nul = "--b\nContent-Type: application/octet-stream\nContent-Disposition: attachment; filename*=UTF-8''a%00\n\nx\n"
    exe = "--b\nContent-Type: application/octet-stream\nContent-Disposition: attachment; filename=\"invoice.pdf.exe\"\n\nMZ\n"
    message = MailScore::Message.new("Content-Type: multipart/mixed; boundary=b\n\n#{nul}#{exe}--b--\n")

    assert_equal [ "a", "invoice.pdf.exe" ], message.content.attachments.map(&:name)
    [ MailScore::Rules::MimeBadExtension, MailScore::Rules::MimeDoubleBadExtension ].each do |rule|
      assert_equal "invoice.pdf.exe", rule.new(nil, nil).run(message, MailScore::Envelope.read({}, message))&.detail
    end
    assert_equal "exe", MailScore::Content.extension("evil\0.exe")
    assert_equal [ "évil.exe" ], MailScore::Content.zip_entries("PK\x03\x04".b + "\0" * 22 + [ 10 ].pack("v") + "\0\0" + "\xC3\xA9vil\0.exe".b)
  end

  def test_documents_do_not_fire
    assert_nil run_rule(attachment("application/pdf; name=report.pdf"))
    assert_nil run_rule("Content-Type: text/html\n\n<p>hi</p>")
  end

  private
    def attachment(headers, body = "data")
      "Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nsee attached\n--b\nContent-Type: #{headers}\n\n#{body}\n--b--\n"
    end

    def run_rule(raw)
      message = MailScore::Message.new(raw)
      MailScore::Rules::MimeBadExtension.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
