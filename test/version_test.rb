require "test_helper"

class MailScore::VersionTest < MailScore::TestCase
  def test_the_version_is_a_release_number
    assert_match(/\A\d+\.\d+\.\d+\z/, MailScore::VERSION)
  end
end
