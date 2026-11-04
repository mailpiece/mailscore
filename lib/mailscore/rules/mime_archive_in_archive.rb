module MailScore
  module Rules
    # A zip holding another archive, a way to hide its payload from scanners.
    class MimeArchiveInArchive < Rule
      NAME = "ATTACHMENT_NESTED_ARCHIVE"
      GROUP = "mime_types"
      WEIGHT = 5.0
      DESCRIPTION = "Archive inside a zip attachment"

      ARCHIVES = %w[ 7z ace alz arj bz2 cab egg lz rar xz zip ].to_set.freeze

      def run(message, _envelope)
        message.content.attachments.each do |attachment|
          name = attachment.archive_names.find { ARCHIVES.include?(Content.extension(it)) }
          return Hit.new(name: NAME, weight: WEIGHT, detail: "#{attachment.name}: #{name}") if name
        end

        nil
      end
    end
  end
end
