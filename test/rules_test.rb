require "test_helper"

class MailScore::RulesTest < MailScore::TestCase
  class ExampleRule < MailScore::Rule
    NAME = "EXAMPLE"
    GROUP = "headers"
    WEIGHT = 1.5
    DESCRIPTION = "Fires on example mail"

    def run(subject)
      MailScore::Hit.new(name: NAME, weight: WEIGHT, detail: subject) if subject.include?("example")
    end
  end

  def test_the_catalogue_lists_each_rule_by_its_constants
    assert_equal [ { name: "EXAMPLE", weight: 1.5, description: "Fires on example mail", group: "headers" } ], MailScore::Rules.catalogue([ ExampleRule ])
  end

  def test_a_rule_with_several_symbols_lists_each
    rule = Class.new { const_set(:GROUP, "mime"); const_set(:SYMBOLS, { "ONE" => [ 1, "First" ], "TWO" => [ -0.5, "Second" ] }) }

    assert_equal [ { name: "ONE", weight: 1, description: "First", group: "mime" }, { name: "TWO", weight: -0.5, description: "Second", group: "mime" } ],
      MailScore::Rules.catalogue([ rule ])
  end

  def test_dns_lists_are_in_the_rbl_and_surbl_groups
    list = ->(symbol) { { "zone" => "#{symbol.downcase}.example", "symbol" => symbol, "weight" => 1 } }
    config = MailScore::Config.parse(SETTINGS.merge("dnsbl" => [ list.("ZEN") ], "uribl" => [ list.("DBL") ]), env: TOKENS)

    groups = MailScore::Rules.catalogue([ MailScore::Rules::DnsLists ], config:).to_h { [ it[:name], it[:group] ] }
    assert_equal({ "ZEN" => "rbl", "ZEN_LOOKUP_FAILED" => "rbl", "DBL" => "surbl", "DBL_LOOKUP_FAILED" => "surbl" }, groups)
  end

  def test_a_rule_returns_a_hit_or_nil
    assert_equal MailScore::Hit.new(name: "EXAMPLE", weight: 1.5, detail: "an example"), ExampleRule.new(nil, nil).run("an example")
    assert_nil ExampleRule.new(nil, nil).run("plain")
  end

  def test_every_rule_in_the_catalogue_declares_its_constants_and_a_unique_name
    MailScore::Rules::ALL.each do |rule|
      assert_match(/\A[A-Z][A-Z0-9_]*\z/, rule::NAME)
      assert_operator rule, :<, MailScore::Rule
      assert rule.method_defined?(:run), "#{rule} has no run"
    end

    rules = MailScore::Rules.constants.map { MailScore::Rules.const_get(it) }.grep(Class).select { it.const_defined?(:NAME) }
    assert_empty rules - MailScore::Rules::ALL

    catalogue = MailScore::Rules.catalogue([ *MailScore::Rules::ALL, MailScore::Greylister ])
    catalogue.each do |symbol|
      assert_match(/\A[A-Z][A-Z0-9_]*\z/, symbol[:name])
      assert_kind_of Numeric, symbol[:weight]
      refute_empty symbol[:description]
      assert_includes MailScore::Rules.groups, symbol[:group]
    end
    assert_equal catalogue.size, catalogue.map { it[:name] }.uniq.size
  end
end
