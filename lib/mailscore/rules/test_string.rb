module MailScore
  module Rules
    # The standard anti-spam test string in a text part of at most 8 KB,
    # which a person sends to check a filter end to end. It forces reject,
    # whatever the score, unless scores switches it off or reject is off.
    class TestString < Rule
      NAME = "SPAM_TEST_STRING"
      GROUP = "test"
      WEIGHT = 0.0
      DESCRIPTION = "Standard spam test string"

      STRING = "XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X"
      PART_CAP = 8 * 1024

      def run(message, _envelope)
        Hit.new(name: NAME, weight: WEIGHT, data: { action: "reject" }) if message.content.text_parts.any? { it.text.bytesize <= PART_CAP && it.text.include?(STRING) }
      end
    end
  end
end
