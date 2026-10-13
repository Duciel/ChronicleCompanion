# ChronicleCompanion — OctoWoW fork (0.38.0+octo1)

This fork keeps everything ChronicleCompanion 0.38 writes, plus:

- **One file per character, instance and day** (local change kept from 0.37):
  `Chronicle_<Name>_<Instance>_<YYYY-MM-DD>.txt`, a raid that runs past
  midnight stays in the file of the day it started (day starts at 06:00).
  `/chronicle file` shows the current file.
- **Extra log lines** for deeper analysis, listed below.

All lines keep the usual layout `TIMESTAMP_MS|EVENT|field|...`. The event names
are new, so Chronicle skips them (checked with Chronicle's own parser on a real
Onyxia log: 48 328 extra lines, 0 errors, identical results). No field of an
existing event was changed.

## Requirements

| Feature | Needs |
| --- | --- |
| HEALTH, POWER, UNIT_TARGET | Nampower (already required) |
| UNIT_POSITION | ClassicAPI (any visible unit) or SuperWoW (friendly units only) |
| RAID_MARK | nothing; `markN` tokens of ClassicAPI / SuperWoW make it more complete |
| THREAT, THREAT_TANK | the OctoWoW server threat API; TWThreat or pfUI-ThreatPlates optional |

## Events

### OCTO_INFO
`ts|OCTO_INFO|formatVersion|positionApi|classicApi|superWowVersion|threatMode`

Written when logging starts and after every ZONE_INFO.
- `positionApi`: `classicapi`, `superwow`, `unknown` or `none`.
- `threatMode`: `query` (this addon asks the server) or `listen` (TWThreat /
  pfUI-ThreatPlates ask, this addon only records the answers).

### HEALTH
`ts|HEALTH|guid|health|maxHealth`

Group members, their pets, and hostile creatures seen in combat events during
the last 15 s. Written only when the value changes. Source: Nampower
`UNIT_HEALTH_GUID` + `GetUnitField(guid, "health")`, and a poll of tracked
hostiles every `targetInterval`.

Note: check `maxHealth` for creatures. If it is 100, the server sends a
percentage instead of real hit points.

### POWER
`ts|POWER|guid|powerType|value|max`

Group members and pets only. `powerType`: 0 mana, 1 rage, 3 energy. Rage is the
raw field value (×10: 1000 = 100 rage). Written only when the value changes.

### UNIT_TARGET
`ts|UNIT_TARGET|guid|targetGuid`

Target of each tracked hostile creature (empty = no target), polled every
`targetInterval` (0.25 s), written on change. Gives who is tanking and when a
boss switches target.

### UNIT_POSITION
`ts|UNIT_POSITION|guid|x|y|z`

World coordinates (yards), normalised to x = north, y = west whatever the API.
Group members and tracked hostiles, every `positionInterval` (1 s), only while
you are in combat, and only when the unit moved more than `positionMinMove`
(0.5 yd).

### RAID_MARK
`ts|RAID_MARK|guid|index`

Raid icon 1–8 set on a unit, `0` when removed. On `RAID_TARGET_UPDATE`, on
enable, and every 5 s in combat.

### THREAT
`ts|THREAT|mobGuid|mobName|source|list`

Server threat table of one mob. `list` is copied as received:
`player:tank:threat:perc:melee;...` (`tank`/`melee` = 1 or 0, `perc` = % of
the tank's threat). `source`:
- `self`: answer to a `TWT_UDTSv4_TM` request from this client (this addon,
  TWThreat or pfUI-ThreatPlates). `mobGuid` is your target when the answer
  arrived.
- `relay:<Name>`: a `TWTRelayV2` message shared by a group member (TWThreat
  octo fork or pfUI-ThreatPlates). `mobGuid` is that player's target, empty if
  it could not be confirmed.

The same table received twice within 1.5 s is written once.

### THREAT_TANK
`ts|THREAT_TANK|source|list`

"Mobs I am tanking" list: `creature:serverGuid:nextPlayer:perc;...`.
`source` is `self` (TMTv1 answer) or `relay:<Tank>` (`PFTPTankV1` share).
`serverGuid` is the server's decimal form, not the `0x…` form.

## Settings

`/chronicle octo` lists them; `/chronicle octo <setting> <value>` changes one.

| Setting | Default | Meaning |
| --- | --- | --- |
| health, power, target, position, marks, threat | on | turn each line type on/off |
| targetInterval | 0.25 | seconds between target / hostile health polls |
| positionInterval | 1 | seconds between position polls (in combat) |
| positionMinMove | 0.5 | yards before a new position is written |
| threatQuery | auto | `auto`: ask the server only if TWThreat and pfUI-ThreatPlates are absent; `on`; `off` |
| threatInterval | 1 | seconds between threat requests |
| threatLimit | 10 | players per threat table requested |

## Limits

- Only units your client sees are logged. Several raiders logging together
  cover the whole raid.
- The server only answers threat for **your** target. Shared relays from the
  group fill in the other mobs.
- File size grows with HEALTH and UNIT_POSITION lines. Not measured yet in a
  40-man raid: check the first log and raise the intervals if needed.
