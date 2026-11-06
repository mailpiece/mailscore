require "test_helper"

class MailScore::Rules::CompromisedHostTest < MailScore::TestCase
  def test_a_php_script
    assert_equal [ [ "PHP_SCRIPT_HEADER", 0.0, "1000:mailer.php" ] ], hits("X-PHP-Originating-Script: 1000:mailer.php").map { [ it.name, it.weight, it.detail ] }
    assert_equal [ "PHP_SCRIPT_HEADER" ], names("X-PHP-Script: example.com/contact.php for 203.0.113.9")
  end

  def test_a_php_script_run_as_root_or_from_eval
    assert_equal %w[ PHP_SCRIPT_HEADER PHP_SCRIPT_AS_ROOT ], names("X-PHP-Originating-Script: 0:mailer.php")
    assert_equal %w[ PHP_SCRIPT_HEADER PHP_SCRIPT_EVAL ], names("X-PHP-Script: example.com/x.php(12) : eval()'d code for 203.0.113.9")
  end

  def test_a_script_in_a_hidden_path
    assert_equal %w[ PHP_SCRIPT_HEADER SCRIPT_HIDDEN_PATH ], names("X-PHP-Script: example.com/wp-content/.cache/x.php for 203.0.113.9")
    assert_equal %w[ PHP_SCRIPT_HEADER SCRIPT_HIDDEN_PATH ], names("X-PHP-Originating-Script: 1000:.x.php")
    assert_equal [ [ "SCRIPT_SOURCE_HEADER", "X-Source-Args" ], [ "SCRIPT_HIDDEN_PATH", "/usr/bin/php /home/a/.tmp/run.php" ] ],
      hits("X-Source-Args: /usr/bin/php /home/a/.tmp/run.php").map { [ it.name, it.detail ] }
  end

  def test_a_parent_or_current_directory_is_not_hidden
    assert_equal [ "PHP_SCRIPT_HEADER" ], names("X-PHP-Script: example.com/a/../b/./x.php for 203.0.113.9")
    assert_equal [ "PHP_SCRIPT_HEADER" ], names("X-PHP-Originating-Script: 1000:../x.php")
    assert_equal [ "SCRIPT_SOURCE_HEADER" ], names("X-Source-Args: /usr/bin/php /home/a/../run.php")
  end

  def test_source_headers
    assert_equal [ "SCRIPT_SOURCE_HEADER" ], names("X-Source-Dir: example.com:/public_html")
  end

  private
    def names(headers)
      hits(headers).map(&:name)
    end

    def hits(headers)
      message = MailScore::Message.new("#{headers}\nSubject: hi\n\nbody")
      MailScore::Rules::CompromisedHost.new(nil, nil).run(message, MailScore::Envelope.read({}, message))
    end
end
