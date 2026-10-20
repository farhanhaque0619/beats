import Foundation
import InkModel

/// The demo inbox: about forty conversations for "Alex Rivera", a product designer at the
/// (fictional) company Fieldstone, with friends, family, a landlord, newsletters, receipts and a
/// trip to Lisbon coming up. Every person, company and domain is made up (`.example` domains).
/// Dates are relative to `now`, so the inbox always looks fresh: several messages today, some
/// yesterday, more this week and a tail of older mail.
enum DemoContent {
    static func mailboxes(accountID: String) -> [MailboxInfo] {
        [
            MailboxInfo(accountID: accountID, path: "INBOX", role: .inbox, attributes: ["\\HasNoChildren"]),
            MailboxInfo(accountID: accountID, path: "Drafts", role: .drafts, attributes: ["\\HasNoChildren", "\\Drafts"]),
            MailboxInfo(accountID: accountID, path: "Sent", role: .sent, attributes: ["\\HasNoChildren", "\\Sent"]),
            MailboxInfo(accountID: accountID, path: "Archive", role: .archive, attributes: ["\\HasNoChildren", "\\Archive"]),
            MailboxInfo(accountID: accountID, path: "Junk", role: .junk, attributes: ["\\HasNoChildren", "\\Junk"]),
            MailboxInfo(accountID: accountID, path: "Trash", role: .trash, attributes: ["\\HasNoChildren", "\\Trash"]),
            MailboxInfo(accountID: accountID, path: "Receipts", role: .custom, attributes: ["\\HasNoChildren"]),
            MailboxInfo(accountID: accountID, path: "Travel", role: .custom, attributes: ["\\HasNoChildren"]),
        ]
    }

    // MARK: People

    static let priya = EmailAddress(name: "Priya Natarajan", address: "priya@fieldstone.example")
    static let marcus = EmailAddress(name: "Marcus Bell", address: "marcus.bell@fieldstone.example")
    static let hannah = EmailAddress(name: "Hannah Park", address: "hannah.park@fieldstone.example")
    static let jordan = EmailAddress(name: "Jordan Okafor", address: "jordan.okafor@fieldstone.example")
    static let maya = EmailAddress(name: "Maya Torres", address: "maya.torres@fieldstone.example")
    static let comms = EmailAddress(name: "Fieldstone Comms", address: "comms@fieldstone.example")
    static let sam = EmailAddress(name: "Sam Chen", address: "sam.chen@mailbox.example")
    static let nina = EmailAddress(name: "Nina Rivera", address: "nina.rivera@mailbox.example")
    static let ray = EmailAddress(name: "Ray Rivera", address: "ray.rivera@mailbox.example")
    static let grace = EmailAddress(name: "Grace Oyelaran", address: "grace.o@mailbox.example")
    static let theo = EmailAddress(name: "Theo Lindqvist", address: "theo@lindqvist.example")
    static let marisol = EmailAddress(name: "Marisol Vega", address: "marisol@vegaproperties.example")
    static let elena = EmailAddress(name: "Elena Duarte", address: "e.duarte@westbrook.example")
    static let dev = EmailAddress(name: "Dev Mehta", address: "dev@thebuildlog.example")
    static let lena = EmailAddress(name: "Lena Fischer", address: "lena@tinkerbit.example")
    static let omar = EmailAddress(name: "Omar Haddad", address: "omar@riverbendfoodbank.example")
    static let june = EmailAddress(name: "June Albright", address: "june@albright.example")
    static let ingrid = EmailAddress(name: "Studio Ostrander", address: "accounts@studioostrander.example")

    static let kestrel = EmailAddress(name: "Kestrel Air", address: "itineraries@kestrelair.example")
    static let harborPine = EmailAddress(name: "Harbor & Pine Coffee", address: "orders@harborandpine.example")
    static let margin = EmailAddress(name: "The Margin", address: "newsletter@themargin.example")
    static let forgeline = EmailAddress(name: "Kofi Mensah", address: "notifications@forgeline.example")
    static let forgelineBot = EmailAddress(name: "Forgeline", address: "notifications@forgeline.example")
    static let tidewell = EmailAddress(name: "Tidewell Bank", address: "no-reply@tidewellbank.example")
    static let larkfield = EmailAddress(name: "Larkfield Books", address: "orders@larkfieldbooks.example")
    static let fieldNotes = EmailAddress(name: "Field Notes", address: "hello@fieldnotesweekly.example")
    static let cloudberry = EmailAddress(name: "Cloudberry Music", address: "receipts@cloudberry.example")
    static let brightloom = EmailAddress(name: "Brightloom", address: "security@brightloom.example")
    static let brightloomTeam = EmailAddress(name: "Brightloom", address: "team@brightloom.example")
    static let neighborly = EmailAddress(name: "Neighborly", address: "digest@neighborly.example")
    static let stridewise = EmailAddress(name: "Stridewise", address: "coach@stridewise.example")
    static let library = EmailAddress(name: "Pinecrest Public Library", address: "notices@pinecrestlibrary.example")
    static let northstar = EmailAddress(name: "Northstar Dev Summit", address: "speakers@northstarsummit.example")
    static let saltgrass = EmailAddress(name: "Saltgrass Kitchen", address: "letters@saltgrass.example")
    static let ridgeway = EmailAddress(name: "Ridgeway Motors", address: "service@ridgewaymotors.example")
    static let clearwater = EmailAddress(name: "Clearwater Utilities", address: "billing@clearwaterutilities.example")
    static let wayfarer = EmailAddress(name: "Wayfarer Stays", address: "reservations@wayfarerstays.example")
    static let alumni = EmailAddress(name: "Westbrook Alumni", address: "alumni@westbrook.example")
    static let oldMill = EmailAddress(name: "Old Mill Hall", address: "boxoffice@oldmillhall.example")
    static let wickhaven = EmailAddress(name: "Wickhaven Candle Co.", address: "hello@wickhaven.example")
    static let rail = EmailAddress(name: "Ridgeline Rail", address: "tickets@ridgelinerail.example")
    static let spamRewards = EmailAddress(name: "Rewards Center", address: "claim@reward-center.example")
    static let spamAdmin = EmailAddress(name: "Mail Administrator", address: "admin@secure-mailbox-verify.example")
    static let spamWatches = EmailAddress(name: "Luxe Outlet", address: "deals@luxe-watch-outlet.example")

    // MARK: Snapshot

    static func snapshot(account: AccountConfig, now: Date, uidValidity: UInt32, calendar: Calendar = .current) -> DemoSnapshot {
        var b = DemoBuilder(account: account, now: now, calendar: calendar)
        addToday(&b)
        addYesterday(&b)
        addThisWeek(&b)
        addOlder(&b)
        addOtherFolders(&b)
        return b.snapshot(uidValidity: uidValidity)
    }

    // MARK: Today

