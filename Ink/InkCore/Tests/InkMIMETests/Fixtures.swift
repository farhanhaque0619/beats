import Foundation

/// Real-world shaped raw messages. Written with LF in source; `Raw.data` turns them into CRLF.
/// Addresses, names and companies are fictional.
enum Fixtures {
    // MARK: Gmail

    /// Gmail web: multipart/alternative, quoted-printable UTF-8, encoded-word subject.
    static let gmailAlternative = #"""
    Delivered-To: alex@ink.example
    Received: by 2002:a05:7010:4b1a:b0:3e6:9f1c:1234 with SMTP id ab26csp123456mdb;
            Tue, 20 Oct 2026 02:15:42 -0700 (PDT)
    X-Received: by 2002:a17:907:7da4:b0:a8d:5d0d:9a1 with SMTP id oz36-20020a1709077da400b00a8d5d0d09a1mr123456ejc.12.1792487742123;
            Tue, 20 Oct 2026 02:15:42 -0700 (PDT)
    ARC-Seal: i=1; a=rsa-sha256; t=1792487742; cv=none;
            d=google.com; s=arc-20240605;
            b=Xy0b1c2d3e4f5g6h7i8j9k0l1m2n3o4p5q6r7s8t9u0v1w2x3y4z5A6B7C8D9E0F1G2H3I4J5K6L7M8N9O0
    Return-Path: <ada.lovelace@gmail.com>
    Received: from mail-sor-f41.google.com (mail-sor-f41.google.com. [209.85.220.41])
            by mx.google.com with SMTPS id 5b1f17b1804b1-4317d8a1234sor123456f9.4.2026.10.20.02.15.42
            for <alex@ink.example>
            (Google Transport Security);
            Tue, 20 Oct 2026 02:15:42 -0700 (PDT)
    DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed;
            d=gmail.com; s=20230601; t=1792487742; x=1793092542; darn=ink.example;
            h=to:subject:message-id:date:from:mime-version:from:to:cc:subject
             :date:message-id:reply-to;
            bh=47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=;
            b=k3Lq9Xz0Ab1Cd2Ef3Gh4Ij5Kl6Mn7Op8Qr9St0Uv1Wx2Yz3Ab4Cd5Ef6Gh7Ij8Kl9Mn0Op1Qr2St3Uv4Wx5Yz6
    MIME-Version: 1.0
    From: Ada Lovelace <ada.lovelace@gmail.com>
    Date: Tue, 20 Oct 2026 11:15:30 +0200
    Message-ID: <CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com>
    Subject: =?UTF-8?Q?Caf=C3=A9_tomorrow=3F?=
    To: Alex Rivera <alex@ink.example>
    Content-Type: multipart/alternative; boundary="000000000000a1b2c3062534f9e1"

    --000000000000a1b2c3062534f9e1
    Content-Type: text/plain; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    Hi Alex,

    Are you free for a coffee at Caf=C3=A9 Central tomorrow around 10? I'd love =
    to hear how the launch went.

    Cheers,
    Ada

    --000000000000a1b2c3062534f9e1
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    <div dir=3D"ltr">Hi Alex,<div><br></div><div>Are you free for a coffee at C=
    af=C3=A9 Central tomorrow around 10? I&#39;d love to hear how the launch we=
    nt.</div><div><br></div><div>Cheers,</div><div>Ada</div></div>

    --000000000000a1b2c3062534f9e1--
    """#

    /// Gmail reply: attribution wrapped over two lines in the plain part, div.gmail_quote in HTML.
    static let gmailReply = #"""
    MIME-Version: 1.0
    References: <CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com>
    In-Reply-To: <CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com>
    From: Alex Rivera <alex@ink.example>
    Date: Tue, 20 Oct 2026 11:32:04 +0200
    Message-ID: <CAH5r7=kQ2xYz8Lm4Np6Rs0Tv3Wx1Ab9Cd_e@mail.gmail.com>
    Subject: =?UTF-8?Q?Re=3A_Caf=C3=A9_tomorrow=3F?=
    To: Ada Lovelace <ada.lovelace@gmail.com>
    Content-Type: multipart/alternative; boundary="000000000000c4d5e6062534fa77"

    --000000000000c4d5e6062534fa77
    Content-Type: text/plain; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    Sounds great, see you at 10!

    On Tue, Oct 20, 2026 at 11:15=E2=80=AFAM Ada Lovelace <ada.lovelace@gmail.com>
    wrote:

    > Hi Alex,
    >
    > Are you free for a coffee at Caf=C3=A9 Central tomorrow around 10? I'd lo=
    ve
    > to hear how the launch went.
    >
    > Cheers,
    > Ada
    >

    --000000000000c4d5e6062534fa77
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    <div dir=3D"ltr">Sounds great, see you at 10!</div><br><div class=3D"gmail_=
    quote gmail_quote_container"><div dir=3D"ltr" class=3D"gmail_attr">On Tue, =
    Oct 20, 2026 at 11:15=E2=80=AFAM Ada Lovelace &lt;<a href=3D"mailto:ada.lov=
    elace@gmail.com">ada.lovelace@gmail.com</a>&gt; wrote:<br></div><blockquote=
     class=3D"gmail_quote" style=3D"margin:0px 0px 0px 0.8ex;border-left:1px so=
    lid rgb(204,204,204);padding-left:1ex"><div dir=3D"ltr">Hi Alex,<div><br></=
    div><div>Are you free for a coffee at Caf=C3=A9 Central tomorrow around 10?=
     I&#39;d love to hear how the launch went.</div><div><br></div><div>Cheers,=
    </div><div>Ada</div></div>
    </blockquote></div>

