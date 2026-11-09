# Squad core, mission add-ons, and internet hosting

Status: design, not built. This doc proposes two changes to Squadz:

1. **Split it.** A **squad core** does what every squad needs: join, roster, positions, orders,
   notes, files, check fire, and holds. **Missions are add-ons** on top of that core. SpudGunGolf
   fire missions are the first add-on. The recon drone ([RECON.md](RECON.md)) is the second.
2. **Host it on the internet.** A relay server carries the squad's messages when the devices
   aren't on the same network. The relay reuses the earlier `squadz` server (Rust, Axum). The
   commander's device stays in charge, and the relay can't read what it carries.

Read [GROUP_PLAY.md](GROUP_PLAY.md) and [SQUAD_COMMS.md](SQUAD_COMMS.md) first. **No safety rule
changes.** Firing data stays on the commander's iPad and never goes over any link. Holds only add.
The 91 m (100 yd) limit per shot stands. A mission can add holds. Nothing can remove one.

## Contents

1. [Why split](#why-split)
2. [The squad core](#the-squad-core)
3. [Mission add-ons](#mission-add-ons)
4. [Internet hosting](#internet-hosting)
5. [Recycling squadz and SquadTracker](#recycling-squadz-and-squadtracker)
6. [Build order](#build-order)
7. [Open decisions](#open-decisions)

## Why split

GroupKit grew around golf. Its message list mixes things any squad needs (hello, positions,
orders, notes) with things only golf needs (range locks, spots, fired, the course, the firing fan).
`SquadHost` does both in one 630-line type. Every new idea, such as the drone, patrol, or a
meetup, would have to change that type and bump the protocol for everyone.

Splitting lets us get the basics of any squad right first: who's in it, where they are, what
they've been told to do, and whether anyone has called stop. Then each mission adds only what it
needs.

## The squad core

The core is today's GroupKit with the golf parts taken out. Nothing in it knows about potatoes.

| Part | What it does | From today's code |
| --- | --- | --- |
| **Join** | Join code, hello, welcome, refused, bye. Rejoin as the same member after a drop | `Hello`, `Welcome`, `JoinCode`, rejoin in `SquadHost` |
| **Roster** | Members, roles, online or not, remove a member | `Squad`, `Member`, roster in `SquadHost` |
| **Positions** | Each member's position, its accuracy and age; the commander shares them with observers | `MemberPosition`, `.positions` |
| **Orders** | Commander → members: who, what, where; members answer seen, done or can't | `Order`, `OrderAck`. Core kinds: move to, hold position, note, capture. Missions add kinds |
| **Notes and files** | Field notes with a photo; chunked files with a receipt | `FieldNote`, `FileOffer`/`Chunk`/`Done`, `Receipt` |
| **Check fire** | Anyone can call it. Only the commander lifts it | `CheckFire`, `activeCheckFire` |
| **Holds** | The union of the core's holds and every mission's holds. A mission can add, never remove | `Hold`, `GroupGate` |
| **Status** | Roster, positions, holds, and one section per running mission | `SquadStatus`, split |
| **Observers** | The Theater or any watcher: read-only, gets status and positions | `.observing` |

The core is useful by itself: a squad that only shares positions, gets orders and sends notes.
That's what the old `squadz` web app did. It's the first thing to test on the internet, because no
mission rides on it yet.

## Mission add-ons

A mission is a module the commander turns on for the squad. It has an id, a version, its own
messages, its own holds, its own section of the status, and its own order kinds.

```swift
public protocol Mission {
    static var id: MissionID { get }          // "golf.firemission", "recon.drone"
    static var version: Int { get }

    /// A member's message for this mission. Returns what to send.
    mutating func handle(_ payload: Data, from member: MemberID, core: CoreView, now: Date) -> [Outgoing]
    /// This mission's holds. The core adds them to its own; it never subtracts.
    func holds(core: CoreView, now: Date) -> Set<Hold>
    /// This mission's part of the squad status, for members and observers.
    func status(core: CoreView) -> Data
    /// Order kinds this mission adds (for example "Range the pole", "Spot").
    static var orderKinds: [Order.Kind] { get }
}
```

On the wire, a mission message is one core body: `.mission(id, version, payload)`. The core routes
it by id and checks the version. The protocol version then covers only the core. A golf change
bumps the golf mission's version, not everyone's.

`Hold` becomes a core type with a mission id and a reason, so a mission can add its own kinds
without changing the core enum. `GroupGate` stays as it is: it can turn a cleared solution into a
blocked one, never the reverse.

### The missions we know of

| Mission | What it adds | Holds it adds |
| --- | --- | --- |
| **Golf fire mission** (first) | The course and field submissions, range locks, fired, spot requests and reports, the hole and its rounds, the firing fan, the firing gate on the iPad | Walking out, member in the fan, no recent position while a hole is live |
| **Recon drone** (second, [RECON.md](RECON.md)) | The aerial member, station/patrol/look-at orders, drone status | Drone in the fan, drone position unknown |
| **Patrol / meetup** (a test of the split) | Waypoints and a rally point. No holds | None |

Golf keeps everything that makes it safe. The firing data and the solver stay inside the golf
mission on the iPad, which still never sends them anywhere. The "no recent position" hold stays in
golf because it only matters while a hole is live.

## Internet hosting

### The model: a relay, not a host

The commander's device stays in charge. The server is a **relay**: it matches a join code to a
squad, checks that each device belongs, and passes GroupKit frames between the commander and
the members. It doesn't run `SquadHost` and doesn't decide anything.

```
 phone ──┐                      ┌── phone
          ├─ local Wi-Fi ─ iPad ─┤
 phone ──┘   (GroupLink, today)  └── relay ── phone at home
                                      │
                                      └── Theater anywhere
```

Why a relay and not a server that hosts the squad:

- **Same code everywhere.** `SquadHost` and its tests run on the iPad whether the link is local
  Wi-Fi, LoRa or the internet. The relay is one more transport, like LoRa in SQUAD_COMMS.
- **Safety doesn't move.** Holds are worked out on the iPad from what arrives. A slow or dead
  relay shows up as old positions, and the "no recent position" hold covers that, as it does for
  Wi-Fi today.
- **The server holds very little.** Squads, device tokens and a short queue of frames waiting for
  delivery. No positions history, no game state.

A later option is a hosted commander for core-only squads with no iPad (a web group). That's a
`SquadHost` running on the server. It's out of scope until the relay works.

### Links

GroupLink gets a second transport, `RelayLink`: a WebSocket over TLS to the relay, carrying the
same length-prefixed frames as the local link ([Wire.swift](../Packages/SpudCore/Sources/GroupKit/Wire.swift)).
A member can be on both links; the commander takes the first copy of each frame (messages already
carry a sequence number) and ignores repeats. A device prefers the local link when it's there.

### Keys: the relay can't read the squad

Today's local link uses TLS keyed from the join code. That's fine on one Wi-Fi network. It isn't
enough on the internet, where anyone can try codes.

- **Device tokens.** Joining through the relay gives each device a random token (as `squadz` did
  with its `sqz_` keys). The relay checks the token on every connection. The commander can revoke
  one by removing the member.
- **End-to-end encryption.** Frame bodies are sealed with the squad's keys from
  [SQUAD_COMMS.md](SQUAD_COMMS.md) Part 1 (the same keys LoRa uses). The relay sees only who a
  frame is from, who it's for, and its size.
- **Join codes are short-lived.** On the relay, a join code works for 10 minutes, or until the
  commander closes joining, and wrong codes are rate-limited per address. SquadTracker already
  expired its codes after 5 minutes.

### What runs where

| Piece | Where | Notes |
| --- | --- | --- |
| Relay | One small container on any host with TLS | Rust, Axum, Tokio (from `squadz`). SQLite for squads and tokens. Nothing else stored |
| Commander | The iPad app | Unchanged, plus `RelayLink` |
| Members | The iPhone app; later a browser for core-only squads | A browser member can't join a golf mission: golf needs the app's camera ranging and safety checks |
| Theater | The Mac app, as an observer through the relay | Fields and files sent to the Theater still go device to Theater, sealed end to end |

## Recycling squadz and SquadTracker

The earlier `squadz` repo is a Rust/Axum server with a Next.js web client for sharing positions
in a squad. SquadTracker is an earlier TypeScript version with WebSockets.

**Keep from squadz:**
- The Rust workspace, Axum and Tokio setup, the Dockerfile, health and metrics.
- Join codes: 6 characters from an alphabet without 0/O/1/I. GroupKit's `JoinCode` uses the same
  idea.
- Per-device tokens (`sqz_` keys) and the auth middleware.
- The squad manager's create, join, leave and leader rules.
- The Leaflet map client, later, for a browser member.

**Keep from SquadTracker:**
- WebSockets instead of 10-second polling.
- Join codes that expire. Open squads (anyone can invite) and managed squads (only the leader can).
  Squadz is managed only for now.

**Fix or drop before anything goes on the internet:**

| In squadz today | Problem | Change |
| --- | --- | --- |
| `GET /api/v1/squads` is public | Lists every squad with its join code and members, so anyone can join any squad | Remove it |
| `GET /api/v1/squads/:id/locations` is public | Anyone with a squad id reads live positions | The relay doesn't store positions at all; they're sealed in frames |
| Crypto endpoints with a fixed demo key | The key is in the source and returned by `/crypto/health` | Remove them; use the squad keys |
| Dashboard password in the URL query | Ends up in logs and browser history | Remove the dashboard, or use a POST and a cookie |
| Everything in memory | A restart drops every squad and token | SQLite for squads and tokens |
| CORS allows any origin | Any web page can call the API | Allow only the web client's origin |
| Positions and squads by REST | Polling, and the server sees everything | Frames over WebSocket, sealed end to end |

The squadz server is deployed today. Because of the first two rows, **take it down, or at least
remove those two routes, before using it again.**

## Build order

| Step | What | Done when |
| --- | --- | --- |
| **C1. Extract the core** | Move the golf parts of GroupKit and `SquadHost` behind the `Mission` protocol, with no change in behaviour. Golf is the only mission | Every GroupKit and safety test passes unchanged. A fuzz test: no mission message lifts a core hold |
| **C2. Mission messages** | `.mission(id, version, payload)`, a core-only protocol version, hold ids per mission | A squad with no mission plays a "positions and orders" session on devices. A golf version bump doesn't break core-only devices |
| **C3. Relay** | The recycled squadz server: tokens, rooms, WebSocket frames, SQLite, the fixes above | A phone on cellular joins an iPad on home Wi-Fi through the relay and shows up on its map |
| **C4. Sealed frames** | Bodies sealed with the squad keys; the relay sees headers only | A test relay that logs everything logs no positions, names or notes |
| **C5. Golf over the relay** | Golf mission with a member on the relay | Holds behave the same as on local Wi-Fi: stopping the relay raises "no recent position" within 15 s |
| **C6. Theater through the relay** | The Mac app as an observer from anywhere | The Theater shows a squad that isn't on its network |
| **C7. Recon mission** | [RECON.md](RECON.md) as the second mission | Its own milestones |

## Open decisions

- **Name.** Is the core "Squadz" and golf "SpudGunGolf for Squadz", or does the core get its own
  name?
- **Repo.** Keep the core in this repo's SpudCore package, or move it and the relay to the
  `squadz` repo and depend on it from here?
- **Browser members.** Worth doing for core-only squads, or app only?
- **Where to host the relay.** Any host that runs a container with TLS works. Pick one when C3 starts.