    private static func addToday(_ b: inout DemoBuilder) {
        let me = b.me

        // A four-message work thread with Alex's own reply; the newest message is unread. The
        // review is a weekday a couple of days out, and the plan covers this quarter's months.
        let quarter = b.quarter(of: b.now)
        let reviewDay = b.format(b.workday(atLeast: 2, after: b.now), "EEEE")
        let months = (0...3).map { b.month($0, from: b.now) }
        func milestone(_ index: Int, _ text: String) -> String { months[index].padding(toLength: 11, withPad: " ", startingAt: 0) + text }
        b.add("q4-roadmap.1", from: priya, to: [me], cc: [marcus],
              subject: "\(quarter) roadmap review — draft for \(reviewDay)", date: b.yesterday(17, 42),
              text: """
              Hi Alex,

              Attached is the first full draft of the \(quarter) roadmap ahead of \(reviewDay)'s review. The big changes since the offsite:

              • Onboarding v2 moves up to \(months[0]) — it's our biggest lever on week-one retention.
              • Offline mode slips to \(months[3]) so we can do it properly.
              • Search gets a small, dedicated squad (Marcus has thoughts on staffing).

              Could you take a pass at the onboarding section in particular? I'd love your read on whether the milestones are realistic for design.

              Thanks,
              Priya
              """,
              answered: true,
              attachments: [DemoBuilder.attachment(2, "\(quarter)-Roadmap-Draft.pdf", "application/pdf", DemoAssets.pdf(
                  title: "\(quarter) Roadmap — Draft v2", subtitle: "Fieldstone Product · Prepared by Priya Natarajan",
                  lines: [
                      "# Themes", "1. Week-one retention: Onboarding v2 (checklist, sample project, invites).",
                      "2. Reliability: offline mode foundations, sync conflict handling.", "3. Findability: search squad, saved filters.",
                      "", "# Milestones", milestone(0, "Onboarding v2 design complete; checklist in beta."),
                      milestone(1, "Onboarding v2 to 100%; search squad staffed."), milestone(2, "Search v1 (titles + people) behind a flag."),
                      milestone(3, "Offline mode target (read-only first)."), "", "# Open questions",
                      "- Do we cut the animated tour from v2?", "- Staffing for search: one or two engineers?",
                      "- Is \(months[3]) a commitment or a target for offline mode?",
                  ]))])
        b.add("q4-roadmap.2", folder: "Sent", from: me, to: [priya], cc: [marcus],
              subject: "Re: \(quarter) roadmap review — draft for \(reviewDay)", date: b.today(112),
              text: """
              Thanks Priya — this reads really well.

              On onboarding: the milestones are doable if we cut the animated tour from v2 and ship the checklist first. That buys us about two weeks. I've left comments on pages 3 and 4.

              One question: are we presenting the \(months[3]) date for offline mode as firm, or as a target? Worth being explicit on \(reviewDay).

              Alex
              """, parent: "q4-roadmap.1")
        b.add("q4-roadmap.3", from: marcus, to: [priya, me],
              subject: "Re: \(quarter) roadmap review — draft for \(reviewDay)", date: b.today(64),
              text: """
              Agree with Alex on the tour — the checklist gets us 80% of the value for a fraction of the work.

              For search, I can free up Kofi two days a week from \(months[1]) without hurting the API work. That plus one more engineer should be enough for the first milestone.

              Marcus
              """, parent: "q4-roadmap.2")
        b.add("q4-roadmap.4", from: priya, to: [me], cc: [marcus],
              subject: "Re: \(quarter) roadmap review — draft for \(reviewDay)", date: b.today(8),
              text: """
              Thanks both — I've folded your notes into v3.

              Let's call \(months[3]) a target, not a commitment. I'll say that up front so nobody walks away with the wrong date.

              \(reviewDay) at 10:00 in the Larch room still works for everyone? I'll bring printed copies. Alex, could you bring the revised onboarding deck?

              P.
              """, unread: true, parent: "q4-roadmap.3")

        // Calendar invitation with an .ics attachment.
        let critique = b.next(weekday: 5, hour: 14)
        let critiqueEnd = critique.addingTimeInterval(3600)
        let whenLine = "\(b.format(critique, "EEEE, MMMM d")) · \(b.format(critique, "h:mm"))–\(b.format(critiqueEnd, "h:mm a"))"
        b.add("invite.design-critique", from: jordan, to: [me, priya, hannah],
              subject: "Invitation: Design critique @ \(b.format(critique, "EEE MMM d")), \(b.format(critique, "h:mm"))–\(b.format(critiqueEnd, "h:mm a"))",
              date: b.today(36),
              text: """
              Jordan Okafor has invited you to an event.

              Design critique
              When: \(whenLine)
              Where: Fieldstone HQ, Larch room (or join on Huddle: huddle.example/fieldstone-crit)
              Who: Jordan Okafor (organizer), Alex Rivera, Priya Natarajan, Hannah Park

              Bring one work in progress you'd like eyes on. Ten minutes each, then open feedback. Snacks provided.

              Going? Yes · Maybe · No

              Invitation from Fieldstone Calendar. You are receiving this email because you are an attendee of this event.
              """,
              unread: true,
              attachments: [DemoBuilder.attachment(2, "invite.ics", "text/calendar", DemoAssets.ics(
                  uid: "design-critique-\(b.format(critique, "yyyyMMdd"))@fieldstone.example",
                  summary: "Design critique", start: critique, end: critiqueEnd,
                  location: "Fieldstone HQ, Larch room",
                  description: "Bring one work in progress you'd like eyes on. Ten minutes each, then open feedback.",
                  attendees: [
                      .init(name: "Jordan Okafor", email: jordan.address, organizer: true),
                      .init(name: me.displayName, email: me.address),
                      .init(name: "Priya Natarajan", email: priya.address),
                      .init(name: "Hannah Park", email: hannah.address),
                  ], stamp: b.today(36)))])

        b.add("dinner-saturday", from: sam, to: [me], subject: "Dinner Saturday?", date: b.today(82),
              text: """
              Hey!

              Mia and I are finally trying that new ramen place on Alder Street — Saturday around 7? They don't take reservations, so the plan is to show up early, put our names down and grab a drink next door while we wait.

              Let me know if you and Jess are in. Bring an appetite, apparently the tonkotsu is ridiculous.

              Sam
              """, unread: true)

        let marginIssue = DemoHTML.newsletter(
            brand: "The Margin", accent: "#c2410c", background: "#f4efe6", kicker: "Issue 112",
            title: "Why small teams ship faster",
            preheader: "It isn't the headcount. It's the number of handoffs — and what you do about them.",
            intro: """
            Every few years someone rediscovers that small teams ship faster, and every few years we draw the wrong conclusion: that the trick is to keep teams small. This week, a closer look at what actually slows big teams down — and how to borrow the good parts at any size.
            """,
            heroImagePNG: DemoAssets.landscapePNG(width: 240, height: 100, palette: DemoAssets.dusk),
            heroAlt: "Illustration: a ridge at dusk",
            sections: [
                .init(heading: "It's the handoffs, not the headcount", body: """
                In the twenty teams we talked to, the best predictor of speed wasn't size. It was how many times a piece of work changed hands between "someone had an idea" and "a customer used it". Small teams win because they have fewer seams, not fewer people.

                The fastest large team we met had a simple rule: whoever starts a feature walks it all the way to release, pulling in help rather than passing it on.
                """),
                .init(heading: "Three things we read this week", body: """
                • A field guide to writing decision documents nobody has to schedule a meeting about.
                • Why "done" should include the first week of support — a case for owning outcomes.
                • The quiet power of a team that says no to most meetings, most of the time.
                """),
                .init(heading: "Try this on Monday", body: """
                Pick the last thing your team shipped and count the handoffs. Then ask which one you could remove next time. One fewer seam per feature is worth more than another planning ritual.
                """),
            ],
            signoff: "Until next week,\nRosa Kim, editor",
            footerLines: ["The Margin is a weekly letter about how good teams work.", "You're receiving this because you subscribed at themargin.example."],
            unsubscribe: "https://themargin.example/unsubscribe/af31c9")
        b.add("margin-112", from: margin, to: [me], subject: "Issue 112: Why small teams ship faster", date: b.today(150),
              text: marginIssue.text, html: marginIssue.html,
              snippet: "It isn't the headcount. It's the number of handoffs — and what you do about them. Every few years someone rediscovers that small teams ship faster…",
              unread: true, bulk: true, unsubscribe: "https://themargin.example/unsubscribe/af31c9")

        b.add("pr-482-review", from: forgeline, to: [me], replyTo: [EmailAddress(address: "reply+482@forgeline.example")],
              subject: "Re: [fieldstone/atlas] Fix thread ordering on cold launch (PR #482)", date: b.today(186),
              text: """
              @kofi-mensah approved this pull request.

              Looks good! Verified on a cold launch with three accounts — threads now come back in the right order and the flicker on first paint is gone.

              One nit: ThreadCache.prime() could return early when the store is empty, but happy to land this as is.

              —
              Reply to this email directly, view it on Forgeline, or unsubscribe.
              You are receiving this because you authored the thread.
              """,
              unread: true, bulk: true, unsubscribe: "https://forgeline.example/notifications/unsubscribe/482",
              externalReferences: ["fieldstone/atlas/pull/482@forgeline.example"])

        let order = DemoHTML.receipt(
            brand: "Harbor & Pine Coffee", accent: "#1f4d3a", title: "Thanks for your order, Alex!",
            preheader: "Order #HP-48213 is confirmed and will ship tomorrow.",
            intro: "We're roasting your beans this afternoon. You'll get another email with tracking as soon as your order ships.",
            meta: [("Order", "#HP-48213"), ("Placed", b.format(b.today(252), "MMM d, yyyy")), ("Ships to", "Alex Rivera, Seattle WA")],
            items: [
                .init(name: "Ridgeline Blend — whole bean", detail: "340 g · Qty 2", amount: "$36.00"),
                .init(name: "Ceramic pour-over cone", detail: "Slate · Qty 1", amount: "$24.00"),
            ],
            totals: [("Subtotal", "$60.00"), ("Shipping", "Free"), ("Tax", "$5.10"), ("Total", "$65.10")],
            note: "Questions about your order? Just reply to this email — a real person reads every one.",
            footerLines: ["Harbor & Pine Coffee Roasters · 18 Wharf Lane, Port Avery"], unsubscribe: nil)
        b.add("order-hp-48213", from: harborPine, to: [me], subject: "Your Harbor & Pine order #HP-48213", date: b.today(252),
              text: order.text, html: order.html, snippet: "Thanks for your order, Alex! We're roasting your beans this afternoon. Order #HP-48213 · Total $65.10",
              bulk: true)
    }