    --000000000000c4d5e6062534fa77--
    """#

    /// Gmail with an inline image: multipart/related around multipart/alternative.
    static let gmailInlineImage = #"""
    MIME-Version: 1.0
    From: Ada Lovelace <ada.lovelace@gmail.com>
    Date: Mon, 19 Oct 2026 16:04:11 +0200
    Message-ID: <CAJ8x=Qn1Pq2Rs3Tu4Vw5Xy6Za7Bc8De9Fg@mail.gmail.com>
    Subject: Whiteboard from today
    To: alex@ink.example
    Content-Type: multipart/related; boundary="000000000000e7f8a9062534fb10"

    --000000000000e7f8a9062534fb10
    Content-Type: multipart/alternative; boundary="000000000000e7f8a8062534fb0f"

    --000000000000e7f8a8062534fb0f
    Content-Type: text/plain; charset="UTF-8"

    Here's the whiteboard:

    [image: whiteboard.png]

    Ada

    --000000000000e7f8a8062534fb0f
    Content-Type: text/html; charset="UTF-8"

    <div dir="ltr">Here's the whiteboard:<div><br></div><div><img src="cid:ii_m2abc1230" alt="whiteboard.png" width="542" height="301"><br></div><div><br></div><div>Ada</div></div>

    --000000000000e7f8a8062534fb0f--
    --000000000000e7f8a9062534fb10
    Content-Type: image/png; name="whiteboard.png"
    Content-Disposition: inline; filename="whiteboard.png"
    Content-Transfer-Encoding: base64
    Content-ID: <ii_m2abc1230>
    X-Attachment-Id: ii_m2abc1230

    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9
    awAAAABJRU5ErkJggg==
    --000000000000e7f8a9062534fb10--
    """#

    // MARK: Apple Mail / iCloud

    /// Apple Mail with an inline image: alternative(plain, related(html, image)).
    static let appleMailInlineImage = #"""
    Return-Path: <grace@icloud.com>
    From: Grace Hopper <grace@icloud.com>
    Content-Type: multipart/alternative;
    	boundary="Apple-Mail=_5F3A2B1C-8D4E-4F6A-9B7C-1D2E3F4A5B6C"
    Mime-Version: 1.0 (Mac OS X Mail 16.0 \(3826.200.121\))
    Subject: Photo from the offsite
    Date: Mon, 19 Oct 2026 18:42:07 -0700
    Message-Id: <8F2A1B3C-4D5E-6F7A-8B9C-0D1E2F3A4B5C@icloud.com>
    To: Alex Rivera <alex@ink.example>
    X-Mailer: Apple Mail (2.3826.200.121)


    --Apple-Mail=_5F3A2B1C-8D4E-4F6A-9B7C-1D2E3F4A5B6C
    Content-Transfer-Encoding: 7bit
    Content-Type: text/plain;
    	charset=us-ascii

    Here's the team photo!



    Grace

    --Apple-Mail=_5F3A2B1C-8D4E-4F6A-9B7C-1D2E3F4A5B6C
    Content-Type: multipart/related;
    	type="text/html";
    	boundary="Apple-Mail=_A1B2C3D4-0000-4444-8888-CCCCDDDDEEEE"


    --Apple-Mail=_A1B2C3D4-0000-4444-8888-CCCCDDDDEEEE
    Content-Transfer-Encoding: 7bit
    Content-Type: text/html;
    	charset=us-ascii

    <html><head><meta http-equiv="content-type" content="text/html; charset=us-ascii"></head><body style="overflow-wrap: break-word; -webkit-nbsp-mode: space; line-break: after-white-space;">Here's the team photo!<div><br></div><div><img apple-inline="yes" id="7A1B2C3D-1111-2222-3333-444455556666" src="cid:A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D" alt="team.png"></div><div><br></div><div>Grace</div></body></html>
    --Apple-Mail=_A1B2C3D4-0000-4444-8888-CCCCDDDDEEEE
    Content-Disposition: inline;
    	filename=team.png
    Content-Type: image/png;
    	x-unix-mode=0644;
    	name="team.png"
    Content-Transfer-Encoding: base64
    Content-Id: <A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D>

    iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
    --Apple-Mail=_A1B2C3D4-0000-4444-8888-CCCCDDDDEEEE--

    --Apple-Mail=_5F3A2B1C-8D4E-4F6A-9B7C-1D2E3F4A5B6C--
    """#

    /// iPhone reply from iCloud: plain text only, quoted original, "Sent from my iPhone".
    static let iCloudPlainReply = #"""
    From: Grace Hopper <grace@icloud.com>
    Content-Type: text/plain;
    	charset=utf-8
    Content-Transfer-Encoding: quoted-printable
    Mime-Version: 1.0 (1.0)
    Date: Tue, 20 Oct 2026 07:58:31 -0700
    Subject: Re: Photo from the offsite
    Message-Id: <C0FFEE12-3456-7890-ABCD-EF1234567890@icloud.com>
    References: <8F2A1B3C-4D5E-6F7A-8B9C-0D1E2F3A4B5C@icloud.com> <CAH5r7=abc@mail.gmail.com>
    In-Reply-To: <CAH5r7=abc@mail.gmail.com>
    To: Alex Rivera <alex@ink.example>
    X-Mailer: iPhone Mail (22A3354)

    Yes, Thursday works =F0=9F=91=8D

    Sent from my iPhone

