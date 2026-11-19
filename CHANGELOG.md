# Changelog

## 0.1.4 (2026-11-19)

- Fixed: 0.1.3 showed the error "LunarJournal.lua:53: attempt to call a nil value" every second, and zone names weren't saved. Zone names, time per zone and zone changes are recorded again.

## 0.1.3 (2026-11-19)

- Fixed: turning in a quest could show the error "attempt to perform string conversion on a secret string value" several times. The game sometimes hides the quest giver's name, the NPC's ID or the reward text from addons. The turn-in is now saved without the hidden part.
- The same protection now covers offered, accepted and abandoned quests, NPCs you talk to, group members, trades, duels and zone names. If the game hides one of those values, the entry is saved without it instead of the addon stopping with an error.

## 0.1.2

- Fishing catches and crafts are recorded properly in the modern client.
- No more error every second when the game hides your movement speed.