    // MARK: Yesterday

    private static func addYesterday(_ b: inout DemoBuilder) {
        let me = b.me
        let depart = b.daysAhead(16, 7, 5)
        let returnFlight = b.daysAhead(25, 13, 40)
        let itinerary = DemoHTML.card(
            brand: "KESTREL AIR", accent: "#0b5cad", title: "You're all set for Lisbon",
            preheader: "Confirmation XK7Q2M · \(b.format(depart, "EEE, MMM d")) · Seattle to Lisbon",
            intro: "Hi Alex, here's your itinerary. Your e-tickets are attached — you can also check in on the Kestrel Air app 24 hours before departure.",
            details: [
                .init(heading: "Outbound · \(b.format(depart, "EEE, MMM d"))", rows: [
                    ("KX 218", "Seattle (SEA) 7:05 AM → Boston (BOS) 3:32 PM"),
                    ("KX 482", "Boston (BOS) 6:50 PM → Lisbon (LIS) 7:05 AM +1"),
                    ("Seats", "23A, 23B · Economy"),
                ]),
                .init(heading: "Return · \(b.format(returnFlight, "EEE, MMM d"))", rows: [
                    ("KX 483", "Lisbon (LIS) 1:40 PM → Boston (BOS) 4:15 PM"),
                    ("KX 219", "Boston (BOS) 6:30 PM → Seattle (SEA) 9:58 PM"),
                    ("Seats", "31C, 31D · Economy"),
                ]),
                .init(heading: "Passengers", rows: [
                    ("Alex Rivera", "E-ticket 0274 8812 3301"),
                    ("Jess Morgan", "E-ticket 0274 8812 3302"),
                    ("Confirmation", "XK7Q2M"),
                ]),
            ],
            action: (title: "Manage booking", url: "https://kestrelair.example/trips/XK7Q2M"),
            outro: "Each passenger can bring one carry-on bag and one personal item. Checked bags can be added until 3 hours before departure.",
            footerLines: ["Kestrel Air · This is a service message about your booking."], unsubscribe: nil)
        b.add("trip-xk7q2m", from: kestrel, to: [me], subject: "Your trip to Lisbon: itinerary and e-tickets (XK7Q2M)",
              date: b.yesterday(9, 12), text: itinerary.text, html: itinerary.html,
              snippet: "You're all set for Lisbon. Confirmation XK7Q2M · Seattle to Lisbon on \(b.format(depart, "EEE, MMM d")). Your e-tickets are attached.",
              flagged: true,
              attachments: [DemoBuilder.attachment(2, "KestrelAir-eTicket-XK7Q2M.pdf", "application/pdf", DemoAssets.pdf(
                  title: "Kestrel Air — Electronic Ticket", subtitle: "Confirmation XK7Q2M · Issued \(b.format(b.yesterday(9, 12), "MMM d, yyyy"))",
                  lines: [
                      "# Passengers", "ALEX RIVERA      E-ticket 0274 8812 3301", "JESS MORGAN      E-ticket 0274 8812 3302", "",
                      "# Outbound \u{00B7} \(b.format(depart, "EEE, MMM d yyyy"))",
                      "KX 218   SEA 07:05  ->  BOS 15:32   Seats 23A 23B", "KX 482   BOS 18:50  ->  LIS 07:05+1   Seats 23A 23B", "",
                      "# Return \u{00B7} \(b.format(returnFlight, "EEE, MMM d yyyy"))",
                      "KX 483   LIS 13:40  ->  BOS 16:15   Seats 31C 31D", "KX 219   BOS 18:30  ->  SEA 21:58   Seats 31C 31D", "",
                      "Fare: Economy Standard. Baggage: 1 carry-on + 1 personal item per passenger.",
                  ], accent: (0.04, 0.36, 0.68)))])

        let leaseDate = b.daysAgo(3, 10, 15)
        let replyDate = b.yesterday(11, 30)
        // The fan visit: the coming Friday when it's within the week, else the next workday.
        var visit = b.weekday(6, atLeast: 2, after: replyDate)
        if visit.timeIntervalSince(replyDate) > 6 * 86_400 { visit = b.workday(atLeast: 2, after: replyDate) }
        b.add("lease-4b.1", from: marisol, to: [me], subject: "Lease renewal for unit 4B", date: leaseDate,
              text: """
              Hi Alex,

              Your lease on 4B is up at the end of \(b.month(2, from: leaseDate)), so I wanted to reach out early. We'd love to have you stay.

              For a 12-month renewal the rent would go from $2,150 to $2,210 a month. I can also offer a 6-month term at $2,260 if you'd rather keep things flexible.

              No rush — let me know by mid-\(b.month(1, from: leaseDate)) which you prefer and I'll send the paperwork.

              Best,
              Marisol Vega
              Vega Properties
              """, answered: true)
        b.add("lease-4b.2", folder: "Sent", from: me, to: [marisol], subject: "Re: Lease renewal for unit 4B", date: b.daysAgo(2, 21, 3),
              text: """
              Hi Marisol,

              Thanks for the early heads-up — we'd definitely like to stay. The 12-month term sounds good.

              One thing before we sign: the bathroom fan has been rattling for a few weeks. Could someone take a look sometime this month?

              Thanks,
              Alex
              """, parent: "lease-4b.1")
        b.add("lease-4b.3", from: marisol, to: [me], subject: "Re: Lease renewal for unit 4B", date: replyDate,
              text: """
              Wonderful, so glad you're staying!

              I've put you down for 12 months at $2,210. Our maintenance tech, Luis, can come by \(b.format(visit, "EEEE")) between 9 and 11 for the fan — does that work? If not, just suggest a time.

              I'll email the renewal paperwork next week.

              Marisol
              """, unread: true, parent: "lease-4b.2")

        b.add("hike-photos", from: theo, to: [me, sam], subject: "Photos from Saturday's hike", date: b.yesterday(19, 5),
              text: """
              Finally got these off my camera. The light at the overlook was unreal — sorry for making everyone wait while I fiddled with settings.

              Two favourites attached. The full album is in the shared folder.

              Same time next month? I'm thinking the Cedar Falls loop.

              Theo
              """,
              attachments: [
                  DemoBuilder.attachment(2, "ridge-trail.png", "image/png", DemoAssets.landscapePNG(width: 240, height: 160, palette: DemoAssets.dusk)),
                  DemoBuilder.attachment(3, "lake-overlook.png", "image/png", DemoAssets.landscapePNG(width: 240, height: 160, palette: DemoAssets.lake)),
              ])

        let statementDate = b.yesterday(7, 30)
        let statementTitle = "Your \(b.month(0, from: statementDate)) statement is ready"
        let statement = DemoHTML.card(
            brand: "TIDEWELL BANK", accent: "#0f766e", title: statementTitle,
            preheader: "Your statement for the card ending in 4417 is ready to view.",
            intro: "Hi Alex, your statement for the Tidewell Rewards card ending in 4417 is now available in online banking.",
            details: [.init(heading: "Summary", rows: [
                ("Statement balance", "$1,284.36"), ("Minimum payment", "$35.00"),
                ("Payment due", b.format(b.daysAhead(24, 9, 0), "MMMM d")), ("Autopay", "On — full balance"),
            ])],
            action: (title: "View statement", url: "https://tidewellbank.example/statements"),
            outro: "Tidewell Bank will never ask for your password or one-time codes by email.",
            footerLines: ["Tidewell Bank, Member FDIC (fictional). Please don't reply to this email."], unsubscribe: nil)
        b.add("statement-oct", from: tidewell, to: [me], subject: statementTitle, date: statementDate,
              text: statement.text, html: statement.html,
              snippet: "Your statement for the Tidewell Rewards card ending in 4417 is now available. Statement balance $1,284.36.",
              bulk: true)

        let shipped = DemoHTML.card(
            brand: "Larkfield Books", accent: "#7c3aed", title: "Your books are on their way",
            preheader: "2 items shipped · arriving \(b.format(b.daysAhead(2, 12, 0), "EEEE"))",
            intro: "Good news, Alex — your order has shipped and should arrive \(b.format(b.daysAhead(2, 12, 0), "EEEE, MMMM d")).",
            details: [
                .init(heading: "In this shipment", rows: [("The Quiet Grid", "Paperback · Qty 1"), ("Field Guide to Northwest Mushrooms", "Hardcover · Qty 1")]),
                .init(heading: "Tracking", rows: [("Carrier", "Parcelpoint Ground"), ("Tracking number", "PP 4471 0932 8810")]),
            ],
            action: (title: "Track package", url: "https://larkfieldbooks.example/track/PP447109328810"),
            outro: "Happy reading!",
            footerLines: ["Larkfield Books · Independent since 1987"], unsubscribe: "https://larkfieldbooks.example/unsubscribe")
        b.add("larkfield-shipped", from: larkfield, to: [me], subject: "Shipped: 2 items from your Larkfield Books order", date: b.yesterday(15, 20),
              text: shipped.text, html: shipped.html,
              snippet: "Good news, Alex — your order has shipped and should arrive \(b.format(b.daysAhead(2, 12, 0), "EEEE")). Tracking PP 4471 0932 8810.",
              unread: true, bulk: true, unsubscribe: "https://larkfieldbooks.example/unsubscribe")
    }

