module MailScore
  module Rules
    # An attachment, or a file named inside a zip, that runs code when opened.
    class MimeBadExtension < Rule
      NAME = "ATTACHMENT_RISKY_EXTENSION"
      GROUP = "mime_types"
      WEIGHT = 2.0
      DESCRIPTION = "Risky attachment type"

      EXTENSIONS = %w[
        ace ade adp app arj asp asx bas bat cab chm cmd cnt com cpl csh diagcab docm exe fxp gadget grp hlp hpj hta htm
        html inf ins isp iso its jar jnlp js jse ksh lib lnk mad maf mag mam maq mar mas mat mau mav maw mcf mda mdb mde
        mdt mdw mdz msc msh msh1 msh1xml msh2 msh2xml mshxml msi msp mst msu nsh ops osd pcd pif pl plg pptm prf prg
        printerexport ps1 ps1xml ps2 ps2xml psc1 psc2 psd1 psdm1 pst reg scf scr sct sfx shb shs shtm shtml sys theme url
        vb vbe vbp vbs vsmacros vss vst vsw vxd webpnp website ws wsc wsh xbap xll xlsm xnk
      ].to_set.freeze

      def run(message, _envelope)
        message.content.attachments.each do |attachment|
          name = [ attachment.name, *attachment.archive_names ].find { EXTENSIONS.include?(Content.extension(it)) }
          return Hit.new(name: NAME, weight: WEIGHT, detail: name) if name
        end

        nil
      end
    end
  end
end
