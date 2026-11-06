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
      assert_equal "invoice.pdf.exe", rule.new(MailScore::Config.parse(SETTINGS, env: TOKENS), nil).run(message, MailScore::Envelope.read({}, message))&.detail
    end
    assert_equal "exe", MailScore::Content.extension("evil\0.exe")
    assert_equal [ "évil.exe" ], MailScore::Content.zip_entries("PK\x03\x04".b + "\0" * 22 + [ 10 ].pack("v") + "\0\0" + "\xC3\xA9vil\0.exe".b)
  end

  def test_documents_do_not_fire
    assert_nil run_rule(attachment("application/pdf; name=report.pdf"))
    assert_nil run_rule("Content-Type: text/html\n\n<p>hi</p>")
  end

  PE = ("MZ\x90\0".b + "\0" * 56 + [ 0x80 ].pack("V")).ljust(0x80, "\0") + "PE\0\0".b

  def test_a_program_under_a_harmless_name_fires_at_no_weight
    hit = run_rule(attachment("application/pdf; name=invoice.pdf\nContent-Transfer-Encoding: base64", [ PE ].pack("m")))

    assert_equal [ "ATTACHMENT_RISKY_EXTENSION", 0.0, "invoice.pdf is exe" ], [ hit.name, hit.weight, hit.detail ]
    lnk = "L\0\0\0\x01\x14\x02\0\0\0\0\0\xC0\0\0\0\0\0\0F".b + "\0" * 8
    assert_equal "Report.docx is lnk", run_rule(attachment("application/octet-stream; name=Report.docx\nContent-Transfer-Encoding: base64", [ lnk ].pack("m"))).detail
  end

  def test_a_risky_name_keeps_its_weight_over_a_program_found_by_content
    hit = run_rule(attachment("application/octet-stream; name=setup.exe\nContent-Transfer-Encoding: base64", [ PE ].pack("m")))

    assert_equal [ 2.0, "setup.exe" ], [ hit.weight, hit.detail ]
  end

  def test_mz_alone_is_not_a_program
    assert_nil run_rule(attachment("application/pdf; name=a.pdf\nContent-Transfer-Encoding: base64", [ "MZ\x90\0".b + "\0" * 60 ].pack("m")))
    assert_nil run_rule(attachment("application/pdf; name=a.pdf\nContent-Transfer-Encoding: base64", [ PE.sub("PE", "NE") ].pack("m")))
    assert_nil run_rule(attachment("text/plain; name=a.txt", "MZ is a postcode prefix"))
  end

  def test_a_program_kind_off_the_list_does_not_fire
    elf = attachment("application/octet-stream; name=photo.jpg\nContent-Transfer-Encoding: base64", [ "\x7FELF\x02\x01\x01".b ].pack("m"))
    macho = attachment("application/octet-stream; name=update\nContent-Transfer-Encoding: base64", [ "\xCF\xFA\xED\xFE\x07\0\0\x01".b ].pack("m"))
    path = File.join(Dir.mktmpdir, "risky_extensions.txt").tap { File.write(it, "elf\nmacho\n") }

    assert_nil run_rule(elf)
    assert_equal "photo.jpg is elf", run_rule(elf, "risky_extensions" => path).detail
    assert_equal "update is macho", run_rule(macho, "risky_extensions" => path).detail
  end

  def test_a_risky_extensions_file_replaces_the_list
    path = File.join(Dir.mktmpdir, "risky_extensions.txt").tap { File.write(it, "pdf\n") }

    assert_equal "report.pdf", run_rule(attachment("application/pdf; name=report.pdf"), "risky_extensions" => path).detail
    assert_nil run_rule(attachment("application/octet-stream; name=setup.exe"), "risky_extensions" => path)
  end

  private
    def attachment(headers, body = "data")
      "Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nsee attached\n--b\nContent-Type: #{headers}\n\n#{body}\n--b--\n"
    end

    def run_rule(raw, settings = {})
      message = MailScore::Message.new(raw)
      MailScore::Rules::MimeBadExtension.new(MailScore::Config.parse(SETTINGS.merge(settings), env: TOKENS), nil).run(message, MailScore::Envelope.read({}, message))
    end
end