    // MARK: This week

    private static func addThisWeek(_ b: inout DemoBuilder) {
        let me = b.me

        // Next month's offsite, on its second Thursday and Friday.
        let offsitePlanned = b.daysAgo(5, 9, 20)
        let offsiteMonth = b.month(1, from: offsitePlanned)
        let offsiteStart = b.weekday(5, number: 2, monthsAfter: 1, from: offsitePlanned)
        let offsiteDays = "\(offsiteMonth) \(b.format(offsiteStart, "d"))–\(b.format(offsiteStart.addingTimeInterval(86_400), "d"))"
        b.add("offsite.1", from: hannah, to: [me, marcus, priya], subject: "Offsite planning: venue shortlist", date: offsitePlanned,
              text: """
              Hi all,

              I've narrowed the \(offsiteMonth) offsite down to three venues — all within an hour of the office, all fit 24 people:

              1. Millbrook Lodge — big fireplace room, great food, a bit pricier.
              2. The Foundry Annex — industrial loft, walkable from the train, no outdoor space.
              3. Saltmarsh Retreat — beautiful, but the drive is 55 minutes and parking is tight.

              Can you each send me your first and second choice by Friday? I'll book whichever wins.

              Thanks!
              Hannah
              """, answered: true)
        b.add("offsite.2", from: marcus, to: [hannah], cc: [me, priya], subject: "Re: Offsite planning: venue shortlist", date: b.daysAgo(5, 11, 2),
              text: "Millbrook first, Foundry second. The fireplace room is perfect for the planning sessions, and the team will appreciate the food.\n\nM.",
              parent: "offsite.1")
        b.add("offsite.3", folder: "Sent", from: me, to: [hannah], cc: [marcus, priya], subject: "Re: Offsite planning: venue shortlist", date: b.daysAgo(4, 8, 47),
              text: "Millbrook for me too, Foundry as backup.\n\nIf we go with Millbrook, could we get the smaller breakout room as well? Design would love a space for the workshop on day two.\n\nAlex",
              parent: "offsite.2")
        b.add("offsite.4", from: priya, to: [hannah], cc: [me, marcus], subject: "Re: Offsite planning: venue shortlist", date: b.daysAgo(2, 16, 15),
              text: "Millbrook it is — sounds unanimous. Hannah, thank you for pulling this together so quickly.\n\nLet's hold \(offsiteDays) and share an agenda draft next week. Alex, yes to the breakout room.\n\nPriya",
              parent: "offsite.3")

        let due = b.daysAhead(30, 9, 0)
        let invoice = "INV-\(b.format(b.daysAgo(2, 10, 40), "yyyy"))-1043"
        b.add("invoice-1043", from: ingrid, to: [me], subject: "Invoice \(invoice) — Fieldstone brand refresh (phase 2)", date: b.daysAgo(2, 10, 40),
              text: """
              Hi Alex,

              Please find attached invoice \(invoice) for phase 2 of the Fieldstone brand refresh (illustration system and icon set).

              Amount due: $8,400.00
              Due date: \(b.format(due, "MMMM d, yyyy"))

              Payment details are on the invoice. It was a pleasure working with you and the team — the new icons look fantastic in the app.

              Warmly,
              Ingrid Ostrander
              Studio Ostrander
              """, unread: true,
              attachments: [DemoBuilder.attachment(2, "\(invoice).pdf", "application/pdf", DemoAssets.pdf(
                  title: "Invoice \(invoice)", subtitle: "Studio Ostrander · Bill to: Fieldstone, attn. Alex Rivera",
                  lines: [
                      "Issued: \(b.format(b.daysAgo(2, 10, 40), "MMMM d, yyyy"))      Due: \(b.format(due, "MMMM d, yyyy"))", "",
                      "# Services", "Illustration system (12 spot illustrations)            $5,200.00",
                      "Icon set (48 icons, 2 weights)                         $2,700.00", "Production files and handoff                            $500.00", "",
                      "# Total due                                            $8,400.00", "",
                      "Bank transfer: Northgate Credit Union, account 0099 1842 77 (fictional).",
                  ], accent: (0.55, 0.27, 0.07)))])

        let notes = DemoHTML.newsletter(
            brand: "Field Notes", accent: "#2563eb", background: "#eef2f7", kicker: "No. 87",
            title: "Typography that breathes",
            preheader: "Line height, measure and the case for a little more white space.",
            intro: "This week: three small typographic habits that make long reading easier, and a gallery of interfaces that get it right.",
            heroImagePNG: nil, heroAlt: "",
            sections: [
                .init(heading: "1. Mind the measure", body: "Lines between 45 and 75 characters are easiest to read. On wide screens, cap your text column rather than letting it run edge to edge."),
                .init(heading: "2. Leading scales with size", body: "Body text likes a line height around 1.5. Headlines want less — 1.1 to 1.25 — or they start to drift apart."),
                .init(heading: "3. Space is structure", body: "Group related things by putting less space between them than between groups. Your readers will feel the hierarchy before they read a word."),
            ],
            signoff: "See you next week,\nThe Field Notes team",
            footerLines: ["Field Notes is a weekly design reading list."], unsubscribe: "https://fieldnotesweekly.example/unsubscribe")
        b.add("fieldnotes-87", from: fieldNotes, to: [me], subject: "Field Notes #87: Typography that breathes", date: b.daysAgo(3, 7, 0),
              text: notes.text, html: notes.html, snippet: "Line height, measure and the case for a little more white space. This week: three small typographic habits that make long reading easier.",
              bulk: true, unsubscribe: "https://fieldnotesweekly.example/unsubscribe")

        let asked = b.daysAgo(6, 20, 10)
        let deadline = "\(b.month(2, from: asked)) 1"
        b.add("halden-letter.1", folder: "Sent", from: me, to: [elena], subject: "Recommendation letter for the Halden Fellowship", date: asked,
              text: """
              Dear Professor Duarte,

              I hope the semester is treating you well! I'm applying for the Halden Design Fellowship this \(b.season(of: b.firstOfMonth(2, from: asked))), and I'd be honoured if you would write a letter of recommendation. The deadline is \(deadline).

              I can send my statement of purpose, CV and the wayfinding project we did in your studio course, if that would help.

              Thank you for considering it,
              Alex Rivera
              """)
        b.add("halden-letter.2", from: elena, to: [me], subject: "Re: Recommendation letter for the Halden Fellowship", date: b.daysAgo(3, 14, 22),
              text: """
              Dear Alex,

              Of course — I'd be delighted. Your wayfinding project is still one of my favourite examples to show students.

              Please send your statement and CV when they're ready, plus a short note on what you'd like me to emphasise. I'll have the letter in well before \(deadline).

              All best,
              Elena Duarte
              Professor of Interaction Design, Westbrook University
              """, parent: "halden-letter.1")

        let music = DemoHTML.receipt(
            brand: "Cloudberry Music", accent: "#db2777", title: "Your receipt",
            preheader: "Cloudberry Family · monthly · $18.43",
            intro: "Thanks for listening with Cloudberry. Here's your receipt for this month.",
            meta: [("Receipt", "CB-2210-88431"), ("Billed", b.format(b.daysAgo(4, 6, 15), "MMM d, yyyy")), ("Payment", "Visa ···· 4417")],
            items: [.init(name: "Cloudberry Family", detail: "Monthly · up to 6 listeners", amount: "$16.99")],
            totals: [("Subtotal", "$16.99"), ("Tax", "$1.44"), ("Total", "$18.43")],
            note: "You can change or cancel your plan any time in Account → Subscription.",
            footerLines: ["Cloudberry Music Ltd. (fictional)"], unsubscribe: nil)
        b.add("cloudberry-oct", from: cloudberry, to: [me], subject: "Your receipt from Cloudberry Music", date: b.daysAgo(4, 6, 15),
              text: music.text, html: music.html, snippet: "Thanks for listening with Cloudberry. Cloudberry Family, monthly — Total $18.43.", bulk: true)

        b.add("brightloom-signin", from: brightloom, to: [me], subject: "New sign-in to your Brightloom account", date: b.daysAgo(2, 22, 48),
              text: """
              We noticed a new sign-in to your Brightloom account.

              Device: Mac (Safari)
              Location: Seattle, WA (approximate)
              Time: \(b.format(b.daysAgo(2, 22, 46), "EEEE, MMMM d 'at' h:mm a"))

              If this was you, you can ignore this email. If not, reset your password right away and review your active sessions in Settings → Security.

              — The Brightloom team
              """, bulk: true)

        b.add("mom-birthday", from: nina, to: [me], subject: "Mom's birthday 🎂 — gift ideas?", date: b.daysAgo(2, 12, 31),
              text: """
              Hi!!

              Mom's birthday is three weeks from Saturday (yes, I'm being organised for once). I was thinking we go in together on something nice instead of two smaller gifts.

              Ideas so far:
              – a pottery class for her and Dad (she keeps mentioning the studio on Fifth)
              – the cookbook from that bakery she loves, plus a new stand mixer
              – framing a few of Grandpa's old photos

              Thoughts? I can handle ordering if you send me your half.

              Love,
              Nina
              """, unread: true, flagged: true)

        b.add("build-log-guest", from: dev, to: [me], subject: "Guest spot on The Build Log?", date: b.daysAgo(3, 13, 5),
              text: """
              Hi Alex,

              I host The Build Log, a podcast about how product teams actually work. I loved your talk at Northstar last spring on designing for interruptions, and I'd love to have you on as a guest.

              Episodes are about 45 minutes, recorded remotely, and very conversational. We'd talk about your path into design, how Fieldstone runs critiques, and whatever you're excited about lately.

              We're booking for \(b.month(1, from: b.daysAgo(3, 13, 5))) and \(b.month(2, from: b.daysAgo(3, 13, 5))). Any interest?

              Cheers,
              Dev Mehta
              The Build Log
              """)

        b.add("neighborly-digest", from: neighborly, to: [me], subject: "This week near Alder Street: a lost cat, a free piano and a block party", date: b.daysAgo(5, 8, 0),
              text: """
              Here's what your neighbours shared this week.

              • Lost cat: Pepper, grey tabby, last seen near 34th and Alder. Friendly, answers to treats.
              • Free piano: an upright in good shape, you haul. First come, first served.
              • Block party: Saturday the \(b.dayOrdinal(b.weekday(7, atLeast: 10, after: b.daysAgo(5, 8, 0)))), 2–6pm on Birch Street. Bring a dish to share.

              See all 14 posts on Neighborly.
              """, bulk: true, unsubscribe: "https://neighborly.example/settings/email")

        b.add("stridewise-month", from: stridewise, to: [me], subject: "Your month in running: 84 km and a new 10K best", date: b.daysAgo(6, 7, 45),
              text: """
              Nice work, Alex!

              Last month you ran 84.2 km over 12 runs — your most consistent month this year. You also set a new 10K personal best: 48:12.

              Most popular route: Greenlake Loop (5 times)
              Longest run: 14.6 km
              Average pace: 5:21 /km

              Keep it going this month — you're 16 km from your \(b.season(of: b.daysAgo(6, 7, 45))) goal.
              """, bulk: true, unsubscribe: "https://stridewise.example/email-settings")

        b.add("atlas-api.1", from: lena, to: [me], subject: "Quick question about the Atlas API", date: b.daysAgo(4, 15, 40),
              text: """
              Hi Alex,

              Marcus suggested I ask you directly — sorry for the cold email! We're building an integration with Atlas and can't work out where "shared with me" projects live in the API. /v2/projects only seems to return projects I own.

              Is there a separate endpoint, or a parameter I'm missing?

              Thanks so much,
              Lena Fischer
              Tinkerbit
              """, answered: true)
        b.add("atlas-api.2", folder: "Sent", from: me, to: [lena], subject: "Re: Quick question about the Atlas API", date: b.daysAgo(4, 17, 5),
              text: "Hi Lena — no problem at all! Add ?scope=all to /v2/projects and you'll get shared projects too. It's in the docs under \"Listing projects\", but it's easy to miss.\n\nLet me know if anything else is unclear.\n\nAlex",
              parent: "atlas-api.1")
        b.add("atlas-api.3", from: lena, to: [me], subject: "Re: Quick question about the Atlas API", date: b.daysAgo(3, 9, 10),
              text: "That did it — thank you! Our integration is live in beta now. If you ever want a demo, just say the word.\n\nLena",
              parent: "atlas-api.2")

        let allHands = DemoHTML.newsletter(
            brand: "Fieldstone", accent: "#4f46e5", background: "#f1f1f6", kicker: "All-hands recap",
            title: "Slides, recording and your questions answered",
            preheader: "Missed Thursday's all-hands? Here's the ten-minute version.",
            intro: "Thanks to everyone who joined on Thursday. Here's the short version, with links to the slides and recording on the intranet.",
            heroImagePNG: nil, heroAlt: "",
            sections: [
                .init(heading: "Highlights", body: "• Atlas crossed 40,000 weekly active teams.\n• Onboarding v2 is the top product priority for \(b.quarter(of: b.now)).\n• The \(offsiteMonth) offsite is confirmed at Millbrook Lodge."),
                .init(heading: "Your questions", body: "We ran out of time for a few questions about hybrid work and the new expense policy. Hannah has answered all of them in the FAQ — look for the \"All-hands follow-ups\" page."),
            ],
            signoff: "— Fieldstone Comms",
            footerLines: ["Internal: sent to everyone@fieldstone.example."], unsubscribe: "https://intranet.fieldstone.example/email-preferences")
        b.add("allhands-recap", from: comms, to: [EmailAddress(name: "Everyone at Fieldstone", address: "everyone@fieldstone.example")],
              subject: "All-hands recap: slides, recording and your questions answered", date: b.daysAgo(2, 17, 30),
              text: allHands.text, html: allHands.html, snippet: "Missed Thursday's all-hands? Here's the ten-minute version, with links to the slides and recording.",
              bulk: true, unsubscribe: "https://intranet.fieldstone.example/email-preferences")
    }

