module MailScore
  module Rules
    # The standard anti-spam test string, which a person sends to check a
    # filter end to end, anywhere in the subject, the headers or a text or
    # HTML part. It forces reject, whatever the score, unless scores
    # switches it off or reject is off.
    class TestString < Rule
      NAME = "SPAM_TEST_STRING"
      GROUP = "test"
      WEIGHT = 0.0
      DESCRIPTION = "Standard spam test string"

      STRING = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"

      def run(message, _envelope)
        if [ message.subject, message.headers, *message.content.text_parts.map(&:text) ].any? { it&.include?(STRING) }
          Hit.new(name: NAME, weight: WEIGHT, data: { action: "reject" })
        end
      end
    end
  end
end
