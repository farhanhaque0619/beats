import Foundation

/// Config documents in the shapes the ISPDB and real autoconfig servers serve.
enum ClientConfigFixtures {
    /// ISPDB entry for Gmail (abridged from autoconfig.thunderbird.net/v1.1/gmail.com).
    static let gmail = """
    <?xml version="1.0" encoding="UTF-8"?>
    <clientConfig version="1.1">
      <emailProvider id="googlemail.com">
        <domain>gmail.com</domain>
        <domain>googlemail.com</domain>
        <!-- MX, for Google Apps -->
        <domain>google.com</domain>
        <displayName>Google Mail</displayName>
        <displayShortName>GMail</displayShortName>
        <incomingServer type="imap">
          <hostname>imap.gmail.com</hostname>
          <port>993</port>
          <socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username>
          <authentication>OAuth2</authentication>
          <authentication>password-cleartext</authentication>
        </incomingServer>
        <incomingServer type="pop3">
          <hostname>pop.gmail.com</hostname>
          <port>995</port>
          <socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username>
          <authentication>OAuth2</authentication>
          <authentication>password-cleartext</authentication>
          <pop3>
            <leaveMessagesOnServer>true</leaveMessagesOnServer>
          </pop3>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>smtp.gmail.com</hostname>
          <port>465</port>
          <socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username>
          <authentication>OAuth2</authentication>
          <authentication>password-cleartext</authentication>
        </outgoingServer>
        <documentation url="http://mail.google.com/support/bin/answer.py?answer=13273">
          <descr>How to enable IMAP/POP3 in GMail</descr>
        </documentation>
      </emailProvider>
      <oAuth2>
        <issuer>accounts.google.com</issuer>
        <scope>https://mail.google.com/ https://www.googleapis.com/auth/carddav https://www.googleapis.com/auth/calendar</scope>
        <authURL>https://accounts.google.com/o/oauth2/auth</authURL>
        <tokenURL>https://www.googleapis.com/oauth2/v3/token</tokenURL>
      </oAuth2>
    </clientConfig>
    """

    /// GMX: STARTTLS listed before SSL for SMTP, plus a plain-text POP3 server.
    static let gmx = """
    <?xml version="1.0"?>
    <clientConfig version="1.1">
        <emailProvider id="gmx.net">
          <domain>gmx.net</domain>
          <domain>gmx.de</domain>
          <displayName>GMX Freemail</displayName>
          <displayShortName>GMX</displayShortName>
          <incomingServer type="imap">
             <hostname>imap.gmx.net</hostname>
             <port>143</port>
             <socketType>STARTTLS</socketType>
             <username>%EMAILADDRESS%</username>
             <authentication>password-cleartext</authentication>
          </incomingServer>
          <incomingServer type="imap">
             <hostname>imap.gmx.net</hostname>
             <port>993</port>
             <socketType>SSL</socketType>
             <username>%EMAILADDRESS%</username>
             <authentication>password-cleartext</authentication>
          </incomingServer>
          <incomingServer type="pop3">
             <hostname>pop.gmx.net</hostname>
             <port>110</port>
             <socketType>plain</socketType>
             <username>%EMAILADDRESS%</username>
             <authentication>password-cleartext</authentication>
          </incomingServer>
          <outgoingServer type="smtp">
             <hostname>mail.gmx.net</hostname>
             <port>587</port>
             <socketType>STARTTLS</socketType>
             <username>%EMAILADDRESS%</username>
             <authentication>password-cleartext</authentication>
          </outgoingServer>
          <outgoingServer type="smtp">
             <hostname>mail.gmx.net</hostname>
             <port>465</port>
             <socketType>SSL</socketType>
             <username>%EMAILADDRESS%</username>
             <authentication>password-cleartext</authentication>
          </outgoingServer>
          <documentation url="https://hilfe.gmx.net/pop-imap/index.html">
            <descr lang="de">Allgemeine Beschreibung der Einstellungen</descr>
            <descr lang="en">Generic settings page</descr>
          </documentation>
        </emailProvider>
    </clientConfig>
    """