    // MARK: Older

    private static func addOlder(_ b: inout DemoBuilder) {
        let me = b.me

        b.add("plant-swap", from: june, to: [me], subject: "Plant swap this Sunday 🌿", date: b.daysAgo(7, 17, 50),
              text: "Hi neighbours!\n\nWe're doing a plant swap on the community garden porch this Sunday from 10 to noon. Bring cuttings, seedlings, pots you don't need — or just come for coffee. I'll have far too many pothos starts.\n\nJune (#2B)")

        let bookClubDate = b.daysAgo(8, 19, 20)
        let pickMonth = b.month(1, from: bookClubDate)
        let meeting = b.weekday(1, number: 3, monthsAfter: 1, from: bookClubDate)
        b.add("book-club-nov", from: grace, to: [me, sam, nina], subject: "Book club: \(pickMonth) pick 📚", date: bookClubDate,
              text: """
              Hi book people,

              Thanks for a lovely discussion last week! For \(pickMonth) we're reading Small Hours at the Saltwater Inn by Ida Marchetti — it's short, so no excuses.

              We'll meet Sunday the \(b.dayOrdinal(meeting)) at my place, 4pm. I'll make the chai; someone else please bring snacks.

              Grace
              """)

        b.add("library-hold", from: library, to: [me], subject: "Your hold is ready for pickup", date: b.daysAgo(9, 10, 0),
              text: """
              Hello Alex Rivera,

              The following item is ready for pickup at Pinecrest Library — Main Branch:

              The Quiet Grid: Cities After Cars (book)

              It will be held for you until \(b.format(b.daysAgo(2, 20, 0), "EEEE, MMMM d")). Library hours are Monday to Saturday 9am–8pm and Sunday noon–5pm.
              """, bulk: true)

        let margin111 = DemoHTML.newsletter(
            brand: "The Margin", accent: "#c2410c", background: "#f4efe6", kicker: "Issue 111",
            title: "The case for boring technology",
            preheader: "Innovation tokens, and why you should spend them on your product, not your stack.",
            intro: "Every team gets a few innovation tokens. Spend them on what makes your product different — and pick proven, slightly boring tools for everything else.",
            heroImagePNG: nil, heroAlt: "",
            sections: [
                .init(heading: "What boring buys you", body: "Known failure modes, searchable answers and teammates who already know the tool. None of that shows up in a benchmark, all of it shows up at 2am."),
                .init(heading: "When to break the rule", body: "When the boring option genuinely can't do the job — and you've written down why, so the next person doesn't have to rediscover it."),
            ],
            signoff: "Until next week,\nRosa Kim, editor",
            footerLines: ["The Margin is a weekly letter about how good teams work."], unsubscribe: "https://themargin.example/unsubscribe/af31c9")
        b.add("margin-111", from: margin, to: [me], subject: "Issue 111: The case for boring technology", date: b.daysAgo(9, 7, 30),
              text: margin111.text, html: margin111.html, snippet: "Innovation tokens, and why you should spend them on your product, not your stack.",
              bulk: true, unsubscribe: "https://themargin.example/unsubscribe/af31c9")

        let accepted = b.daysAgo(10, 16, 0)
        let summitYear = (Int(b.format(accepted, "yyyy")) ?? 2026) + 1
        b.add("northstar-accepted", from: northstar, to: [me], subject: "Your talk was accepted 🎉", date: accepted,
              text: """
              Hi Alex,

              Congratulations! Your talk, "Designing for the second week", has been accepted for Northstar Dev Summit \(summitYear) in Portland.

              Next steps:
              1. Confirm your slot by replying to this email (we've pencilled you in for day 2 at 11:30).
              2. Send a headshot and a two-sentence bio by \(b.format(b.thirtieth(monthAfter: accepted), "MMMM d")).
              3. Book travel — speakers get two hotel nights at the Riverside.

              We're thrilled to have you.

              The Northstar programme committee
              """, flagged: true)

        let cookingSeason = b.season(of: b.daysAgo(11, 9, 0))
        let saltgrassIssue = DemoHTML.newsletter(
            brand: "Saltgrass Kitchen", accent: "#b45309", background: "#faf3e8", kicker: "The Weekend Table",
            title: "Three one-pan \(cookingSeason) dinners",
            preheader: "Roast squash with chickpeas, a sheet-pan gnocchi and the easiest apple crumble.",
            intro: "Fewer dishes, more evening. This week's recipes each use one pan and about forty minutes, most of them hands-off.",
            heroImagePNG: DemoAssets.landscapePNG(width: 240, height: 100, palette: DemoAssets.meadow),
            heroAlt: "Illustration: golden \(cookingSeason) hills",
            sections: [
                .init(heading: "Roast squash, chickpeas and crispy sage", body: "Toss cubed squash and chickpeas with olive oil, smoked paprika and salt. Roast at 220°C for 30 minutes, add sage leaves for the last five, and finish with a spoonful of yoghurt."),
                .init(heading: "Sheet-pan gnocchi with tomatoes", body: "Shop-bought gnocchi goes straight onto the tray with cherry tomatoes, garlic and a red onion. Twenty-five minutes later: crisp edges, jammy tomatoes, dinner."),
                .init(heading: "The easiest apple crumble", body: "Slice four apples into a baking dish, rub butter into flour, oats and brown sugar, scatter on top and bake for 35 minutes. Custard optional, but encouraged."),
            ],
            signoff: "Happy cooking,\nAnnika at Saltgrass",
            footerLines: ["Saltgrass Kitchen · recipes for ordinary weeknights"], unsubscribe: "https://saltgrass.example/unsubscribe")
        b.add("saltgrass-weekend", from: saltgrass, to: [me], subject: "The Weekend Table: three one-pan \(cookingSeason) dinners", date: b.daysAgo(11, 9, 0),
              text: saltgrassIssue.text, html: saltgrassIssue.html, snippet: "Roast squash with chickpeas, a sheet-pan gnocchi and the easiest apple crumble.",
              bulk: true, unsubscribe: "https://saltgrass.example/unsubscribe")

        b.add("atlas-release-320", from: forgelineBot, to: [me], subject: "[fieldstone/atlas] Release v3.2.0", date: b.daysAgo(12, 18, 0),
              text: """
              fieldstone/atlas v3.2.0 has been released.

              Highlights
              • Faster project list: first paint is 40% quicker on large workspaces.
              • Shared projects now appear in /v2/projects with ?scope=all.
              • Fixed: comments occasionally lost their author avatar.

              View the full release notes on Forgeline.
              """, bulk: true, unsubscribe: "https://forgeline.example/notifications/unsubscribe/releases")

        b.add("ridgeway-service", from: ridgeway, to: [me], subject: "Reminder: your 30,000-mile service is due", date: b.daysAgo(13, 11, 0),
              text: "Hi Alex,\n\nOur records show your Corsa hatchback is due for its 30,000-mile service. It takes about two hours and includes an oil change, tyre rotation and brake inspection.\n\nBook online or call us at (555) 014-2290.\n\nRidgeway Motors service team",
              bulk: true, unsubscribe: "https://ridgewaymotors.example/unsubscribe")

        b.add("review-guidelines.1", from: marcus, to: [me], subject: "Code review guidelines v2", date: b.daysAgo(15, 10, 0),
              text: """
              Hey Alex,

              I've been drafting v2 of our code review guidelines and want a design perspective on the UI review part.

              Specifically: should designers be required reviewers on any PR that touches a screen, or only when the PR is labelled "ui"? The draft is in the eng handbook under "Reviews".

              Marcus
              """, answered: true)
        b.add("review-guidelines.2", folder: "Sent", from: me, to: [marcus], subject: "Re: Code review guidelines v2", date: b.daysAgo(14, 9, 30),
              text: "Labelled \"ui\" only, please — required reviewers on every screen change would slow you down, and we'd end up rubber-stamping most of them.\n\nWhat would help more: screenshots or a short screen recording in the PR description for anything visual. Happy to write that section if you like.\n\nAlex",
              parent: "review-guidelines.1")
        b.add("review-guidelines.3", from: marcus, to: [me], subject: "Re: Code review guidelines v2", date: b.daysAgo(14, 13, 45),
              text: "Perfect, that's what I hoped you'd say. I've added the screenshot requirement and credited you in the changelog. 😄\n\nShipping v2 on Monday.\n\nM.",
              parent: "review-guidelines.2")

        let billMonth = b.month(0, from: b.daysAgo(16, 6, 0))
        b.add("clearwater-autopay", from: clearwater, to: [me], subject: "Autopay scheduled for your \(billMonth) bill", date: b.daysAgo(16, 6, 0),
              text: "Hi Alex,\n\nYour \(billMonth) bill of $96.40 will be paid automatically on \(b.format(b.daysAgo(9, 9, 0), "MMMM d")) from your account ending in 0381.\n\nUsage this period: 412 kWh electricity, 3,900 gallons water.\n\nClearwater Utilities",
              bulk: true)

        let rota = b.daysAgo(18, 18, 30)
        let rotaMonth = b.month(1, from: rota)
        let shifts = [1, 3].map { b.dayOrdinal(b.weekday(7, number: $0, monthsAfter: 1, from: rota)) }
        let deliveryRun = b.dayOrdinal(b.weekday(4, number: 4, monthsAfter: 1, from: rota))
        let holiday = [11, 12].contains(b.calendar.component(.month, from: b.firstOfMonth(1, from: rota))) ? "holiday " : ""
        b.add("food-bank-nov", from: omar, to: [me], subject: "Volunteer schedule for \(rotaMonth)", date: rota,
              text: """
              Hi volunteers,

              The \(rotaMonth) schedule is up! You're down for Saturday morning shifts (9–12) on the \(shifts[0]) and \(shifts[1]), packing produce boxes. If either date doesn't work, reply and I'll find a swap.

              We're also short two drivers for the \(holiday)delivery run on the \(deliveryRun) — if you have a car and a free afternoon, it would mean a lot.

              Thank you for everything you do,
              Omar
              Riverbend Food Bank
              """)

        let referred = b.daysAgo(19, 11, 10)
        b.add("referral-thanks", from: maya, to: [me], subject: "Thanks for the referral!", date: referred,
              text: "Hi Alex,\n\nJust wanted to let you know your referral, Rosa Lindgren, accepted our offer for Senior iOS Engineer! She starts on \(b.format(b.thirtieth(monthAfter: referred), "MMMM d")).\n\nThe referral bonus will be in your \(b.month(2, from: referred)) paycheck. Thank you for sending such a great candidate our way.\n\nMaya\nPeople Team")

        let checkIn = b.daysAhead(17, 15, 0)
        let checkOut = b.daysAhead(25, 11, 0)
        let booking = DemoHTML.card(
            brand: "Wayfarer Stays", accent: "#0e7490", title: "Your stay at Casa Azulejo is confirmed",
            preheader: "Lisbon · \(b.format(checkIn, "MMM d")) – \(b.format(checkOut, "MMM d")) · 8 nights",
            intro: "Pack your bags, Alex! Your host Inês is looking forward to welcoming you.",
            details: [
                .init(heading: "Reservation", rows: [
                    ("Property", "Casa Azulejo — Alfama, Lisbon"), ("Check-in", "\(b.format(checkIn, "EEE, MMM d")) from 3:00 PM"),
                    ("Check-out", "\(b.format(checkOut, "EEE, MMM d")) by 11:00 AM"), ("Guests", "2 adults"), ("Confirmation", "WS-9921-LX"),
                ]),
                .init(heading: "Payment", rows: [("8 nights", "€1,016.00"), ("Cleaning fee", "€45.00"), ("Total paid", "€1,061.00")]),
            ],
            action: (title: "View reservation", url: "https://wayfarerstays.example/trips/WS-9921-LX"),
            outro: "Free cancellation until 7 days before check-in.",
            footerLines: ["Wayfarer Stays · This message is about your reservation."], unsubscribe: nil)
        b.add("wayfarer-booking", from: wayfarer, to: [me], subject: "Booking confirmed: Casa Azulejo, Lisbon", date: b.daysAgo(20, 21, 15),
              text: booking.text, html: booking.html,
              snippet: "Your stay at Casa Azulejo is confirmed. Lisbon · \(b.format(checkIn, "MMM d")) – \(b.format(checkOut, "MMM d")) · 8 nights · Confirmation WS-9921-LX")

        b.add("expense-policy", from: hannah, to: [EmailAddress(name: "Everyone at Fieldstone", address: "everyone@fieldstone.example")], cc: [me],
              subject: "Updated expense policy (effective \(b.month(2, from: b.daysAgo(22, 14, 0))) 1)", date: b.daysAgo(22, 14, 0),
              text: "Hi everyone,\n\nQuick heads-up: from \(b.month(2, from: b.daysAgo(22, 14, 0))) 1, rides under $60 and meals under $25 no longer need a receipt — just a note in the expense tool. Everything else works as before.\n\nThe full policy is on the intranet under People → Expenses. Shout if anything's unclear.\n\nHannah")

        b.add("portfolio-feedback", from: jordan, to: [me], subject: "Portfolio review feedback", date: b.daysAgo(25, 16, 20),
              text: """
              Hi Alex,

              Thanks again for walking me through your portfolio refresh. Overall it's strong, and the wayfinding case study is the standout.

              A few notes:
              • Lead with the problem, not the process — the first screen of each case study should say what changed for people.
              • The onboarding project needs one before/after comparison. It's the most persuasive thing you have.
              • Cut the icon exploration page; it's lovely, but it dilutes the story.

              Happy to look again when you've had a pass at it.

              Jordan
              """)

        b.add("brightloom-welcome", from: brightloomTeam, to: [me], subject: "Welcome to Brightloom — three tips to get started", date: b.daysAgo(30, 9, 0),
              text: "Welcome aboard, Alex!\n\n1. Press ⌘K anywhere to jump to a note.\n2. Type /today to start a daily page.\n3. Drag any note onto another to link them.\n\nWe're glad you're here.\nThe Brightloom team",
              bulk: true, unsubscribe: "https://brightloom.example/email-preferences")

        b.add("climbing-pass", from: theo, to: [me], subject: "Climbing gym membership split?", date: b.daysAgo(35, 12, 40),
              text: "Want to split a 10-visit pass at Basecamp? It's $160 for ten, so we'd each get five sessions for $80 — way cheaper than drop-ins.\n\nI can pick it up this weekend.\n\nT")
    }