    > On Oct 20, 2026, at 7:40=E2=80=AFAM, Alex Rivera <alex@ink.example> wrote:
    >=20
    > =EF=BB=BFLove it! Can we print one for the office?
    """#

    // MARK: Outlook

    /// Outlook desktop: windows-1252 QP, MsoNormal HTML with the header-rule quote, winmail.dat.
    static let outlookWinmail = #"""
    Received: from DB9PR04MB8106.eurprd04.prod.outlook.com (2603:10a6:10:2c3::11)
     by AM0PR04MB6849.eurprd04.prod.outlook.com with HTTPS; Tue, 20 Oct 2026
     08:01:12 +0000
    From: "Smith, John" <John.Smith@contoso.example>
    To: Alex Rivera <alex@ink.example>, "Doe, Jane" <jane.doe@contoso.example>
    CC: Team Leads <leads@contoso.example>
    Subject: RE: Q3 budget review
    Thread-Topic: Q3 budget review
    Thread-Index: AQHZ8kL2abc123def456ghi789jkl0mnoAABCDEF
    Date: Tue, 20 Oct 2026 08:01:11 +0000
    Message-ID: <DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2@DB9PR04MB8106.eurprd04.prod.outlook.com>
    References: <CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com>
     <AM0PR04MB68491A2B3C4D5E6F7A8B9C0D1E2F3A4B5@AM0PR04MB6849.eurprd04.prod.outlook.com>
    In-Reply-To: <AM0PR04MB68491A2B3C4D5E6F7A8B9C0D1E2F3A4B5@AM0PR04MB6849.eurprd04.prod.outlook.com>
    Accept-Language: en-US, de-DE
    Content-Language: en-US
    X-MS-Has-Attach: yes
    X-MS-TNEF-Correlator: <DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2@DB9PR04MB8106.eurprd04.prod.outlook.com>
    Content-Type: multipart/mixed;
    	boundary="_002_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_"
    MIME-Version: 1.0

    --_002_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_
    Content-Type: multipart/alternative;
    	boundary="_000_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_"

    --_000_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_
    Content-Type: text/plain; charset="Windows-1252"
    Content-Transfer-Encoding: quoted-printable

    Hi Alex,

    The revised numbers are attached =96 let=92s discuss on Thursday.

    Thanks,
    John

    From: Alex Rivera <alex@ink.example>
    Sent: Monday, October 19, 2026 5:12 PM
    To: Smith, John <John.Smith@contoso.example>
    Subject: Q3 budget review

    Hi John, could you send the latest Q3 figures?

    --_000_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_
    Content-Type: text/html; charset="Windows-1252"
    Content-Transfer-Encoding: quoted-printable

    <html xmlns:v=3D"urn:schemas-microsoft-com:vml" xmlns:o=3D"urn:schemas-micr=
    osoft-com:office:office" xmlns:w=3D"urn:schemas-microsoft-com:office:word" =
    xmlns:m=3D"http://schemas.microsoft.com/office/2004/12/omml" xmlns=3D"http:=
    //www.w3.org/TR/REC-html40">
    <head>
    <meta http-equiv=3D"Content-Type" content=3D"text/html; charset=3DWindows-1=
    252">
    <meta name=3D"Generator" content=3D"Microsoft Word 15 (filtered medium)">
    <style><!--
    /* Font Definitions */
    @font-face
    	{font-family:"Cambria Math";
    	panose-1:2 4 5 3 5 4 6 3 2 4;}
    p.MsoNormal, li.MsoNormal, div.MsoNormal
    	{margin:0in;
    	font-size:11.0pt;
    	font-family:"Calibri",sans-serif;}
    a:link, span.MsoHyperlink
    	{mso-style-priority:99;
    	color:#0563C1;
    	text-decoration:underline;}
    --></style><!--[if gte mso 9]><xml>
    <o:shapedefaults v:ext=3D"edit" spidmax=3D"1026" />
    </xml><![endif]-->
    </head>
    <body lang=3D"EN-US" link=3D"#0563C1" vlink=3D"#954F72" style=3D"word-wrap:=
    break-word">
    <div class=3D"WordSection1">
    <p class=3D"MsoNormal">Hi Alex,<o:p></o:p></p>
    <p class=3D"MsoNormal"><o:p>&nbsp;</o:p></p>
    <p class=3D"MsoNormal">The revised numbers are attached =96 let=92s discuss=
     on Thursday.<o:p></o:p></p>
    <p class=3D"MsoNormal"><o:p>&nbsp;</o:p></p>
    <p class=3D"MsoNormal">Thanks,<o:p></o:p></p>
    <p class=3D"MsoNormal">John<o:p></o:p></p>
    <p class=3D"MsoNormal"><o:p>&nbsp;</o:p></p>
    <div style=3D"border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0in =
    0in 0in">
    <p class=3D"MsoNormal"><b>From:</b> Alex Rivera &lt;alex@ink.example&gt; <b=
    r>
    <b>Sent:</b> Monday, October 19, 2026 5:12 PM<br>
    <b>To:</b> Smith, John &lt;John.Smith@contoso.example&gt;<br>
    <b>Subject:</b> Q3 budget review<o:p></o:p></p>
    </div>
    <p class=3D"MsoNormal"><o:p>&nbsp;</o:p></p>
    <p class=3D"MsoNormal">Hi John, could you send the latest Q3 figures?<o:p><=
    /o:p></p>
    </div>
    </body>
    </html>

    --_000_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_--

    --_002_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_
    Content-Type: application/ms-tnef; name="winmail.dat"
    Content-Description: winmail.dat
    Content-Disposition: attachment; filename="winmail.dat"; size=34;
    	creation-date="Tue, 20 Oct 2026 08:01:10 GMT";
    	modification-date="Tue, 20 Oct 2026 08:01:10 GMT"
    Content-Transfer-Encoding: base64

    eJ8+IgEAAQaQCAAEAAAAAAABAAEAAQeQBgAIAAAA5AQAAA==

