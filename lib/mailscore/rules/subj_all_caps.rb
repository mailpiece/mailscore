module MailScore
  module Rules
    # A Subject with capital letters and no lower case or caseless ones,
    # after any Re: or Fwd:. It weighs in full from LENGTH characters, and
    # in proportion below that.
    class SubjAllCaps < Rule
      NAME = "SUBJECT_ALL_CAPS"
      WEIGHT = 3.0
      DESCRIPTION = "Subject is in capitals"

      LENGTH = 40
      REPLY = /\A(?:(?:Re|Fwd|Fw|Aw|Antwort|Sv):\s*)+(.+)\z/i

      def run(message, _envelope)
        subject = message.subject.to_s
        subject = subject[REPLY, 1] || subject

        if subject.match?(/\p{Lu}/) && !subject.match?(/[\p{Ll}\p{Lo}]/)
          Hit.new(name: NAME, weight: (WEIGHT * [ subject.length.fdiv(LENGTH), 1 ].min).round(2), detail: "#{subject.length} characters")
        end
      end
    end
  end
end
