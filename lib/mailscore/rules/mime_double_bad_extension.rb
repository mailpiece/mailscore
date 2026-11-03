module MailScore
  module Rules
    # A risky file dressed as a document, such as invoice.pdf.exe.
    class MimeDoubleBadExtension < Rule
      NAME = "ATTACHMENT_DISGUISED_EXTENSION"
      WEIGHT = 3.0
      DESCRIPTION = "Attachment with a risky extension behind a harmless one"

      DECOYS = %w[ avi doc docx gif jpeg jpg mov mp3 mp4 odt pdf png ppt pptx rtf txt xls xlsx zip ].to_set.freeze

      def run(message, _envelope)
        message.content.attachments.each do |attachment|
          name = [ attachment.name, *attachment.archive_names ].find { double?(it) }
          return Hit.new(name: NAME, weight: WEIGHT, detail: name) if name
        end

        nil
      end

      private
        def double?(name)
          stem, extension = Content.split_name(name)
          MimeBadExtension::EXTENSIONS.include?(extension) && DECOYS.include?(Content.extension(stem))
        end
    end
  end
end
