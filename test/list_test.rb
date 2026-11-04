require "test_helper"

class MailScore::ListTest < MailScore::TestCase
  def setup
    @now = 0
    @path = File.join(Dir.mktmpdir, "shorteners.txt").tap { File.write(it, "bit.ly\n") }
    @list = MailScore::List.new(@path, clock: -> { @now })
  end

  def test_a_changed_file_is_read_again_once_the_check_is_due
    replace "Short.Example\n"

    @now = MailScore::List::CHECK_EVERY - 1
    assert_includes @list, "bit.ly"

    @now = MailScore::List::CHECK_EVERY
    assert_includes @list, "short.example"
    refute_includes @list, "bit.ly"
    assert_includes log, "list reloaded: #{@path}"
  end

  def test_a_file_replaced_with_the_same_mtime_is_read_again
    mtime = File.mtime(@path)
    File.write("#{@path}.new", "goo.gl\n") # same size: only the inode tells
    File.utime(mtime, mtime, "#{@path}.new")
    File.rename("#{@path}.new", @path)

    @now = MailScore::List::CHECK_EVERY
    assert_includes @list, "goo.gl"
    refute_includes @list, "bit.ly"
  end

  def test_a_file_just_emptied_is_read_a_check_later
    File.truncate(@path, 0)
    @now = MailScore::List::CHECK_EVERY
    assert_includes @list, "bit.ly"
    assert_includes log, "list truncated, read on the next check: #{@path}"

    @now *= 2
    refute_includes @list, "bit.ly"
  end

  def test_a_file_emptied_then_written_skips_the_empty_list
    File.truncate(@path, 0)
    @now = MailScore::List::CHECK_EVERY
    assert_includes @list, "bit.ly"

    File.write(@path, "goo.gl\n")
    @now *= 2
    assert_includes @list, "goo.gl"
  end

  def test_an_unchanged_file_is_not_read_again
    @now = MailScore::List::CHECK_EVERY

    assert_includes @list, "bit.ly"
    assert_empty log
  end

  def test_a_missing_or_undecodable_file_keeps_the_last_list
    File.delete(@path)
    @now = MailScore::List::CHECK_EVERY
    assert_includes @list, "bit.ly"

    replace "\xff\n"
    @now *= 2
    assert_includes @list, "bit.ly"

    assert_equal 2, log.scan("list reload failed, kept the last").size
  end

  def test_a_url_within_the_list_matches_a_subdomain
    assert MailScore::Content::Url.parse("https://go.bit.ly/3xYz").within?(@list)
  end

  private
    # Written beside and renamed over, as a cron job should, with a new mtime.
    def replace(text)
      File.binwrite("#{@path}.new", text)
      File.utime(Time.now, Time.now + 60, "#{@path}.new")
      File.rename("#{@path}.new", @path)
    end
end