    /// cPanel-generated autoconfig (what `autoconfig.<domain>` serves on most shared hosting).
    static let cpanel = """
    <?xml version="1.0" encoding="UTF-8"?>

    <clientConfig version="1.1">
        <emailProvider id="example-hosting.com">
            <domain>example-hosting.com</domain>
            <displayName>example-hosting.com Email</displayName>
            <displayShortName>example-hosting.com</displayShortName>

            <incomingServer type="imap">
                <hostname>mail.%EMAILDOMAIN%</hostname>
                <port>993</port>
                <socketType>SSL</socketType>
                <authentication>password-cleartext</authentication>
                <username>%EMAILADDRESS%</username>
            </incomingServer>

            <incomingServer type="pop3">
                <hostname>mail.%EMAILDOMAIN%</hostname>
                <port>995</port>
                <socketType>SSL</socketType>
                <authentication>password-cleartext</authentication>
                <username>%EMAILADDRESS%</username>
            </incomingServer>

            <outgoingServer type="smtp">
                <hostname>mail.%EMAILDOMAIN%</hostname>
                <port>465</port>
                <socketType>SSL</socketType>
                <authentication>password-cleartext</authentication>
                <username>%EMAILADDRESS%</username>
            </outgoingServer>

            <documentation url="http://example-hosting.com/">
                <descr lang="en">Generic settings page</descr>
            </documentation>
        </emailProvider>
    </clientConfig>
    """

    /// Comcast (Xfinity): SMTP only on 587 with STARTTLS; local-part user names.
    static let comcast = """
    <?xml version="1.0" encoding="UTF-8"?>
    <clientConfig version="1.1">
      <emailProvider id="comcast.net">
        <domain>comcast.net</domain>
        <displayName>Comcast</displayName>
        <incomingServer type="imap">
          <hostname>imap.comcast.net</hostname>
          <port>993</port>
          <socketType>SSL</socketType>
          <username>%EMAILLOCALPART%</username>
          <authentication>password-cleartext</authentication>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>smtp.comcast.net</hostname>
          <port>587</port>
          <socketType>STARTTLS</socketType>
          <username>%EMAILLOCALPART%</username>
          <authentication>password-cleartext</authentication>
        </outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    /// Only plain-text servers: must be rejected.
    static let plainOnly = """
    <clientConfig version="1.1">
      <emailProvider id="oldisp.example">
        <incomingServer type="imap">
          <hostname>mail.oldisp.example</hostname><port>143</port><socketType>plain</socketType>
          <username>%EMAILADDRESS%</username><authentication>password-cleartext</authentication>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>mail.oldisp.example</hostname><port>25</port><socketType>plain</socketType>
          <authentication>password-cleartext</authentication>
        </outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    /// Exchange/EWS and JMAP entries alongside IMAP (Fastmail- and Office-style documents).
    static let mixedProtocols = """
    <?xml version="1.0" encoding="UTF-8"?>
    <clientConfig version="1.1">
      <emailProvider id="corp.example">
        <domain>corp.example</domain>
        <displayName>Corp Mail</displayName>
        <incomingServer type="exchange">
          <hostname>outlook.office365.com</hostname>
          <port>443</port>
          <username>%EMAILADDRESS%</username>
          <socketType>SSL</socketType>
          <authentication>OAuth2</authentication>
          <owaURL>https://outlook.office365.com/owa/</owaURL>
          <ewsURL>https://outlook.office365.com/ews/exchange.asmx</ewsURL>
        </incomingServer>
        <incomingServer type="jmap">
          <hostname>api.corp.example</hostname>
          <port>443</port>
          <socketType>SSL</socketType>
        </incomingServer>
        <incomingServer type="IMAP">
          <hostname>IMAP.Corp.Example</hostname>
          <port>993</port>
          <socketType>SSL</socketType>
          <username>%EMAILLOCALPART%@corp.example</username>
          <authentication>GSSAPI</authentication>
        </incomingServer>
        <incomingServer type="imap">
          <hostname>imap2.corp.example</hostname>
          <port>993</port>
          <socketType>SSL</socketType>
          <username>%EMAILADDRESS%</username>
          <authentication>password-cleartext</authentication>
        </incomingServer>
        <outgoingServer type="smtp">
          <hostname>smtp.corp.example</hostname>
          <port>587</port>
          <socketType>TLS</socketType>
          <authentication>password-encrypted</authentication>
        </outgoingServer>
      </emailProvider>
    </clientConfig>
    """

    /// Two providers; only the first counts.
    static let twoProviders = """
    <clientConfig version="1.1">
      <emailProvider id="first.example">
        <displayName>First</displayName>
        <incomingServer type="imap"><hostname>imap.first.example</hostname><port>993</port><socketType>SSL</socketType></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.first.example</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
      </emailProvider>
      <emailProvider id="second.example">
        <displayName>Second</displayName>
        <incomingServer type="imap"><hostname>imap.second.example</hostname><port>993</port><socketType>SSL</socketType></incomingServer>
        <outgoingServer type="smtp"><hostname>smtp.second.example</hostname><port>465</port><socketType>SSL</socketType></outgoingServer>
      </emailProvider>
    </clientConfig>
    """
}