    --_002_DB9PR04MB81069F2E7A1B0C3D4E5F6A7B8C9D0E1F2DB9PR04MB8106eurp_--
    """#

    /// Outlook on the web reply: #appendonsend / #divRplyFwdMsg markers.
    static let outlookWebReply = #"""
    From: Jane Doe <jane.doe@outlook.example>
    To: Alex Rivera <alex@ink.example>
    Subject: Re: Lunch?
    Date: Tue, 20 Oct 2026 12:05:44 +0000
    Message-ID: <PAXP193MB12345E6F7A8B9C0D1E2F3A4B5C6D7E8F9A@PAXP193MB1234.EURP193.PROD.OUTLOOK.COM>
    Content-Type: text/html; charset="iso-8859-1"
    Content-Transfer-Encoding: quoted-printable
    MIME-Version: 1.0

    <html>
    <head>
    <meta http-equiv=3D"Content-Type" content=3D"text/html; charset=3Diso-8859-=
    1">
    <style type=3D"text/css" style=3D"display:none;"> P {margin-top:0;margin-bo=
    ttom:0;} </style>
    </head>
    <body dir=3D"ltr">
    <div class=3D"elementToProof" style=3D"font-family: Aptos, Aptos_EmbeddedFo=
    nt, Aptos_MSFontService, Calibri, Helvetica, sans-serif; font-size: 12pt; c=
    olor: rgb(0, 0, 0);">
    Sure &#8211; let's do Caf=E9 Nero at 1.</div>
    <div id=3D"appendonsend"></div>
    <hr style=3D"display:inline-block;width:98%" tabindex=3D"-1">
    <div id=3D"divRplyFwdMsg" dir=3D"ltr"><font face=3D"Calibri, sans-serif" st=
    yle=3D"font-size:11pt" color=3D"#000000"><b>From:</b> Alex Rivera &lt;alex@=
    ink.example&gt;<br>
    <b>Sent:</b> Tuesday, October 20, 2026 1:58 PM<br>
    <b>To:</b> Jane Doe &lt;jane.doe@outlook.example&gt;<br>
    <b>Subject:</b> Lunch?</font>
    <div>&nbsp;</div>
    </div>
    <div>Lunch today?</div>
    </body>
    </html>
    """#

    // MARK: Yahoo, Fastmail, Thunderbird, Proton

    /// Yahoo Mail: alternative, yahoo_quoted div.
    static let yahooReply = #"""
    Date: Tue, 20 Oct 2026 14:22:10 +0000 (UTC)
    From: Kim Lee <kim.lee@yahoo.example>
    Reply-To: Kim Lee <kim.lee@yahoo.example>
    To: Alex Rivera <alex@ink.example>
    Message-ID: <1234567890.1234567.1792506130123@mail.yahoo.example>
    In-Reply-To: <CAH5r7=kQ2xYz8Lm4Np6Rs0Tv3Wx1Ab9Cd_e@mail.gmail.com>
    References: <CAH5r7=kQ2xYz8Lm4Np6Rs0Tv3Wx1Ab9Cd_e@mail.gmail.com>
    Subject: Re: Weekend plans
    MIME-Version: 1.0
    Content-Type: multipart/alternative;
    	boundary="----=_Part_1234567_890123456.1792506130120"
    X-Mailer: WebService/1.1.22806 YMailNorrin

    ------=_Part_1234567_890123456.1792506130120
    Content-Type: text/plain; charset=UTF-8
    Content-Transfer-Encoding: 7bit

     Hiking sounds perfect.
        On Tuesday, October 20, 2026 at 01:10:22 PM UTC, Alex Rivera <alex@ink.example> wrote:

     Hiking on Saturday?
    ------=_Part_1234567_890123456.1792506130120
    Content-Type: text/html; charset=UTF-8
    Content-Transfer-Encoding: 7bit

    <html><head></head><body><div class="ydp1a2b3c4dyahoo-style-wrap" style="font-family:Helvetica Neue, Helvetica, Arial, sans-serif;font-size:13px;"><div dir="ltr" data-setdir="false">Hiking sounds perfect.</div></div><div id="yahoo_quoted_9876543210" class="yahoo_quoted">
                <div style="font-family:'Helvetica Neue', Helvetica, Arial, sans-serif;font-size:13px;color:#26282a;">
                    <div>
                        On Tuesday, October 20, 2026 at 01:10:22 PM UTC, Alex Rivera &lt;alex@ink.example&gt; wrote:
                    </div>
                    <div><br></div>
                    <div><br></div>
                    <div><div dir="ltr">Hiking on Saturday?</div></div>
                </div>
            </div></body></html>
    ------=_Part_1234567_890123456.1792506130120--
    """#

    /// Fastmail: plain text with quoted-printable soft breaks, lowercase hex and an encoded trailing space.
    static let fastmailQP = #"""
    Return-Path: <sam@fastmail.example>
    Received: from compute3.internal (compute3.nyi.internal [10.202.2.43])
    	by mailout.nyi.internal (Postfix) with ESMTP id 4B1C25C0123
    	for <alex@ink.example>; Tue, 20 Oct 2026 09:00:01 -0400 (EDT)
    MIME-Version: 1.0
    Message-Id: <4f2a9c1e-7b3d-4e8f-a1b2-c3d4e5f6a7b8@app.fastmail.example>
    Date: Tue, 20 Oct 2026 09:00:00 -0400
    From: "Sam Okafor" <sam@fastmail.example>
    To: "Alex Rivera" <alex@ink.example>
    Subject: Notes from the retro
    Content-Type: text/plain;charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    This line is long enough that it needs a soft line break somewhere in th=
    e middle, and it also has an =c3=a9 encoded with lowercase hex.=20
    Trailing space above was encoded.
    Soft break with trailing whitespace after the equals sign:=\#u{20}\#u{20}\#u{09}
    still the same line.
    """#

    /// Thunderbird: format=flowed with quoting, a signature and a forwarded message attached as .eml.
    static let thunderbirdForwardAttachment = #"""
    Message-ID: <2b6d7c1e-9f0a-4b3c-8d2e-1f0a9b8c7d6e@thunderbird.example>
    Date: Tue, 20 Oct 2026 10:12:45 +0200
    MIME-Version: 1.0
    User-Agent: Mozilla Thunderbird
    Content-Language: en-US
    To: Alex Rivera <alex@ink.example>
    From: Linus Berg <linus@thunderbird.example>
    Subject: Fwd: Lunch on Friday
    Content-Type: multipart/mixed; boundary="------------0aB1cD2eF3gH4iJ5kL6mN7oP"

