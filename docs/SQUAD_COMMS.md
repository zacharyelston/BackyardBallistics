# Squad comms: credentials, LoRa and a standalone squad app

Status: design, not built. This doc proposes three changes to how squads link up, and the order to
build them in:

1. **Member credentials instead of a single join code**, so a squad's links survive app crashes,
   relaunches and code changes, and a reset means something precise.
2. **A second, long-range link over LoRa**, for when the squad is out of Wi-Fi range of its leader.
3. **A standalone squad app** built on a generic squad layer, for ski-touring parties and search and
   rescue (SAR) teams as well as SpudGunGolf.

Read [GROUP_PLAY.md](GROUP_PLAY.md) (v3 Squadz) and [THEATER_MODE.md](THEATER_MODE.md) (v4) first.
This doc uses their roles, their transport and their safety rules, and changes none of the safety
rules.

## Contents

1. [Where things stand](#where-things-stand)
2. [Safety rules that don't change](#safety-rules-that-dont-change)
3. [Part 1: member credentials](#part-1-member-credentials)
4. [Part 2: a long-range link over LoRa](#part-2-a-long-range-link-over-lora)
5. [Part 3: a standalone squad app](#part-3-a-standalone-squad-app)
6. [Recommended order of work](#recommended-order-of-work)
7. [Open questions](#open-questions)

## Where things stand

- **One code does everything.** A squad leader's iPad makes a 6-character `JoinCode`
  (`GroupKit/Messages.swift`). The TLS pre-shared key is an HMAC of that code
  (`NWParameters.groupLink(joinCode:)` in `GroupLink/GroupLink.swift`), and every `Hello` carries
  the code again, which `SquadHost.join` compares. The same code admits a new phone, keeps an
  existing phone connected, and admits a Theater station (`Hello.Role.observer`). The Theater door
  has its own code for phones that send it fields, notes and files (`Hello.Role.contributor`).
- **Identity is the device UUID.** A phone keeps a UUID in `UserDefaults`
  (`SquadMembership.deviceID`), and `SquadHost.join` maps it back to the same `MemberID` on a
  rejoin. Anyone who knows the code and a member's device UUID can rejoin as that member.
- **Recovery depends on the code.** The iPad saves its round and code to a file
  (`SquadCommand.Saved`) and readvertises on relaunch. A phone that crashes needs the code typed
  or scanned again. A separate change has phones and the Theater remember codes locally; that fixes
  crashes but not resets.
- **"New code" strands everyone.** Changing the code changes the TLS key, so every enrolled phone
  fails the handshake and has to be given the new code. There is no way to remove one person except
  by changing the code for everyone.
- **One transport.** Bonjour plus TCP with TLS, on home Wi-Fi or peer-to-peer Wi-Fi: tens of metres
  in a yard, less through terrain or trees.

## Safety rules that don't change

These are the rules in [GROUP_PLAY.md, Safety](GROUP_PLAY.md#safety) and
[THEATER_MODE.md, Safety](THEATER_MODE.md#safety). Restated here because the changes below add
transports and a second app, and each of them must keep the rules:

1. **Firing data never leaves the commander's iPad.** A solution reaches a screen only through
   `Safety.clearSolution` and then `GroupGate` (`SquadHost.firingDisplay`), on the commander's iPad.
   `Cleared` isn't `Codable`. No message, on any transport, carries a solution, a charge, an
   elevation, an aim or a `Cleared` value.
2. **Firing data never goes over LoRa.** The LoRa codec in Part 2 is a closed list of message types,
   and none of them has a field that could hold firing data. The golf layer may send only check fire,
   cease fire (walking out), presence and coarse positions over LoRa. A test pins this list.
3. **Holds only add.** A message over LoRa can raise a hold (check fire, walking out, a member in the
   fan). Nothing over LoRa can lift a hold or confirm downrange.
4. **Silence is not clear.** Losing the LoRa link, or a LoRa position, never counts as "no one in the
   fan". A position heard only over LoRa can raise `memberInFan`, but it is too coarse and too old to
   clear `positionUnknown`; only a recent position over the local link does that.
5. **The standalone squad app has no firing code at all.** It doesn't link SafetyKit, RoundKit's
   firing paths or `GroupGate`. It can't show a solution because it has none to show.

## Part 1: member credentials

### The proposal

The join code becomes an **enrolment code only**: it lets a new device in once. In the `Welcome`, the
leader's device hands that device a **long-lived member credential**, which the device keeps in its
Keychain. From then on, the device connects with its credential, not the code.

| | Today | Proposed |
| --- | --- | --- |
| What a new phone needs | The join code | The enrolment code (text or QR), once |
| What an enrolled phone needs to reconnect | The join code, every time | Its credential, from the Keychain |
| TLS key | HMAC of the join code | Per member: a key derived from the member's credential. For enrolment: a key derived from the enrolment code |
| Who a sender is | The connection; the member is looked up by device UUID | The connection; the member is the credential the TLS handshake used |
| "New code" | Everyone has to re-join | New phones need the new code; enrolled phones aren't affected |
| Removing one person | Not possible | Revoke their credential |
| Real reset | Not possible without re-joining everyone | Revoke members, or start a new squad key |

### What a credential is

```swift
/// Issued by the squad leader's device in the `Welcome`. Kept in the Keychain.
public struct MemberCredential: Codable, Sendable {
    public var squad: SquadID
    public var member: MemberID
    /// Public, sent in the clear as the TLS PSK identity. Random, 16 bytes.
    public var credentialID: Data
    /// Secret, 32 bytes. Never sent again after the Welcome.
    public var secret: SymmetricKey
    /// What the holder may do: member, observer (Theater), contributor (Theater door).
    public var role: CredentialRole
    /// Squad key epoch the secret was issued under (see Revocation).
    public var epoch: Int
    public var issued: Date
}
```

- **The leader derives secrets; it doesn't store them.** The leader's iPad keeps one 32-byte squad
  root key in its Keychain. A member's secret is `HKDF-SHA256(squadRoot, salt: squadID,
  info: "member" + credentialID + epoch)`. The roster stores only credential IDs, roles and a revoked
  flag, so `SquadCommand.Saved` (the file the round is saved in) holds no secrets.
- **The device keeps it with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.** That lets it
  reconnect in the background after the phone is first unlocked, and keeps it out of iCloud backups
  and off other devices. A new phone enrols again.
- **One credential per squad.** A phone can belong to several squads; it keeps one Keychain item per
  `SquadID`.

### The handshake

TLS with pre-shared keys already lets a client name which key it is using (the PSK identity), and lets
the server pick the key by that name (`sec_protocol_options_set_pre_shared_key_selection_block` on the
listener's options).

- **Enrolling.** The phone uses identity `enrol` and a key derived from the enrolment code, as today.
  The `Hello` carries the device's name and UUID, and no longer needs the code as a field (the TLS
  key already proved it). `SquadHost` adds the member and answers with
  `Welcome(member:, squad:, credential:)`. The phone saves the credential, then closes and reconnects
  with it, so every later session runs under the member key.
- **Reconnecting.** The phone uses its credential ID as the identity and its secret as the key. The
  leader's selection block looks the ID up in the roster: unknown or revoked returns no key, and the
  handshake fails. A good handshake *is* the authentication, and `SquadHost` takes the member and role
  from the credential, not from anything in the `Hello`.
- **Enrolment-only sessions are limited.** A connection on the `enrol` identity can send `Hello` and
  nothing else, and is closed after the `Welcome`.
- **The Bonjour TXT record carries a short squad tag** (the first 4 bytes of a hash of the
  `SquadID`), so a phone finds its squad again even if the leader renames it.

The enrolment code stays short because people type it. A 6-character code from a 31-letter alphabet
is about 30 bits, so a recorded enrolment handshake could be guessed offline. That matters much less
once the code only enrols: it can expire (say 15 minutes, or when the leader closes enrolment) and
the leader sees every new member join. A password-authenticated key exchange (PAKE) would close the
gap entirely; see [Open questions](#open-questions).

### Crash recovery

| What crashed | What happens |
| --- | --- |
| A member's phone | On relaunch it reads its credentials and rejoins each squad it was in, with no code. `GroupClient`'s existing retry loop is unchanged; only the key it uses changes |
| The leader's iPad | On relaunch it reads the squad root key from the Keychain and the round and roster from `SquadCommand.Saved`, readvertises, and accepts every enrolled member's credential. Members see "Reconnecting" and then carry on |
| The Theater | Same as a member: it reconnects to each squad it observes with its observer credential, and its door keeps accepting contributor credentials |
| The leader's iPad is lost or wiped | Its squad root key is gone, so its credentials can't be checked. Members re-enrol with a new leader device. Handing a squad to another device is an [open question](#open-questions) |

The change that makes phones and the Theater remember codes locally keeps working until this lands.
After it, devices remember credentials, and codes go back to being short-lived.

### Revocation and resets

Three leader actions, named for what they do:

- **New enrolment code.** Replaces the code. Enrolled members are unaffected. Pending enrolments with
  the old code fail. Use it when the code was shown to the wrong people.
- **Remove member.** Marks that credential revoked, closes its connection, and refuses its next
  handshake. It also bumps the **squad epoch**, which re-keys the LoRa channel (Part 2): the leader
  sends each remaining member the new epoch key over its own link, so the removed device can't read
  or send on the squad's LoRa channel either. The removed member's history (positions, notes) stays
  in the log, marked as from a removed member.
- **Reset squad.** A new squad root key and a new enrolment code. Every credential is invalid, and
  everyone enrols again. This is the "real reset", and the confirmation says so.

Today's "remove member" (`SquadHost.removeMember`) only takes a member off the roster; it doesn't keep
the phone out. It becomes the first half of the new action.

### The Theater

- **Observer (`.observer`).** A Theater station enrols with a squad once, the same way a phone does,
  and gets a credential with role `observer`. The squad host enforces the role from the credential:
  an observer credential gets status, positions, orders and notes, and anything it sends that the
  squad would act on is ignored, as today. A leader can revoke the Theater like any member.
- **The Theater door (`.contributor`).** The Theater is the host here. Its door code becomes its
  enrolment code; a phone that sends something to the Theater enrols once and gets a contributor
  credential, so it can send again later without the code. The owner sees the list of contributor
  devices and can revoke one. **New code** on the door no longer locks out phones that already
  enrolled.
- **Course-level check fire** still comes from the Theater only, and holds still only add
  ([THEATER_MODE.md, Safety](THEATER_MODE.md#safety)).

### Compared with a rotating list of codes

The other idea was a rotating list of codes: the leader keeps several valid codes, retires the oldest
on a schedule, and phones learn the next one while they're connected.

| | Rotating list of codes | Per-member credentials |
| --- | --- | --- |
| Crash recovery | Works if the phone saved a code that is still valid | Works; credentials don't expire on a schedule |
| A member out of range during a rotation | Stranded once their codes age out: the problem this was meant to fix | Unaffected |
| Removing one person | Not possible: every code is shared by everyone | Revoke their credential |
| Strength | Short shared codes as TLS keys, so offline guessing of any recorded session | 256-bit keys after enrolment |
| Deriving the next code from a shared seed (like an authenticator app) | The seed becomes the real long-lived secret, and it's shared, so removing one person still means re-seeding everyone | — |
| Complexity | Clock or schedule agreement, grace windows | One more Keychain item and a key-selection callback |

The part worth keeping is **several codes at once**: the leader can issue **single-use invite codes**,
one per person, each revocable before it's used. That fits a SAR callout, where people arrive at
different times. It slots into the credential design as a set of enrolment codes, not a replacement
for it.

### Protocol changes

`GroupProtocol.version` goes from 6 to 7, and devices on v6 are refused (fail closed, as now).
`Hello.joinCode` goes; `Welcome` gains `credential`; `Hello.role` becomes a request that the
credential's role overrides.

## Part 2: a long-range link over LoRa

### Why, and what it can't do

A squad spread over a ridge, a ski tour, or a SAR sector is out of Wi-Fi range of its leader most of
the time. LoRa radios reach kilometres in open terrain, need no infrastructure, and run for days on a
small battery. They also carry very little: a few hundred bytes per packet, a packet every few
seconds at best across a whole channel. So LoRa is a **second link for small, important messages**,
not a replacement for Wi-Fi.

### Hardware and firmware

Use off-the-shelf radios running the open-source **Meshtastic** firmware, paired to the phone over
Bluetooth LE:

| Radio | Notes |
| --- | --- |
| RAK WisBlock (RAK4631) | nRF52, low power; GPS and battery as add-on modules. A good default |
| LILYGO T-Beam | ESP32 with built-in GPS and an 18650 holder. Heavier, more power-hungry, easy to get |
| Heltec LoRa 32 / Wireless Tracker | Cheap; some models have no GPS |

Why Meshtastic rather than our own firmware: it already does the mesh (managed flooding with a hop
limit), region settings and duty-cycle limits, channel encryption, and a documented BLE API. Its
packets carry a **port number**, and ports from 256 up are reserved for private apps, so our messages
ride the same mesh without touching anyone else's traffic. Radios that aren't in the squad still
relay our packets, which extends range.

How the app talks to the radio:

- **BLE, using Meshtastic's protobuf API** (to-radio and from-radio characteristics). The app sends
  `MeshPacket`s on our private port, and receives packets on that port from the radio.
- **The app configures the radio's channel** from the squad credential: name, pre-shared key and
  region, pushed over BLE on pairing and on every epoch change.
- **A radio with its own GPS keeps beaconing when the phone is dead, asleep or killed.** Meshtastic's
  own position packets (on its standard position port) carry that; the app reads them as a fallback
  position for the member.

### The budget

**Bytes.** A Meshtastic packet holds about 230 bytes of payload after its own header. Our messages
aim for **under 100 bytes** so they stay short on air. Every message on our port has:

| Field | Bytes |
| --- | --- |
| Magic and codec version | 1 |
| Message type | 1 |
| Squad tag | 2 |
| Sender (index in the roster) | 1 |
| Message ID (per sender, wraps) | 3 |
| Authentication tag (ChaCha20-Poly1305) | 16 |
| **Overhead** | **24** |

Meshtastic encrypts channel traffic, but with AES-CTR and no authentication tag, so it hides the
contents and doesn't prove who sent them. We seal our payload ourselves with an AEAD keyed from the
squad credential, and treat Meshtastic's channel encryption as a second layer.

**Airtime.** Time on air for whole packets (our message, plus about 21 bytes of Meshtastic header and
wrapping), at two Meshtastic presets, with the slowest LoRa setting for comparison:

| Message | Our bytes | LongFast (SF11, 250 kHz) | MediumFast (SF9, 250 kHz) | SF12, 125 kHz, CR 4/8 |
| --- | --- | --- | --- | --- |
| Check fire / cease fire (golf) | 26 | 0.6 s | 0.17 s | 3.5 s |
| Presence (battery, status) | 28 | 0.6 s | 0.18 s | 3.5 s |
| Ack | 28 | 0.6 s | 0.18 s | 3.5 s |
| Compact position | 38 | 0.7 s | 0.2 s | 4.1 s |
| Check-in with position | 40 | 0.7 s | 0.2 s | 4.3 s |
| Epoch re-key (to one member) | 60 | 0.85 s | 0.25 s | 5.4 s |
| SOS (position, kind, 40-char text) | 79 | 1.0 s | 0.3 s | 6.2 s |
| Short order (60-char text, place, recipients) | 95 | 1.1 s | 0.3 s | 7.2 s |
| A full packet | 200 | 1.9 s | 0.6 s | 12.7 s |

Every relay sends the packet again. With a hop limit of 3, budget up to 3 transmissions per message
on the channel.

**Rules.** These are a summary for design, not legal advice; check the rules where you operate and
keep the radios on the right region setting.

| | US 915 MHz (902–928) | EU 868 MHz (Meshtastic's 869.4–869.65 MHz band) |
| --- | --- | --- |
| Duty cycle | None under the US rules for this band | **10%** per device: 360 s of transmitting per hour |
| Dwell time | Frequency-hopping devices are limited to 400 ms per channel; LoRaWAN keeps US uplinks under 400 ms for this reason. Meshtastic doesn't hop. Prefer presets that keep our packets short (MediumFast keeps most messages under 400 ms) | No per-packet limit beyond the duty cycle |
| Power | Up to 1 W conducted, less with high-gain antennas | Up to 500 mW ERP in this band |

**The real limit is the shared channel, not the rules.** Every radio on the preset shares one channel,
and Meshtastic backs off when the channel gets busy. Keep our traffic to a few percent of airtime.

Worked example, LongFast, eight members, each message sent up to three times across the mesh:

| Position interval | Channel airtime per hour | Share of the channel |
| --- | --- | --- |
| Every 30 s | 8 × 120 × 0.7 s × 3 ≈ 2,000 s | 56%: far too much |
| Every 2 min | 8 × 30 × 0.7 s × 3 ≈ 500 s | 14%: too much with other traffic |
| Every 5 min | 8 × 12 × 0.7 s × 3 ≈ 200 s | 6%: about right |
| Every 5 min, or on 200 m moved | Somewhat more when moving, much less when still | The default |

In the EU, each radio's share in that last row is about 8 s per hour for its own positions, and at
most about 70 s counting every packet it relays for the others: well inside 360 s. The leader sends
more (orders, acks, re-keys), and still stays inside it.

**So LoRa positions are minutes apart.** Wi-Fi keeps doing the fast updates when it's in range, and
the app shows how old each position is and which link it came on.

### What goes over LoRa

The exact byte layouts, the instruction codebook and the retry rules are in
[LORA_MESSAGES.md](LORA_MESSAGES.md).

| Fits | Doesn't fit |
| --- | --- |
| Compact positions (integer degrees × 10⁷, altitude, accuracy, heading, age) | Photos, capture bundles, meshes |
| Presence (battery, which links are up) | Files, field submissions, courses |
| Short orders (kind, recipients as a roster bitmask, up to 60 characters, an optional place) | Squad status with round summaries |
| Acks | Field notes longer than a short order |
| Check-in and overdue | Breadcrumb tracks (only the latest point; the track syncs over Wi-Fi) |
| SOS, SOS ack, SOS cancel | Anything the golf layer sends except the four messages below |
| Epoch re-key, sealed to one member | Firing data of any kind. Never |
| Golf only: check fire, cease fire (walking out), presence, coarse position | |

### A `Transport` seam under `GroupLink`

Today `GroupClient` and `GroupHost` are the transport. Put a seam under them so the squad layer sends
messages and a router decides which links carry them:

```swift
public enum LinkKind: Sendable { case lan, lora, loopback }

/// What a message is worth, which decides the links it may use.
public enum Priority: Int, Comparable, Sendable {
    /// SOS, check fire, cease fire: every link, repeated until acknowledged.
    case emergency
    /// Orders, acks, check-ins, re-keys: the best link up; LoRa if the LAN is down.
    case control
    /// Positions, presence: LAN at full rate; LoRa at the budgeted rate.
    case routine
    /// Notes, files, tracks, status: LAN only, queued until it's up.
    case bulk
}

public struct LinkCapabilities: Sendable {
    public var maxPayload: Int           // 1 MiB on the LAN, ~200 bytes on LoRa
    public var reliable: Bool            // TCP yes, LoRa no
    public var budget: AirtimeBudget?    // nil on the LAN
}

public protocol Transport: AnyObject {
    var kind: LinkKind { get }
    var capabilities: LinkCapabilities { get }
    var isUp: Bool { get }
    var onReceive: ((Envelope, LinkKind) -> Void)? { get set }
    func send(_ envelope: Envelope, to: Destination) -> SendResult  // queued, tooLarge, overBudget, down
}
```

- **`LanTransport`** wraps today's `GroupHost` and `GroupClient`. **`LoopbackTransport`** wraps
  `Loopback.swift` for tests. **`MeshtasticTransport`** speaks BLE to the radio and owns the compact
  codec.
- **`LinkRouter`** sits above them. It picks links by priority, keeps an outgoing queue per link,
  holds LoRa to its airtime budget, and repeats emergency messages with backoff until they're acked.
- **Every message gets an ID**: the sender's member index and a counter, so it fits the 3-byte LoRa
  field. The envelope's `seq` stays for the TCP stream. Receivers keep a window of recently seen
  `(sender, id)` pairs and drop repeats, so a message that arrives on both links, or through two
  relays, is handled once. Acks name the message ID and may come back on either link.
- **Who sent it.** On the LAN the sender is the connection, as now. On LoRa there is no connection,
  so the sender is whoever holds the key that sealed it:
  - **Member to leader:** sealed with that member's own key (derived from its credential). The leader
    knows who sent it, as on the LAN.
  - **Leader to members, and member broadcasts (SOS, check fire):** sealed with the squad's epoch key.
    That proves "someone in the squad", not which member. For check fire and SOS that's acceptable:
    both only add caution, and an SOS shows its claimed sender and position for people to judge.
    Signing SOS with a per-member Ed25519 key (64 bytes more) is possible if that isn't enough.
- **Keys.** All derived with HKDF from the squad root and epoch, so nothing new to distribute:
  the Meshtastic channel PSK (`info: "lora/channel"`), the squad epoch key (`"lora/group"`), and
  each member's LoRa key (`"lora/member" + credentialID`). Removing a member bumps the epoch and
  re-keys everyone else (Part 1).

### TAK: interoperate, don't compete

Many SAR teams already use TAK (ATAK on Android, iTAK on iOS, WinTAK), and Meshtastic has a TAK
integration that carries compact Cursor-on-Target position and chat messages on its own port. The
squad app shouldn't try to be a TAK client. It should be a good neighbour:

- **Read TAK positions and chat** from the mesh and show them on the map as non-squad contacts,
  labelled by callsign.
- **Optionally publish our members' positions as TAK position reports**, so a team's TAK users see the
  squad. Off by default; the leader turns it on per squad, because it shares positions with anyone on
  the channel.
- **Export to TAK** as data packages or CoT files, alongside GPX and GeoJSON (Part 3), for a base that
  runs a TAK server.
- **Don't carry our orders, check-ins or SOS as TAK messages.** They need our acks, de-duplication and
  authentication. Show a plain chat line to TAK users if the leader wants them to see it.

## Part 3: a standalone squad app

### Who it's for

- **Ski-touring parties:** four to eight people, a leader, a planned route, a turnaround time. They
  spread out on climbs and descents, go out of sight, and regroup. Weather and cold kill batteries.
- **SAR teams:** a base or incident command post, several field teams, assigned search sectors,
  check-in intervals, and a need to show where everyone has been.

Both want what Squadz already does for golf (who's here, where they are, orders and acks, notes), and
neither wants anything to do with a launcher.

### Splitting GroupKit

| Layer | Package | Contents |
| --- | --- | --- |
| **Generic squad layer** | `SquadKit` (new) | `Squad`, `Member`, `MemberID`, credentials and roles, the envelope with message IDs, `Hello` / `Welcome` / `Refused`, positions and tracks, presence, orders and acks, notes, receipts, files, check-ins, SOS, sectors. A generic host (`SquadHub`) that owns the roster and these messages. The `Transport` seam and `LinkRouter`. No golf types, and no dependency on SafetyKit, RoundKit or CourseKit |
| **Golf layer** | `GroupKit` (what's left) | `SquadHost` rounds, `HolePlay` events, locks and lock receipts, spotting and spot requests, Fired, check fire and holds, `GroupGate`, course and field submissions |
| **Transport** | `GroupLink` | The LAN transport (today's code) and, later, the Meshtastic transport |

Golf messages ride the generic layer as a **namespaced payload**:

```swift
public enum Body: Codable, Sendable {
    // generic: hello, welcome, refused, position, presence, order, orderAck, note, receipt,
    // fileOffer/Chunk/Done, checkIn, sos, sosAck, sosCancel, sector, …
    /// An app's own message. The hub passes it to the app layer registered for `namespace`,
    /// and drops it if none is (the squad app has no golf layer).
    case app(namespace: String, version: Int, payload: Data)
}
```

`SquadHost` becomes the golf app layer for namespace `spudgolf`: the generic hub hands it every
`spudgolf` message along with the sender it authenticated, and it returns outgoing messages as today.
The golf layer keeps its own safety tests, including the property test that no sequence of messages
turns a blocked verdict into an allowed one. A new test pins that the generic layer has no message
type that can carry firing data, and that the LoRa codec carries only the four golf messages allowed
over LoRa.

The squad app is a new app target that links `SquadKit` and `GroupLink` only. SpudGunGolf links both
layers and keeps working as it does now.

### Features for ski touring and SAR

| Feature | What it does | Notes |
| --- | --- | --- |
| **Offline maps** | Topographic base map downloaded for an area before the trip; slope-angle shading for avalanche terrain | Vector or raster tiles in one file per area (MBTiles or PMTiles), drawn with an open-source map renderer; check each data source's licence. MapKit doesn't offer offline areas to apps |
| **Breadcrumbs** | Each member's track, recorded on the phone and synced to the leader over Wi-Fi | Over LoRa only the latest point. The radio's own GPS fills gaps when the phone is off |
| **Check-in and overdue timers** | The leader sets an interval (say 30 or 60 minutes); a member checks in with one tap; a missed check-in becomes **overdue** on the leader's screen, then an alert | Also a personal turnaround time on each phone that alerts the member and the leader. Check-ins go on any link |
| **SOS** | Press and hold. Sends position, a kind (injury, lost, avalanche, other) and a short text on every link, repeated until acknowledged, and shows who acknowledged | Cancel needs a second hold. The phone keeps sending its position more often until cancelled |
| **Sector assignments** | The leader draws polygons or lines and assigns them to members or teams; members see theirs and their coverage | Coverage is from breadcrumbs; probability-of-detection maths is out of scope |
| **Notes and photos** | Pinned to the map, as Squadz field notes do | Photos go over Wi-Fi only |
| **Export** | GPX (tracks, waypoints) and GeoJSON (tracks, notes, sectors, check-ins with times), plus TAK packages | So a team can bring the record into the mapping tools it already uses |
| **Roles** | Leader, member, base (observer, like the Theater) | Base sees everything and can send orders if the leader allows it |

### iOS background location and battery

- **Background location** needs "Always" permission and the location background mode. Use
  `CLLocationUpdate.liveUpdates` with a background activity session (iOS 17+), so iOS keeps the app
  running while the session is active and shows the user it's tracking. Explain plainly in the
  permission text who sees the position and when.
- **If the user force-quits the app, tracking stops.** iOS doesn't relaunch an app the user swiped
  away for continuous updates. Say so in the app, and lean on the radio's own GPS beacon as the
  fallback.
- **Bluetooth in the background** needs the `bluetooth-central` background mode and Core Bluetooth
  state restoration, so the radio can wake the app for an incoming SOS or order.
- **Local network links** keep working while the app runs in the background under the location mode.
  If iOS suspends the app anyway, LoRa via the radio is the link that still gets through.
- **Battery.** Continuous GPS costs a few percent an hour, and cold costs more. Adapt the rate:
  frequent fixes while moving, a fix every few minutes while still, reduced accuracy when the squad is
  together on Wi-Fi. Report battery in presence messages, so the leader sees who is about to drop out.
  Advise keeping the phone in an inside pocket and carrying a battery pack. A radio on its own
  battery outlasts the phone by days.

### What it is not

**The squad app supplements radios and personal locator beacons. It never replaces them.** The app
says so on first launch, in its description and in the SOS screen:

- **It doesn't call for help.** SOS reaches only the squad. To reach rescue, use a PLB, a satellite
  messenger, a phone's emergency satellite feature, a voice radio, or a phone call. The SOS screen
  reminds the user to do that too.
- **It isn't an avalanche transceiver.** Everyone in avalanche terrain carries a transceiver, probe
  and shovel. Phones and LoRa radios can interfere with transceivers; keep them the distance the
  transceiver's maker says, and switch the app to its radio-quiet mode (or airplane mode) during a
  transceiver search.
- **It isn't a navigation-grade system.** Phone GPS and positions minutes old over LoRa are
  approximate. Carry a map and compass and know how to use them.
- **It sends nothing to a cloud.** Squad data stays on the squad's devices unless someone exports it.
  For SAR, that includes subject information: treat exports as sensitive.

## Recommended order of work

1. **Member credentials (protocol v6).** Keychain storage, PSK selection by credential ID, the
   credential in `Welcome`, the role taken from the credential, revoke and reset, and the Theater's
   observer and contributor credentials. Tests in GroupKit over the loopback; a field check that a
   killed app and a relaunched iPad both rejoin with no code. This fixes the crash and reset problem
   on its own and comes first.
2. **Message IDs and de-duplication** in the envelope, still on the LAN only. No behaviour change;
   needed by everything after.
3. **Split GroupKit into `SquadKit` and the golf layer**, with golf messages as a namespaced payload.
   No behaviour change; the golf safety tests move with `SquadHost` and must pass unchanged.
4. **The `Transport` seam and `LinkRouter`**, with the LAN and loopback transports only. Priorities,
   queues and acks, tested over the loopback.
5. **The LoRa codec and `MeshtasticTransport`**, with one radio first (RAK4631). Keys from the
   credential, epoch re-key on revoke, the airtime budget. The test that pins which golf messages may
   go over LoRa lands with the codec. A field test of range and airtime on LongFast and MediumFast.
6. **The standalone squad app**: offline maps, breadcrumbs, check-ins, SOS, sectors, export,
   background location. Ski touring first (smaller, simpler); SAR features (sectors, base role,
   TAK export) after.
7. **TAK interop**: read TAK positions and chat, then opt-in publishing and TAK export.

## Open questions

- **Handing a squad to another leader device.** If the leader's iPad is lost, everyone re-enrols.
  Should a squad have a co-leader device holding a copy of the squad root key (SAR would want this),
  and how is it handed over safely?
- **PAKE for enrolment.** A password-authenticated key exchange would stop offline guessing of the
  enrolment code. Is there a maintained Swift implementation worth depending on, or is a short-lived
  code enough?
- **US dwell time.** Which Meshtastic preset should be the US default for squads: LongFast for range,
  or MediumFast to keep packets under 400 ms?
- **A registered Meshtastic port.** Start on the first private port with our magic byte and squad tag
  as the filter; ask for a registered port if the app ships.
- **Squad app name and repo.** Whether the standalone app lives in this repo as a second app target
  or moves out once `SquadKit` is stable.
