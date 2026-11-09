# 2. Squadz (v3)

[Back to How to play](README.md)

In Squadz, **the squad is the player**. A squad has one scorecard. Each hole is still a v2 fire mission. It plays like golf: the squad works together at the head of the hole, doesn't shoot while anyone is on the field, and manages its own play on the course. There are no turns with other squads.

## Who does what

| Who | Device | Does |
| --- | --- | --- |
| **Commander** | The squad's iPad, usually in landscape | Hosts the squad: shows the join code and QR code, the field map with everyone on it, the roster, the hole, members' locks and spot calls, and the orders. It's the squad's only firing display, so the safety checks run there. |
| **Member** | Each player's phone | Joins with the code, reports its position, ranges and sends locks, spots rounds, and answers orders. A phone never shows firing data. |
| **Gunner** | A member, at the launcher | Calls **Fired** when a round is away. |

## Joining

1. On the iPad: **Play → Start a squad**, pick a squad name, and start it. Open **Invite** to show its 6-character code and QR code. The iPad stays awake on its command screen.
2. On each phone: **Play → Join squad**, pick the squad, then **Scan code** or type it.
3. Allow **Local Network** on both devices, and **Location** on the phone. Phones keep reporting their position in the background while in a squad.

If the iPad sleeps or the Wi-Fi blinks, phones rejoin on their own as the same member. The iPad reopens the squad on the same code when it wakes. A phone that can't get through in 8 seconds on its first try stops and says to check the code.

Squads play practice holes (simulated rounds) for now.

## The commander's screen

The map remains beside the workspace on a landscape iPad. Hole, phase, connection state and holds stay visible above the workspace selector. **Mission** contains hole controls and received locks, **Orders** contains tasking, and **Team** contains the roster and inbox. Opening **Invite** shows the join code without replacing the workspace.

- **The map:** satellite imagery with the course boundary, the flags and rings, the firing points, the safety fans (the hole in play is highlighted), and every member as a dot. A dot goes grey when its position is old. **Fit** frames the course and the squad. Used locks are drawn as lines, and orders with a place as pins with a dashed pointer from each member.
- **Hole:** **Start hole** (choose a firing point), **Confirm downrange** (only the commander's own tap does this), **Fired**, then members' spot calls with **Use** or **Lost**, then **Cease fire** and **Finish hole**.
- **Locks:** members' locks, newest first. **Use** checks a lock against the course on the iPad and begins, advances or verifies the mission.
- **Inbox:** field notes and fields that members sent in. See below.

## Field notes and fields

- **A field note** is a short note (up to 500 characters), where you stand, and an optional photo. On a phone in the squad: **Send a field note** on the joined Play screen, or Field → Send a field note. Pick **Squad leader** or **Theater**. Notes to the leader show in the iPad's inbox, and go on to the Theater if one is watching.
- **A field** is a course a member surveyed (Field → Survey a course). **Send to my squad leader** there puts it in the inbox. A field with blocking problems is refused.
- **Adopt** switches the squad to that field, with a fresh card. The leader can only adopt between holes: not mid-hole, not while people walk out. A practice-only field puts the squad in practice. **Decline** drops it.

## Holds

Holds pause firing data while someone may be on the field. They only ever add to the safety checks, never remove them. The iPad works them out itself:

{{holds_list}}

What each one means:

- **Walking out** lasts from **Cease fire** until the hole is finished or resumed, or the next mission begins.
- **Check fire** can come from any phone or the iPad. It holds the squad and cancels the downrange confirmation. Only the commander lifts it, on the iPad, and then confirms downrange again.
- **Inside the firing fan** and **No recent position** apply only while a hole is live. A phone that hasn't sent its position for {{squadz.positionTimeoutS}} s holds the squad: silence is not clear. Between holes there are no fan or position holds.

Holds never stop orders, locks or the map.

Protocol version {{squadz.protocolVersion}}: a device running a different version is refused, so update every device together.