    This is a multi-part message in MIME format.
    --------------0aB1cD2eF3gH4iJ5kL6mN7oP
    Content-Type: text/plain; charset=UTF-8; format=flowed
    Content-Transfer-Encoding: 7bit

    FYI, see the message below. This paragraph is long enough that Thunderbird\#u{20}
    wrapped it with a trailing space, so it should come back as one line.

    --\#u{20}
    Linus

    --------------0aB1cD2eF3gH4iJ5kL6mN7oP
    Content-Type: message/rfc822; name="Lunch on Friday.eml"
    Content-Disposition: attachment; filename="Lunch on Friday.eml"

    Return-Path: <maria@example.org>
    From: Maria Garcia <maria@example.org>
    To: Linus Berg <linus@thunderbird.example>
    Subject: Lunch on Friday
    Date: Mon, 19 Oct 2026 15:00:00 +0200
    Message-ID: <lunch-123@example.org>
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="inner-boundary-42"

    --inner-boundary-42
    Content-Type: text/plain; charset=utf-8

    Shall we try the new ramen place?
    --inner-boundary-42
    Content-Type: text/html; charset=utf-8

    <p>Shall we try the <b>new ramen place</b>?</p>
    --inner-boundary-42--

    --------------0aB1cD2eF3gH4iJ5kL6mN7oP--
    """#

    /// Apple Mail style inline forward: message/rfc822 without an attachment disposition.
    static let inlineForwardedMessage = #"""
    From: Grace Hopper <grace@icloud.com>
    To: Alex Rivera <alex@ink.example>
    Subject: Fwd: Your order has shipped
    Date: Tue, 20 Oct 2026 08:00:00 -0700
    Message-ID: <fwd-1@icloud.com>
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="Apple-Mail=_FWD"

    --Apple-Mail=_FWD
    Content-Type: text/plain; charset=us-ascii

    Look, it's on its way!

    --Apple-Mail=_FWD
    Content-Type: message/rfc822

    From: Shop <orders@shop.example>
    To: grace@icloud.com
    Subject: Your order has shipped
    Date: Mon, 19 Oct 2026 12:00:00 +0000
    Content-Type: multipart/mixed; boundary="shop-outer"

    --shop-outer
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: 8bit

    Your package is on the way. Tracking: 1Z999AA10123456784
    --shop-outer
    Content-Type: application/pdf; name="receipt.pdf"
    Content-Disposition: attachment; filename="receipt.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyA+PgplbmRvYmoKdHJhaWxlcgo8PCAv
    Um9vdCAxIDAgUiA+PgolJUVPRgo=
    --shop-outer--

    --Apple-Mail=_FWD--
    """#

    /// Proton Mail: protonmail_quote.
    static let protonReply = #"""
    Date: Tue, 20 Oct 2026 16:40:00 +0000
    To: Alex Rivera <alex@ink.example>
    From: Noor Haddad <noor@proton.example>
    Subject: Re: Keys
    Message-ID: <abcDEF123ghiJKL456=@proton.example>
    MIME-Version: 1.0
    Content-Type: text/html; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    <div style=3D"font-family: Arial, sans-serif; font-size: 14px;">I left them=
     at reception.</div><div class=3D"protonmail_signature_block"><div class=3D=
    "protonmail_signature_block-user">Noor</div></div><div class=3D"protonmail_=
    quote">
            On Tuesday, October 20th, 2026 at 18:30, Alex Rivera &lt;alex@ink.ex=
    ample&gt; wrote:<br><br>
            <blockquote class=3D"protonmail_quote" type=3D"cite">
                Where are the keys?
            </blockquote><br>
        </div>
    """#

    // MARK: Charsets

    /// Japanese: ISO-2022-JP headers and 7-bit body (escape sequences).
    static let iso2022jp = #"""
    Return-Path: <yamada@example.co.jp>
    From: =?ISO-2022-JP?B?GyRCOzNFRBsoQiAbJEJCQE86GyhC?= <yamada@example.co.jp>
    To: alex@ink.example
    Subject: =?ISO-2022-JP?B?GyRCMnE1RCRONUQ7dk8/JEskRCQkJEYbKEI=?=
    Date: Tue, 20 Oct 2026 18:30:00 +0900
    Message-ID: <20261020183000.ABCD1234@example.co.jp>
    MIME-Version: 1.0
    Content-Type: text/plain; charset=ISO-2022-JP
    Content-Transfer-Encoding: 7bit
    X-Mailer: Becky! ver. 2.81.04

    \#u{1B}$B;3EDMM\#u{1B}(B

