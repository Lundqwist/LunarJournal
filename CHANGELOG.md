# Changelog

## 0.2.0 (2026-11-21)

- Groups: the journal now writes down every party and raid you are in: when it formed and broke up, who was in it, when each member joined and left, and who led it. The journal window shows "Group formed with ..." and "Group broke up after ...".
- Quests done in a group: accepted and turned-in quests note who you were grouped with and which of them had the same quest. Each group lists the quests turned in while it lasted.
- Its own icon on the minimap button and in the AddOns list: the leather journal with the gold crescent moon (`Media\Icon.tga`, made from `Media\icon.png` by `tools\make-icon.ps1`).
- After a /reload the group carries on instead of everyone being written down as joining again.
- New settings window (`/lj settings`, or the Settings button in the journal window or at the top of the options page): a checkbox for each kind of thing the journal writes down, and a text box for how this character's story should be told. The story instructions are saved apart from the journal entries, so StoryMaker gives them to the AI as instructions. The old "Save the quest texts" and "Count kills" options moved there and keep their setting.

## 0.1.4 (2026-11-19)

- Fixed: 0.1.3 showed the error "LunarJournal.lua:53: attempt to call a nil value" every second, and zone names weren't saved. Zone names, time per zone and zone changes are recorded again.

## 0.1.3 (2026-11-19)

- Fixed: turning in a quest could show the error "attempt to perform string conversion on a secret string value" several times. The game sometimes hides the quest giver's name, the NPC's ID or the reward text from addons. The turn-in is now saved without the hidden part.
- The same protection now covers offered, accepted and abandoned quests, NPCs you talk to, group members, trades, duels and zone names. If the game hides one of those values, the entry is saved without it instead of the addon stopping with an error.

## 0.1.2

- Fishing catches and crafts are recorded properly in the modern client.
- No more error every second when the game hides your movement speed.
