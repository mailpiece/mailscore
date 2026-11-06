require "mailscore/resolver"
require "mailscore/rule"
require "mailscore/rules/bounce"
require "mailscore/rules/rcpt_bounce_more_one"
require "mailscore/rules/rdns"
require "mailscore/rules/helo_bad_ip"
require "mailscore/rules/helo_bare_ip"
require "mailscore/rules/helo_not_fqdn"
require "mailscore/rules/helo_not_hostname"
require "mailscore/rules/hostname_unknown"
require "mailscore/rules/missing_date"
require "mailscore/rules/missing_mid"
require "mailscore/rules/missing_from"
require "mailscore/rules/missing_to"
require "mailscore/rules/invalid_msgid"
require "mailscore/rules/multiple_from"
require "mailscore/rules/multiple_unique_headers"
require "mailscore/rules/invalid_date"
require "mailscore/rules/date_in_future"
require "mailscore/rules/date_in_past"
require "mailscore/rules/subj_all_caps"
require "mailscore/rules/authentication"
require "mailscore/rules/http_to_ip"
require "mailscore/rules/dns_lists"
require "mailscore/rules/zero_width_space_url"
require "mailscore/rules/url_homograph_attack"
require "mailscore/rules/from_homograph"
require "mailscore/rules/url_only"
require "mailscore/rules/redirector_url_only"
require "mailscore/rules/phishing"
require "mailscore/rules/html_meta_refresh_url"
require "mailscore/rules/html_form"
require "mailscore/rules/mime_html_only"
require "mailscore/rules/mime_base64_text_bogus"
require "mailscore/rules/mime_bad_extension"
require "mailscore/rules/mime_double_bad_extension"
require "mailscore/rules/mime_archive_in_archive"
require "mailscore/rules/fuzzy_match"
require "mailscore/rules/bayes"
require "mailscore/rules/fasttext"
require "mailscore/rules/trap"

module MailScore
  # What a rule returns when it fires. A detail read from the message or
  # the session may carry any bytes, so a string one is kept as UTF-8,
  # scrubbed, for the JSON answer. +data+ is what the rule found for the
  # code after it, such as the DKIM signers reputation reads, and never
  # reaches the answer.
  Hit = Data.define(:name, :weight, :detail, :data) do
    def initialize(name:, weight:, detail: nil, data: nil)
      detail = detail.dup.force_encoding(Encoding::UTF_8).scrub if detail.is_a?(String)
      super
    end
  end

  # One class per rule, a MailScore::Rule, with +NAME+, +GROUP+, +WEIGHT+ and
  # +DESCRIPTION+, and +run(message, envelope)+ taking a Message and an
  # Envelope and returning nil or a Hit. A rule with several symbols lists
  # them in +SYMBOLS+, name to weight and description, keeps +NAME+ for logs,
  # and may return a list. +GROUP+ is the group its symbols are capped in.
  # +ALL+ is the catalogue `/symbols` lists and `/check` runs.
  module Rules
    CONTENT = [ HttpToIp, ZeroWidthSpaceUrl, UrlHomographAttack, FromHomograph, UrlOnly, RedirectorUrlOnly, Phishing, HtmlMetaRefreshUrl, HtmlForm, MimeHtmlOnly, MimeBase64TextBogus, MimeBadExtension, MimeDoubleBadExtension, MimeArchiveInArchive ].freeze
    ALL = [
      Bounce, RcptBounceMoreOne, Trap,
      Rdns, HeloBadIp, HeloBareIp, HeloNotFqdn, HeloNotHostname, HostnameUnknown,
      MissingDate, MissingMid, MissingFrom, MissingTo, InvalidMsgid, MultipleFrom, MultipleUniqueHeaders,
      InvalidDate, DateInFuture, DateInPast, SubjAllCaps,
      *CONTENT,
      FuzzyMatch,
      Authentication,
      DnsLists,
      Bayes,
      Fasttext
    ].freeze

    # With a +config+, a rule whose symbols are settings lists them from its
    # +symbols(config)+, each with its own group or the rule's.
    def self.catalogue(rules = ALL, config: nil)
      rules.flat_map do |rule|
        symbols =
          if config && rule.respond_to?(:symbols) then rule.symbols(config)
          elsif rule.const_defined?(:SYMBOLS) then rule::SYMBOLS
          else { rule::NAME => [ rule::WEIGHT, rule::DESCRIPTION ] }
          end

        symbols.map { |name, (weight, description, group)| { name:, weight:, description:, group: group || rule::GROUP } }
      end
    end

    # +rules+ and what a scan fires around them.
    def self.scanned(rules = ALL)
      [ *rules, Limits, Reputation, Greylister, Scanner ]
    end

    # Every group the +groups+ setting may cap.
    def self.groups
      scanned.flat_map { it.const_defined?(:GROUPS) ? it::GROUPS : it::GROUP }.uniq
    end
  end
end