    \#u{1B}$B$*@$OC$K$J$C$F$*$j$^$9!#\#u{1B}(B
    \#u{1B}$BL@F|$N2q5D$O8a8e\#u{1B}(B3\#u{1B}$B;~$+$i$G$9!#\#u{1B}(B
    \#u{1B}$B$h$m$7$/$*4j$$$$$?$7$^$9!#\#u{1B}(B
    """#

    /// Chinese: GB2312 headers (Foxmail) and a base64 GB2312 body.
    static let gb2312 = #"""
    From: "=?gb2312?B?1dTP/sP3?=" <zhaoxm@example.cn>
    To: "alex" <alex@ink.example>
    Subject: =?gb2312?B?udjT2s/C1ty1xLvh0umwssXF?=
    Date: Tue, 20 Oct 2026 17:05:12 +0800
    Message-ID: <202610201705120123456@example.cn>
    X-Mailer: Foxmail 7.2.25.375[cn]
    Mime-Version: 1.0
    Content-Type: text/plain;
    	charset="gb2312"
    Content-Transfer-Encoding: base64

    uPfOu82sysKjugoKz8LW3NK7yc/O58qutePU2sj9wqW74dLpytK/qrvho6zH69e8yrGyzrzToaMK
    CtC70LujoQo=
    """#

    /// A windows-1252 newsletter: designed HTML with a hidden preheader and a tracking pixel.
    static let windows1252Newsletter = #"""
    Return-Path: <bounce-123@email.northwind.example>
    From: "Northwind Outfitters" <news@email.northwind.example>
    Reply-To: Northwind Outfitters <reply@email.northwind.example>
    To: alex@ink.example
    Subject: =?windows-1252?Q?=93Fall_Sale=94_starts_now_=96_20%_off?=
    Date: Tue, 20 Oct 2026 13:00:05 +0000
    Message-ID: <0.1.2A.3B4.1DB2A3C4D5E6F70.0@email.northwind.example>
    List-Unsubscribe: <https://email.northwind.example/u?e=abc>, <mailto:unsub@email.northwind.example?subject=unsubscribe>
    List-Unsubscribe-Post: List-Unsubscribe=One-Click
    List-ID: Northwind News <news.northwind.example>
    Precedence: bulk
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="----=_NextPart_000_0012_01DB2A3C.4D5E6F70"

    This is a multi-part message in MIME format.

    ------=_NextPart_000_0012_01DB2A3C.4D5E6F70
    Content-Type: text/plain; charset="windows-1252"
    Content-Transfer-Encoding: quoted-printable

    View this email in your browser: https://email.northwind.example/v/abc

    =93Fall Sale=94 =96 save 20% on everything=85 only =8019!

    https://email.northwind.example/c/1

    ------=_NextPart_000_0012_01DB2A3C.4D5E6F70
    Content-Type: text/html; charset="windows-1252"
    Content-Transfer-Encoding: quoted-printable

