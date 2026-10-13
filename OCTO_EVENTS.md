# ChronicleCompanion — OctoWoW fork (0.38.1)

This fork keeps everything ChronicleCompanion 0.38 writes, plus:

- **One file per character, instance and day** (local change kept from 0.37):
  `Chronicle_<Name>_<Instance>_<YYYY-MM-DD>.txt`, a raid that runs past
  midnight stays in the file of the day it started (day starts at 06:00).
  `/chronicle file` shows the current file.
- **Extra log lines** for deeper analysis, listed below.

All lines keep the usual layout `TIMESTAMP_MS|EVENT|field|...`. The event names
are new, so Chronicle skips them (checked with Chronicle's own parser on a real
Onyxia log with tens of thousands of extra lines, including UNIT_STATE: 0 errors,
identical results). No field of an
existing event was changed.

## Requirements

| Feature | Needs |
| --- | --- |
| UNIT_STATE (health, power), UNIT_TARGET | Nampower (already required) |
| UNIT_STATE position fields | ClassicAPI (any visible unit) or SuperWoW (friendly units only) |
| RAID_MARK | nothing; `markN` tokens of ClassicAPI / SuperWoW make it more complete |
| THREAT, THREAT_TANK | the OctoWoW server threat API; TWThreat or pfUI-ThreatPlates optional |

## Events

### OCTO_INFO
`ts|OCTO_INFO|formatVersion|positionApi|classicApi|superWowVersion|threatMode|mapId`

Written when logging starts and after every ZONE_INFO. `formatVersion` is 2
since `UNIT_STATE` replaced `HEALTH`, `POWER` and `UNIT_POSITION`.
- `positionApi`: `classicapi`, `superwow`, `unknown` or `none`.
- `threatMode`: `query` (this addon asks the server) or `listen` (TWThreat /
  pfUI-ThreatPlates ask, this addon only records the answers).

### UNIT_STATE
`ts|UNIT_STATE|guid|hp|maxHp|power|maxPower|powerType|mapId|x|y|z`

Health, power and position of one unit on one line, written only when one of
them changes (position: a move of more than `positionMinMove` yards).

| Field | Content |
| --- | --- |
| `hp`, `maxHp` | current and max health |
| `power`, `maxPower` | current and max value of the unit's **current** power type |
| `powerType` | `0` mana, `1` rage, `2` focus, `3` energy, `4` happiness |
| `mapId` | `Map.dbc` id (ClassicAPI), e.g. 309 for Zul'Gurub; empty without ClassicAPI |
| `x`, `y`, `z` | world coordinates in yards, x = north, y = west whatever the API |

Empty fields mean "not available" (no power, out of position range, etc.).
Rage is converted to the usual 0–100 scale (the unit field stores ×10).

Units: group members, their pets, and hostile creatures seen in combat events
during the last 15 s. Lines come from:
- Nampower `UNIT_HEALTH_GUID` / `UNIT_MANA_GUID` / `UNIT_RAGE_GUID` /
  `UNIT_ENERGY_GUID`, written right away (same timestamp as the event);
- a poll of tracked hostiles every `targetInterval` (0.25 s);
- a position poll every `positionInterval` (1 s), only while you are in combat.

Notes:
- A druid's power is the one of their current form: energy in cat form, rage
  in bear form, mana otherwise. The caster mana is not visible while shifted.
- Check `maxHp` for creatures. If it is 100, the server sends a percentage
  instead of real hit points.

### UNIT_TARGET
`ts|UNIT_TARGET|guid|targetGuid`

Target of each tracked hostile creature (empty = no target), polled every
`targetInterval` (0.25 s), written on change. Gives who is tanking and when a
boss switches target.

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

The options panel (`/clog` or `/chronicle config`) has an **Extra events**
side panel on its right: one checkbox per line type, the threat request mode
(auto / on / off) and the APIs detected. Intervals are only in the slash
command: `/chronicle octo` lists the settings, `/chronicle octo <setting>
<value>` changes one.

| Setting | Default | Meaning |
| --- | --- | --- |
| unitState, target, marks, threat | on | turn each line type on/off |
| position | on | add positions to `UNIT_STATE` and poll them in combat |
| targetInterval | 0.25 | seconds between target / hostile health and power polls |
| positionInterval | 1 | seconds between position polls (in combat) |
| positionMinMove | 0.5 | yards a unit must move before a position change alone writes a line |
| threatQuery | auto | `auto`: ask the server only if TWThreat and pfUI-ThreatPlates are absent; `on`; `off` |
| threatInterval | 1 | seconds between threat requests |
| threatLimit | 10 | players per threat table requested |

## Limits

- Only units your client sees are logged. Several raiders logging together
  cover the whole raid.
- The server only answers threat for **your** target. Shared relays from the
  group fill in the other mobs.
- File size grows with UNIT_STATE lines. Not measured yet in a
  40-man raid: check the first log and raise the intervals if needed.