    // MARK: Sent, Drafts, Archive, Trash, Spam, folders

    private static func addOtherFolders(_ b: inout DemoBuilder) {
        let me = b.me

        b.add("onboarding-brief", folder: "Sent", from: me, to: [priya], subject: "Onboarding study — draft brief", date: b.daysAgo(12, 15, 30),
              text: "Hi Priya,\n\nHere's the draft brief for the onboarding study. Short version: eight sessions with people in their first two weeks, focused on where they stall between signing up and creating their second project.\n\nI'd love to start recruiting next week if this looks right to you.\n\nAlex")
        b.add("lisbon-recs", folder: "Sent", from: me, to: [theo], subject: "Lisbon recs?", date: b.daysAgo(19, 20, 45),
              text: "You were in Lisbon last spring, right? Jess and I are going in a few weeks — any favourite spots? Especially food, and anything that isn't on every top-ten list.\n\nA")

        b.add("draft-lisbon", folder: "Drafts", from: me, to: [sam], subject: "Lisbon trip ideas", date: b.yesterday(22, 10),
              text: "Hey Sam — you asked about our Lisbon plans. So far: Alfama on day one, a day trip to Sintra, and as many pastéis de nata as is reasonable. Did you and Mia ever make it to", draft: true)

        b.add("boarding-den", folder: "Archive", from: kestrel, to: [me], subject: "Your boarding pass: KX 210 Seattle → Denver", date: b.daysAgo(40, 5, 30),
              text: "Hi Alex,\n\nYou're checked in for KX 210 from Seattle to Denver. Boarding starts at 7:25 AM from gate C14. Seat 12F.\n\nHave a great flight!\nKestrel Air")
        b.add("atlas-kickoff", folder: "Archive", from: priya, to: [me, marcus], subject: "Kickoff notes: Atlas onboarding", date: b.daysAgo(28, 17, 0),
              text: "Notes from today's kickoff are in the project doc. Decisions: we're measuring week-one retention, the checklist is the first experiment, and Alex owns the research plan.\n\nThanks all — exciting one.\nPriya")
        b.add("design-guild", folder: "Archive", from: jordan, to: [me], subject: "Welcome to the Fieldstone design guild", date: b.daysAgo(50, 10, 0),
              text: "Welcome to the guild, Alex! We meet every other Wednesday for critique and coffee. The first one's an easy one — just come and listen.\n\nJordan")
        b.add("order-hp-47790", folder: "Archive", from: harborPine, to: [me], subject: "Your Harbor & Pine order #HP-47790", date: b.daysAgo(33, 8, 10),
              text: "Thanks for your order! Ridgeline Blend, whole bean, 340 g. Total $21.25. Shipping tomorrow.", bulk: true)
        let alumniDate = b.daysAgo(27, 12, 0)
        let alumniSeason = b.season(of: alumniDate)
        b.add("alumni-autumn", folder: "Archive", from: alumni, to: [me],
              subject: "Westbrook Alumni News — \(alumniSeason.prefix(1).uppercased() + alumniSeason.dropFirst()) \(b.format(alumniDate, "yyyy"))", date: alumniDate,
              text: "Homecoming highlights, a new design studio on the east campus and twelve alumni stories. Read the \(alumniSeason) issue online.",
              bulk: true, unsubscribe: "https://westbrook.example/alumni/unsubscribe")
        b.add("sylvan-tickets", folder: "Archive", from: oldMill, to: [me], subject: "Your tickets: Sylvan Strings Quartet", date: b.daysAgo(44, 19, 0),
              text: "Thank you for your purchase! 2 tickets, row F, seats 7–8. Doors open at 7pm. Show this email at the box office.")

        b.add("candle-sale", folder: "Trash", from: wickhaven, to: [me], subject: "Tonight only: 40% off every candle", date: b.daysAgo(2, 18, 0),
              text: "Our \(b.season(of: b.daysAgo(2, 18, 0))) collection is 40% off until midnight. Cedar & Smoke is back in stock.", bulk: true,
              unsubscribe: "https://wickhaven.example/unsubscribe")
        b.add("stridewise-miss", folder: "Trash", from: stridewise, to: [me], subject: "We miss you! You haven't logged a run in 5 days", date: b.daysAgo(9, 7, 0),
              text: "Even a short run keeps your streak alive. Lace up!", bulk: true, unsubscribe: "https://stridewise.example/email-settings")
        b.add("pumpkin-fwd", folder: "Trash", from: ray, to: [me, nina], subject: "Fwd: Fwd: You won't believe this pumpkin", date: b.daysAgo(12, 9, 45),
              text: "Saw this and thought of you two. 1,800 pounds!! Uncle Ray")

        b.add("spam-giftcard", folder: "Junk", from: spamRewards, to: [me], subject: "Congratulations! You've been selected for a $750 gift card", date: b.yesterday(3, 12),
              text: "Dear valued customer, you have been selected to receive a $750 gift card. Click here to claim within 24 hours.", unread: true, bulk: true)
        b.add("spam-mailbox", folder: "Junk", from: spamAdmin, to: [me], subject: "Action required: your mailbox is almost full", date: b.daysAgo(3, 4, 40),
              text: "Your mailbox has reached 98% of its quota. Verify your account now to avoid losing incoming messages.", unread: true, bulk: true)
        b.add("spam-watches", folder: "Junk", from: spamWatches, to: [me], subject: "Exclusive: 92% off luxury watches — today only", date: b.daysAgo(6, 2, 15),
              text: "Top brands at unbelievable prices. Limited stock!", bulk: true)

        b.add("cloudberry-sep", folder: "Receipts", from: cloudberry, to: [me], subject: "Your receipt from Cloudberry Music", date: b.daysAgo(34, 6, 15),
              text: "Cloudberry Family, monthly — $16.99 + $1.44 tax. Total $18.43. Receipt CB-2209-77102.", bulk: true)
        b.add("clearwater-sep", folder: "Receipts", from: clearwater, to: [me], subject: "Your \(b.month(0, from: b.daysAgo(38, 6, 0))) bill is ready", date: b.daysAgo(38, 6, 0),
              text: "Your \(b.month(0, from: b.daysAgo(38, 6, 0))) bill is $88.15 and will be paid automatically on the 3rd.", bulk: true)
        b.add("kestrel-receipt", folder: "Travel", from: kestrel, to: [me], subject: "Receipt for your purchase: Lisbon round trip", date: b.daysAgo(21, 20, 5),
              text: "Thank you for flying Kestrel Air. 2 passengers, Seattle ⇄ Lisbon. Total charged: $1,486.20. Confirmation XK7Q2M.")
        b.add("rail-portland", folder: "Travel", from: rail, to: [me], subject: "Ticket confirmation: Seattle → Portland", date: b.daysAgo(60, 13, 30),
              text: "Your Ridgeline Rail ticket is confirmed. Train 507, departs King Street Station 8:20 AM, coach 3, seat 14A.")
    }
}
