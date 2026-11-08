require "test_helper"

class MailScore::SpamHeadersTest < MailScore::TestCase
  THRESHOLDS = MailScore::Config.parse(SETTINGS, env: TOKENS).thresholds

  def test_a_flagged_message
    assert_equal [ [ "X-Spam-Flag", "YES" ], [ "X-Spam-Score", "7.3" ], [ "X-Spam-Level", "*******" ],
      [ "X-Spam-Status", "Yes, score=7.3 required=6.0 tests=FIVE,TWO" ], [ "X-Spam-Action", "add header" ] ],
      headers("add_header", 7.3, %w[ FIVE TWO ])
  end

  def test_a_message_not_flagged
    assert_equal [ [ "X-Spam-Flag", "NO" ], [ "X-Spam-Score", "2.0" ], [ "X-Spam-Level", "**" ],
      [ "X-Spam-Status", "No, score=2.0 required=6.0 tests=TWO" ], [ "X-Spam-Action", "no action" ] ],
      headers("no_action", 2, %w[ TWO ])
  end

  def test_every_action_but_no_action_is_flagged
    %w[ add_header rewrite_subject soft_reject reject ].each do |action|
      assert_equal "YES", headers(action, 20).to_h["X-Spam-Flag"]
    end
  end

  def test_the_level_is_left_out_below_one_point
    assert_nil headers("no_action", 0.9).to_h["X-Spam-Level"]
    assert_equal "-0.5", headers("no_action", -0.5).to_h["X-Spam-Score"]
    assert_nil headers("no_action", -0.5).to_h["X-Spam-Level"]
    assert_equal "0.0", headers("no_action", -0.04).to_h["X-Spam-Score"]
  end

  def test_the_level_stops_at_50_stars
    assert_equal "*" * 50, headers("reject", 83.6).to_h["X-Spam-Level"]
    assert_equal "*" * 50, headers("reject", 50).to_h["X-Spam-Level"]
  end

  def test_required_is_the_lowest_visible_action_switched_on
    rewrite = THRESHOLDS.merge("add_header" => nil, "rewrite_subject" => 8.0)
    reject_only = THRESHOLDS.merge("add_header" => nil, "soft_reject" => 10.0)
    none = THRESHOLDS.merge("add_header" => nil, "reject" => nil)

    assert_equal "No, score=1.0 required=8.0 tests=none", headers("no_action", 1, thresholds: rewrite).to_h["X-Spam-Status"]
    assert_equal "No, score=1.0 required=15.0 tests=none", headers("no_action", 1, thresholds: reject_only).to_h["X-Spam-Status"]
    assert_equal "No, score=1.0 tests=none", headers("no_action", 1, thresholds: none).to_h["X-Spam-Status"]
  end

  def test_no_symbols_is_tests_none
    assert_equal "No, score=0.0 required=6.0 tests=none", headers("no_action", 0).to_h["X-Spam-Status"]
  end

  def test_a_value_never_carries_a_cr_or_an_lf
    assert_equal "Yes, score=7.0 required=6.0 tests=FIVEBcc: x,TWO", headers("add_header", 7, [ "FIVE\r\nBcc: x", "TWO" ]).to_h["X-Spam-Status"]
  end

  private
    def headers(action, score, names = [], thresholds: THRESHOLDS)
      hits = names.map { MailScore::Hit.new(name: it, weight: 1.0) }
      verdict = MailScore::Verdict.new(action:, score: score.to_f, complete: true, hits:, subject: nil)
      MailScore::SpamHeaders.new(verdict, thresholds).to_a
    end
end
