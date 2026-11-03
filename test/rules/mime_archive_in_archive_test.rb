require "test_helper"

class MailScore::Rules::MimeArchiveInArchiveTest < MailScore::TestCase
  def test_a_zip_holding_an_archive
    hit = run_rule(zip("docs/inner.rar"))

    assert_equal "ATTACHMENT_NESTED_ARCHIVE", hit.name
    assert_equal 5.0, hit.weight
    assert_equal "a.zip: docs/inner.rar", hit.detail
  end

  def test_a_zip_of_documents_does_not_fire
    assert_nil run_rule(zip("report.pdf"))
  end

  private
    def zip(entry)
      [ "PK\x03\x04".b + "\0" * 22 + [ entry.bytesize ].pack("v") + "\0\0" + entry ].pack("m")
    end

    def run_rule(body)
      message = MailScore::Message.new("Content-Type: application/zip; name=a.zip\nContent-Transfer-Encoding: base64\n\n#{body}")
      MailScore::Rules::MimeArchiveInArchive.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