    <!DOCTYPE html><html><head><title>Fall Sale</title><style>body{background-c=
    olor:#f4f1ea}</style></head><body bgcolor=3D"#f4f1ea">
    <span style=3D"display:none;max-height:0;overflow:hidden">Our biggest sale =
    of the season is here.</span>
    <table width=3D"600" align=3D"center" bgcolor=3D"#ffffff" cellpadding=3D"0"=
     cellspacing=3D"0">
    <tr><td><img src=3D"https://img.northwind.example/hero.jpg" width=3D"600" a=
    lt=3D"Fall Sale"></td></tr>
    <tr><td style=3D"padding:24px;font-family:Georgia,serif">=93Fall Sale=94 =
    =96 save 20% on everything=85 only =8019!</td></tr>
    <tr><td><a href=3D"https://email.northwind.example/c/1">Shop now &rarr;</a>=
    </td></tr>
    </table>
    <img src=3D"https://email.northwind.example/wf/open?upn=3Dabc" width=3D"1" =
    height=3D"1" alt=3D"" style=3D"display:block;height:1px!important;width:1px=
    !important">
    </body></html>

    ------=_NextPart_000_0012_01DB2A3C.4D5E6F70--
    """#

    // MARK: Structure edge cases

    /// base64 wrapped at odd lengths without padding.
    static let base64OddLines = #"""
    From: legacy@mailer.example
    To: alex@ink.example
    Subject: Odd base64
    Date: 20 Oct 2026 09:00 GMT
    MIME-Version: 1.0
    Content-Type: text/plain; charset=UTF-8
    Content-Transfer-Encoding: base64

    SGVsbG8gZnJvbSBhIG1h
    aWxlciB0aGF0IHdyYXBzIGJhc2U2NCBhdCBvZGQg
    bGVuZ3RocywgYW5kIGZvcmdldHMgdGhlIHBhZGRpbmch
    """#

    /// Truncated download: the final boundary never arrives.
    static let missingEndBoundary = #"""
    From: Ada Lovelace <ada.lovelace@gmail.com>
    To: alex@ink.example
    Subject: Report
    Date: Tue, 20 Oct 2026 11:00:00 +0200
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="XYZ"

    --XYZ
    Content-Type: text/plain; charset=utf-8

    Report attached.
    --XYZ
    Content-Type: application/pdf; name="report.pdf"
    Content-Disposition: attachment; filename="report.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyA+PgplbmRvYmoKdHJhaWxlcgo8PCAv
    Um9vdCAxIDAgUiA+PgolJUVPRgo=
    """#

    /// Google Calendar invite: text/calendar inside the alternative plus an invite.ics attachment.
    static let calendarInvite = #"""
    MIME-Version: 1.0
    Date: Tue, 20 Oct 2026 09:15:00 +0000
    Reply-To: Ada Lovelace <ada.lovelace@gmail.com>
    Sender: Google Calendar <calendar-notification@google.com>
    Message-ID: <calendar-7kukuqrfedlm2f9t2vr42q2g1c@google.com>
    Subject: Invitation: Design review @ Thu Oct 22, 2026 2pm - 3pm (CEST) (alex@ink.example)
    From: Ada Lovelace <ada.lovelace@gmail.com>
    To: alex@ink.example
    Content-Type: multipart/mixed; boundary="000000000000b2c3d4062534fa01"

    --000000000000b2c3d4062534fa01
    Content-Type: multipart/alternative; boundary="000000000000b2c3d3062534fa00"

    --000000000000b2c3d3062534fa00
    Content-Type: text/plain; charset="UTF-8"; format=flowed; delsp=yes
    Content-Transfer-Encoding: base64

    WW91IGhhdmUgYmVlbiBpbnZpdGVkIHRvIHRoZSBmb2xsb3dpbmcgZXZlbnQuDQoNCkRlc2lnbiBy
    ZXZpZXcNClRodXJzZGF5IE9jdCAyMiwgMjAyNiDii4UgMnBtIOKAkyAzcG0gKENlbnRyYWwgRXVy
    b3BlYW4gVGltZSAtIEJlcmxpbikNCg0KSm9pbmluZyBpbmZvOiBKb2luIHdpdGggR29vZ2xlIE1l
    ZXQNCmh0dHBzOi8vbWVldC5nb29nbGUuY29tL2FiYy1kZWZnLWhpag0K
    --000000000000b2c3d3062534fa00
    Content-Type: text/html; charset="UTF-8"
    Content-Transfer-Encoding: quoted-printable

    <span itemscope itemtype=3D"http://schema.org/InformAction"><table border=
    =3D"0" cellpadding=3D"0" cellspacing=3D"0" role=3D"presentation" style=3D"w=
    idth:100%"><tr><td><h2>Design review</h2><p>Thursday Oct 22, 2026 =E2=8B=85=
     2pm =E2=80=93 3pm</p></td></tr></table></span>
    --000000000000b2c3d3062534fa00
    Content-Type: text/calendar; charset="UTF-8"; method=REQUEST
    Content-Transfer-Encoding: 7bit

    BEGIN:VCALENDAR
    PRODID:-//Google Inc//Google Calendar 70.9054//EN
    VERSION:2.0
    CALSCALE:GREGORIAN
    METHOD:REQUEST
    BEGIN:VEVENT
    DTSTART:20261022T120000Z
    DTEND:20261022T130000Z
    DTSTAMP:20261020T091500Z
    ORGANIZER;CN=Ada Lovelace:mailto:ada.lovelace@gmail.com
    UID:7kukuqrfedlm2f9t2vr42q2g1c@google.com
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
     TRUE;CN=alex@ink.example;X-NUM-GUESTS=0:mailto:alex@ink.example
    SUMMARY:Design review
    END:VEVENT
    END:VCALENDAR

    --000000000000b2c3d3062534fa00--

    --000000000000b2c3d4062534fa01
    Content-Type: application/ics; name="invite.ics"
    Content-Disposition: attachment; filename="invite.ics"
    Content-Transfer-Encoding: base64

    QkVHSU46VkNBTEVOREFSDQpWRVJTSU9OOjIuMA0KTUVUSE9EOlJFUVVFU1QNCkVORDpWQ0FMRU5EQVINCg==
    --000000000000b2c3d4062534fa01--
    """#

    /// Attachment names in every encoding seen in the wild.
    static let encodedFilenames = #"""
    From: Clara Schmidt <clara@example.de>
    To: alex@ink.example
    Subject: =?UTF-8?Q?Unterlagen_f=C3=BCr_Montag?=
    Date: Tue, 20 Oct 2026 10:00:00 +0200
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="=_mixed 001"

    --=_mixed 001
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: 8bit

    Hallo Alex, anbei die Unterlagen.
    --=_mixed 001
    Content-Type: application/pdf
    Content-Disposition: attachment;
     filename*0*=utf-8''Pr%C3%A4sentation%20Q3%20;
     filename*1*=%E2%80%93%20final.pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKJSVFT0YK
    --=_mixed 001
    Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document;
     name="=?UTF-8?B?5aCx5ZGK5pu4LmRvY3g=?="
    Content-Disposition: attachment; filename="=?UTF-8?B?5aCx5ZGK5pu4LmRvY3g=?="
    Content-Transfer-Encoding: base64

    UEsDBBQAAAAIAA==
    --=_mixed 001
    Content-Type: application/pdf
    Content-Disposition: attachment; filename*=iso-8859-1'de'Rechnung%20M%E4rz.pdf
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKJSVFT0YK
    --=_mixed 001
    Content-Type: image/jpeg; name="C:\Users\john\Pictures\IMG_0042.JPG"
    Content-Transfer-Encoding: base64

    /9j/4AAQSkZJRgABAQAAAQABAAD/2Q==
    --=_mixed 001
    Content-Type: application/octet-stream
    Content-Disposition: attachment; filename="../../etc/passwd"
    Content-Transfer-Encoding: base64

    cm9vdDp4OjA6MDpyb290Oi9yb290Oi9iaW4vYmFzaAo=
    --=_mixed 001--
    """#

    /// Dovecot/Postfix bounce: multipart/report with delivery-status and the returned headers.
    static let dovecotBounce = #"""
    Return-Path: <>
    Delivered-To: alex@ink.example
    Received: by mail.ink.example (Postfix)
    	id 3F1A2B3C4D; Tue, 20 Oct 2026 09:30:02 +0000 (UTC)
    Date: Tue, 20 Oct 2026 09:30:02 +0000 (UTC)
    From: MAILER-DAEMON@mail.ink.example (Mail Delivery System)
    Subject: Undelivered Mail Returned to Sender
    To: alex@ink.example
    Auto-Submitted: auto-replied
    MIME-Version: 1.0
    Content-Type: multipart/report; report-type=delivery-status;
    	boundary="3F1A2B3C4D.1792488602/mail.ink.example"
    Message-Id: <20261020093002.3F1A2B3C4D@mail.ink.example>

    This is a MIME-encapsulated message.

    --3F1A2B3C4D.1792488602/mail.ink.example
    Content-Description: Notification
    Content-Type: text/plain; charset=us-ascii

    This is the mail system at host mail.ink.example.

    I'm sorry to have to inform you that your message could not
    be delivered to one or more recipients.

    <nobody@nowhere.example>: host mx.nowhere.example said: 550 5.1.1 User unknown

    --3F1A2B3C4D.1792488602/mail.ink.example
    Content-Description: Delivery report
    Content-Type: message/delivery-status

    Reporting-MTA: dns; mail.ink.example
    Arrival-Date: Tue, 20 Oct 2026 09:30:01 +0000 (UTC)

    Final-Recipient: rfc822; nobody@nowhere.example
    Action: failed
    Status: 5.1.1

    --3F1A2B3C4D.1792488602/mail.ink.example
    Content-Description: Undelivered Message Headers
    Content-Type: text/rfc822-headers

    From: Alex Rivera <alex@ink.example>
    To: nobody@nowhere.example
    Subject: Hello?

    --3F1A2B3C4D.1792488602/mail.ink.example--
    """#

    /// Mailman list: alternative body plus a text/plain footer part added by the list.
    static let mailmanFooter = #"""
    From: Pat Kim <pat@example.net>
    To: ink-dev@lists.example.org
    Subject: [ink-dev] Release checklist
    Date: Tue, 20 Oct 2026 07:00:00 -0700
    Message-ID: <release-1@example.net>
    List-Id: Ink development <ink-dev.lists.example.org>
    List-Unsubscribe: <https://lists.example.org/mailman/options/ink-dev>, <mailto:ink-dev-request@lists.example.org?subject=unsubscribe>
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="===============1234567890=="

    --===============1234567890==
    Content-Type: multipart/alternative; boundary="alt-1"

    --alt-1
    Content-Type: text/plain; charset="us-ascii"

    Please review the checklist before Friday.
    --alt-1
    Content-Type: text/html; charset="us-ascii"

    <p>Please review the <a href="https://wiki.example.org/release">checklist</a> before Friday.</p>
    --alt-1--

    --===============1234567890==
    Content-Type: text/plain; charset="us-ascii"
    MIME-Version: 1.0
    Content-Transfer-Encoding: 7bit
    Content-Disposition: inline

    _______________________________________________
    ink-dev mailing list
    ink-dev@lists.example.org
    https://lists.example.org/mailman/listinfo/ink-dev

    --===============1234567890==--
    """#

    /// S/MIME signed message.
    static let smimeSigned = #"""
    From: Security Team <security@bank.example>
    To: alex@ink.example
    Subject: Your statement is ready
    Date: Tue, 20 Oct 2026 06:00:00 +0000
    MIME-Version: 1.0
    Content-Type: multipart/signed; protocol="application/pkcs7-signature"; micalg=sha-256;
    	boundary="----SIGNED-BOUNDARY"

    This is an S/MIME signed message

    ------SIGNED-BOUNDARY
    Content-Type: text/plain; charset=utf-8

    Your October statement is ready in online banking.
    ------SIGNED-BOUNDARY
    Content-Type: application/pkcs7-signature; name="smime.p7s"
    Content-Transfer-Encoding: base64
    Content-Disposition: attachment; filename="smime.p7s"

    MIIBAGZha2Utc2lnbmF0dXJlLWJ5dGVz
    ------SIGNED-BOUNDARY--
    """#

    /// Pre-MIME message: no MIME-Version, no Content-Type, LF-only line endings.
    static let preMIMEPlain = """
    From: root (Cron Daemon)
    To: root
    Subject: Cron <root@server> /usr/local/bin/backup.sh
    Date: Tue, 20 Oct 2026 03:00:01 +0000

    backup completed: 1203 files, 4.2 GB
    """

    /// HTML-only marketing mail (no plain part) from Mailchimp, with tracking pixel and remote images.
    static let htmlOnlyMailchimp = #"""
    From: Ink Weekly <hello@inkweekly.example>
    To: alex@ink.example
    Subject: Issue #42: Fast email on every device
    Date: Tue, 20 Oct 2026 15:00:00 +0000
    MIME-Version: 1.0
    List-Unsubscribe: <https://inkweekly.us1.list-manage.com/unsubscribe?u=1&id=2>
    Content-Type: text/html; charset="utf-8"
    Content-Transfer-Encoding: quoted-printable

    <!doctype html><html><head><meta charset=3D"UTF-8"><style type=3D"text/css=
    ">.mcnTextContent{color:#202020;}</style></head><body><center><table align=
    =3D"center" border=3D"0" cellpadding=3D"0" cellspacing=3D"0" width=3D"100%=
    "><tr><td><span class=3D"mcnPreviewText" style=3D"display:none !important;=
    ">This week: offline search and quieter notifications</span><h1>Issue #42</=
    h1><p class=3D"mcnTextContent">Hello &amp; welcome to issue&nbsp;#42.</p><img=
     src=3D"https://mcusercontent.example/hero.png" width=3D"564"><img src=3D"h=
    ttps://inkweekly.us1.list-manage.com/track/open.php?u=3D1&amp;id=3D2&amp;e=
    =3D3" height=3D"1" width=3D"1"></td></tr></table></center></body></html>
    """#
}
