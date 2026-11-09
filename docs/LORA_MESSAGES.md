# LoRa message spec

Status: design, not built. This is the wire format for the squad's long-range link, proposed in
[SQUAD_COMMS.md, Part 2](SQUAD_COMMS.md#part-2-a-long-range-link-over-lora). Read that first for why
LoRa, the radios, the airtime budget and the keys. This doc says exactly which bytes go in each packet.

## Contents

1. [Design rules](#design-rules)
2. [Packet layout](#packet-layout)
3. [Field encodings](#field-encodings)
4. [Message types](#message-types)
5. [The instruction codebook](#the-instruction-codebook)
6. [Acks and retries](#acks-and-retries)
7. [Sizes and airtime](#sizes-and-airtime)
8. [An example](#an-example)
9. [Open questions](#open-questions)

## Design rules

1. **Instructions are codes, not sentences.** A leader's instruction is a one-byte code from a shared
   codebook, plus fixed arguments (a place, a member, a time, a number). Free text is optional and
   short. A code costs 1 byte where the sentence costs 20 to 60. It reads the same in every
   receiver's language, the app can act on it (draw the place, start a timer), and nobody parses
   typing.
2. **The codebook ships in the app; it is never sent.** Both ends hold the same codebook version.
   The `Welcome` (over Wi-Fi) records which version the squad uses.
3. **Fixed layouts, no general-purpose encoding.** No JSON, no protobuf inside our payload: every type
   has a fixed byte layout, with at most one length-prefixed text field at the end. A receiver
   rejects a packet whose length doesn't match its type.
4. **Positions are small.** Within a squad, a position is metres east and north of a shared reference
   point (the squad's **datum**) in 4 bytes. Positions anyone outside the squad may see (SOS) are
   absolute, in 8 bytes.
5. **Firing data has no encoding.** No type, code or field can hold a firing solution, a charge, an
   elevation, an aim or a `Cleared` value. The golf layer gets exactly two messages: check fire and
   cease fire (walking out). Both only add holds. Nothing here lifts a hold.
6. **Every packet is authenticated.** A packet that fails its tag is dropped without a reply.

## Packet layout

Our bytes go in the payload of a Meshtastic `Data` message on our private port (see
[Open questions](#open-questions)). Meshtastic adds its own header around it.

```
 0      1      2      3      4      5      6      7      8 ...              n-16 ... n
+------+------+------+------+------+------+------+------+----------------------+------------+
| ver  | type | squad tag   | from | message ID         | body (encrypted)     | auth tag   |
+------+------+------+------+------+------+------+------+----------------------+------------+
 \_____________________ header: 8 bytes, sent in clear, authenticated _______/   16 bytes
```

| Field | Size | Meaning |
| --- | --- | --- |
| `ver` | 1 | High nibble `0xA` (ours), low nibble the codec version (`1`). Anything else is ignored |
| `type` | 1 | Bits 0–5: the [message type](#message-types). Bit 6: key (0 = squad epoch key, 1 = the sender's member key). Bit 7: ack requested |
| `squad tag` | 2 | First 2 bytes of `HKDF(epochKey, info: "lora/tag")`. Tells a radio which squad and which key epoch, without naming the squad. It changes with every epoch. A receiver tries its current and previous epoch |
| `from` | 1 | The sender's index in the roster. 0 = the leader, 1–127 = members, 128–254 reserved, 255 = a radio with no phone (radio-GPS beacons only) |
| `message ID` | 3 | The sender's counter, per epoch. Never reused under the same key (see [Nonces](#nonces)) |
| `body` | 0–184 | The type's fields, encrypted |
| `auth tag` | 16 | ChaCha20-Poly1305 tag over the header and the body |

Overhead is **24 bytes** per packet. Keep the whole packet under about 100 bytes; the codec refuses
anything over 200.

### Nonces

The 12-byte nonce is `squad tag (2) ‖ from (1) ‖ message ID (3) ‖ type (1) ‖ 0x00 × 5`. Nothing extra
is sent. The rule that keeps it safe: **a sender never reuses a message ID under the same key.** Each
device persists its counter and reserves IDs in blocks of 256: it writes "next block starts at N+256"
before using ID N, so a crash skips IDs and never repeats one. A new epoch resets every counter to 0.
24 bits is 16 million messages per sender per epoch: years at one a minute.

### Who sent it

- With the **member key** (bit 6 set), only that member and the leader can make the tag, so the
  leader knows exactly who sent it. Members use it for everything they send to the leader.
- With the **squad epoch key**, the tag proves "someone in the squad". The leader uses it for
  broadcasts; members use it for messages everyone needs to read (SOS, check fire, beacons). `from`
  then says who claims to have sent it, and the app shows it that way.

## Field encodings

All integers are big-endian.

### Place: 5 or 9 bytes

One header byte, then the coordinates.

| Bits of the header | Meaning |
| --- | --- |
| 7 | 0 = relative to a datum, 1 = absolute |
| 6–4 | Datum ID (0–7), for relative places |
| 3–2 | Source: 0 = phone GPS, 1 = radio GPS, 2 = entered on a map, 3 = last known (stale) |
| 1 | Altitude valid (a 3D fix) |
| 0 | Moving |

- **Relative (4 bytes):** `east: Int16`, `north: Int16`, in units of 2 m from the datum. That covers
  ±65 km at 2 m resolution, finer than a phone fix. A place outside that range is sent absolute.
- **Absolute (8 bytes):** `lat: Int32`, `lon: Int32`, in units of 10⁻⁷ degrees (WGS 84).

**The datum** is a point the leader picks: the trailhead, base, or the firing point. It goes in the
`Welcome` over Wi-Fi and in a [`datum`](#message-types) message over LoRa. A receiver that doesn't
know a datum ID asks for it (`datumRequest`) and shows the position as unknown until then. Changing
the datum takes a new ID, so old positions still decode.

### Motion: 6 bytes

Always follows a place in beacons and check-ins.

| Field | Size | Encoding |
| --- | --- | --- |
| Altitude | 2 | `Int16`, metres above mean sea level |
| Accuracy | 1 | Horizontal, metres, 0–253; 254 = 254 m or worse; 255 = unknown |
| Course | 1 | Degrees × 256 / 360 (1.4° steps). Ignored when speed is 0 |
| Speed | 1 | Units of 0.2 m/s, up to 50.8 m/s; 255 = unknown |
| Fix age | 1 | Seconds between the fix and sending, 0–254; 255 = older |

There's no clock time in the packet. The receiver stamps arrival time and subtracts the fix age;
relays add seconds, which doesn't matter at these rates.

### Recipients: 1 or 5 bytes

| First byte | Meaning |
| --- | --- |
| `0x00` | Everyone in the squad |
| `0x01`–`0x7F` | One member, by roster index |
| `0x80`–`0xFE` | One team: `0x80 + team number` (teams come from the roster, over Wi-Fi) |
| `0xFF` | A bitmask of roster indices 1–32 follows, 4 bytes |

### Text: 1 + n bytes

A length byte, then UTF-8, at most 48 bytes, cut at a character boundary. Always the last field.

### Message reference: 4 bytes

`from (1) ‖ message ID (3)` of the message being answered.

## Message types

| Code | Type | Direction | Key | Body | Body bytes |
| --- | --- | --- | --- | --- | --- |
| `0x01` | `beacon` | Anyone → all | Epoch | place, motion, presence | 15 or 19 |
| `0x02` | `checkIn` | Member → leader | Member | status (1), place, motion | 12 or 16 |
| `0x03` | `order` | Leader → recipients | Epoch | recipients, code, arguments, optional text | 2–64 |
| `0x04` | `report` | Member → leader (or all) | Member or epoch | code, arguments, optional text | 1–60 |
| `0x05` | `ack` | Anyone → sender | Either | reference, response (1) | 5 |
| `0x06` | `sos` | Anyone → all | Epoch | kind (1), people (1), absolute place, motion, optional text | 17–50 |
| `0x07` | `sosAck` | Anyone → all | Epoch | reference, ETA in minutes (1; 255 = unknown) | 5 |
| `0x08` | `sosCancel` | SOS sender → all | Epoch | reference, reason (1) | 5 |
| `0x09` | `datum` | Leader → all | Epoch | datum ID (1), absolute place | 10 |
| `0x0A` | `datumRequest` | Anyone → leader | Either | datum ID (1) | 1 |
| `0x0B` | `rekey` | Leader → one member | Member | new epoch (2), new epoch key (32) | 34 |
| `0x0C` | `golf` | Anyone → all | Epoch | golf code (1): `0x01` check fire, `0x02` cease fire (walking out) | 1 |
| `0x3F` | reserved | | | | |

**Presence** (in `beacon`, 4 bytes): phone battery % (1; 255 = no phone), radio battery % (1), links up
(1: bit 0 Wi-Fi to leader, bit 1 BLE to radio, bit 2 GPS), status (1, same codes as `checkIn`).

**Status codes** (in `checkIn` and presence): `0` OK, `1` moving, `2` stopped, `3` resting, `4`
delayed, `5` turning back, `6` need assistance (not an emergency; use `sos` for that).

**SOS kinds:** `0` unspecified, `1` injury, `2` lost, `3` avalanche burial or involvement, `4`
medical, `5` equipment failure, `6` weather or exposure. **People:** how many need help, 0 = unknown.

**Ack responses:** `0` seen, `1` will do, `2` done, `3` cannot, `4` unknown code (update the app).

**Golf** is the only type the golf layer may use, and it has two codes. Both raise holds on the
leader's iPad. There is no code to withdraw a check fire or lift a hold: that happens on the iPad, as
today. A test pins that `golf` has exactly these two codes and that no other type can be sent with
the golf namespace.

## The instruction codebook

An `order` is `recipients, code, arguments, [text]`. A `report` is `code, arguments, [text]`. The code
fixes which arguments follow, in this order, so they need no tags. `[text]` is always allowed, and
code `0xFF` is text only.

Argument kinds: **P** a place (5 or 9 bytes), **M** a member index (1), **T** a time in minutes from
now (1, up to 254), **N** a number (1), **S** a sector or route ID (1, defined over Wi-Fi), **H** a
hazard (1, below).

### Orders: leader → members (`0x01`–`0x5F`)

| Code | Name | Args | Shows as |
| --- | --- | --- | --- |
| **Movement** | | | |
| `0x01` | Hold | — | Hold your position |
| `0x02` | Move to | P | Move to (place) |
| `0x03` | Regroup | P? | Regroup at (place), or on the leader if none |
| `0x04` | Return | P? | Return to (place), or to the datum |
| `0x05` | Follow | M | Follow (member) |
| `0x06` | Wait for | M | Wait for (member) |
| `0x07` | Proceed | S? | Carry on along (route) |
| `0x08` | Turn around | — | Turn around now |
| `0x09` | One at a time | P? | One at a time to (place); wait until the one ahead arrives |
| `0x0A` | Spread out | N | Keep (N × 10) m apart |
| `0x0B` | Stop | — | Stop: everyone stays put |
| **Reporting** | | | |
| `0x10` | Report position | — | (No screen: sends a beacon now) |
| `0x11` | Check in by | T | Check in within (T) minutes |
| `0x12` | Check-in interval | T | Check in every (T) minutes (starts the timer) |
| `0x13` | Beacon rate | N | Send position every (N) minutes on LoRa |
| `0x14` | Report status | — | Send your status |
| **Tasks** | | | |
| `0x20` | Search sector | S | Search (sector) |
| `0x21` | Hasty search | S | Hasty search along (route) |
| `0x22` | Assist | M | Go to (member) and help |
| `0x23` | Stand by | — | Stand by for tasking |
| `0x24` | Mark | P | Mark (place) on your map |
| **Safety** | | | |
| `0x30` | Avoid | P, N | Stay (N × 10) m clear of (place) |
| `0x31` | Hazard | P, H | (Hazard) at (place) |
| `0x32` | Retreat | P? | Weather or hazard: retreat to (place) |
| `0xFF` | Text | — | Text only |

`P?` means the place is optional: a place header byte of `0xFF` stands for "none", with no
coordinates. (An absolute place always has its datum bits at 0, so `0xFF` is never a real header.)

### Reports: members → leader (`0x80`–`0xEF`)

| Code | Name | Args | Shows as |
| --- | --- | --- | --- |
| `0x80` | Arrived | P | (Member) arrived at (place) |
| `0x81` | Sector done | S, N | (Sector) searched, (N)% covered |
| `0x82` | Clue | P | Clue at (place) — text says what |
| `0x83` | Subject found | P, N | Subject found at (place); condition (N): 0 unknown, 1 well, 2 injured, 3 critical, 4 deceased |
| `0x84` | Delayed | T | Delayed (T) minutes |
| `0x85` | Turning back | — | Turning back |
| `0x86` | Hazard | P, H | (Hazard) at (place) |
| `0x87` | Low battery | N | Phone at (N)% |
| `0x88` | Need assist | P? | Need help (not an emergency) |
| `0xFF` | Text | — | Text only |

**Hazards (H):** `0` other, `1` avalanche (recent or observed), `2` cornice, `3` crevasse, `4` icy
slope, `5` open water or thin ice, `6` rockfall, `7` whiteout, `8` lightning, `9` wildlife.

`0x60`–`0x7F` and `0xF0`–`0xFE` are reserved. The golf orders (range the pole, spot, capture) are not
in this codebook; they stay on the local link.

### Changing the codebook

New codes go in unused slots; existing codes never change meaning. A receiver that gets a code it
doesn't know shows "Unknown instruction (update the app)" with any text, and answers with ack `4`.
On Wi-Fi the generic `Order` in `SquadKit` carries the same code, so both links share one vocabulary
and today's `Order.Kind` maps onto it: `moveTo` → `0x02`, `holdPosition` → `0x01`,
`returnToFiringPoint` → `0x04`, `note` → `0xFF`. `rangeFrom`, `spot` and `capture` stay golf-only.

## Acks and retries

- **Orders and `checkIn` ask for an ack** (type bit 7). The receiver acks once with "seen" when it
  shows the order, then again when the member answers (will do, done, cannot). A repeat of the same
  message ID gets the same ack again, so a lost ack heals.
- **Retries on LoRa:** at 30 s, 60 s, 120 s and 240 s, then give up and show "not delivered" to the
  sender. A message delivered over Wi-Fi in the meantime counts; acks may come back on either link.
- **SOS** repeats every 30 s for 5 minutes, then every 2 minutes, until a `sosAck` from the leader or
  a `sosCancel`. Each repeat is a new `sos` with a fresh position and a new message ID; receivers
  group an SOS by sender, so the newest position replaces the last. A `sosAck` may reference any of
  them. Acks from members show too, but only the leader's slows the repeats.
- **Beacons and golf messages** don't ask for acks. Golf check fire repeats three times, 10 s apart.
- **De-duplication:** receivers keep the last 512 `(from, message ID)` pairs per squad and drop
  repeats before acting on them.

## Sizes and airtime

Whole packet = 24 bytes overhead + body. Airtime adds about 21 bytes of Meshtastic header and
wrapping.

| Message | Our bytes | LongFast | MediumFast |
| --- | --- | --- | --- |
| `golf` check fire | 25 | 0.60 s | 0.17 s |
| `ack`, `sosAck`, `sosCancel` | 29 | 0.64 s | 0.18 s |
| `order` with a relative place, one recipient | 31 | 0.64 s | 0.18 s |
| `datum` | 34 | 0.64 s | 0.19 s |
| `beacon`, relative | 39 | 0.68 s | 0.20 s |
| `checkIn`, absolute | 40 | 0.72 s | 0.20 s |
| `beacon`, absolute | 43 | 0.72 s | 0.21 s |
| `rekey` | 58 | 0.85 s | 0.24 s |
| `sos` with 32 bytes of text | 74 | 0.93 s | 0.27 s |
| `order` with a place and 40 bytes of text | 72 | 0.93 s | 0.27 s |

Text is what makes a message long: 40 bytes of it cost more airtime than the rest of an order.

## An example

The leader (index 0) tells member 3 to regroup at a place 412 m east and 1,030 m north of datum 1,
with no text, and asks for an ack:

```
A1             ver: ours, codec 1
83             type: order (0x03), epoch key, ack requested
5C E2          squad tag (this epoch)
00             from: leader
00 01 2F       message ID 303
  --- encrypted body (7 bytes) ---
03             recipients: member 3
03             code: regroup
10             place header: relative, datum 1, phone GPS, no altitude, not moving
00 CE          east  = 206 × 2 m = 412 m
02 03          north = 515 × 2 m = 1,030 m
  --- auth tag (16 bytes) ---
```

31 bytes in all. Member 3's phone shows "Regroup at" with the place on the map, a pointer and a
distance, and acks "seen". When member 3 taps **Will do**, it acks again with response `1`.

## Open questions

- **Our Meshtastic port.** Start on the first private-app port (256) and filter on the `ver` byte and
  squad tag; request a registered port if the app ships.
- **2-byte squad tag collisions.** Two squads on one mesh share a tag about once in 65,536 epochs; a
  wrong-key packet just fails its tag. Is the wasted decrypt worth a third byte?
- **Teams over 32 members.** The bitmask covers roster indices 1–32; bigger SAR callouts use teams.
  Is that enough, or do we need a longer mask?
- **Per-member signatures for SOS.** An epoch-key SOS proves only "someone in the squad". An Ed25519
  signature adds 64 bytes (about 0.4 s on LongFast). Worth it for SAR?
- **Codebook translation.** The codebook doubles as the app's string table for these messages, so a
  squad with mixed languages reads its own. Which languages first?
