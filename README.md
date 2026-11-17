# Lunar Journal

A World of Warcraft: Forever addon that keeps a journal of your character's adventures, and a
Claude Code skill that turns that journal into the character's own memories on
[lundqwist.se/wowcharacters](https://lundqwist.se/wowcharacters/forever/).

## In the game

The addon writes down, per play session, with the real time and the in-game time of day:

- **Quests**: who offered them and where (with the quest text), accepted, turned in (to whom,
  XP and money), abandoned
- **People**: NPCs you talk to (quest givers, vendors, trainers, flight masters, innkeepers,
  bankers, auctioneers, stable masters), players you group with, trade with or duel
- **Time**: running, riding, swimming, flight paths, as a ghost, in combat, idle, resting, and
  the distance covered; time in each zone
- **Professions**: time fishing and what you caught, time crafting and what you made, gathering
  (mining, herbalism, skinning) and what you got
- **The rest**: level ups, deaths (and what killed you), hearthstone trips, flights, kills (rare
  and elite ones by name), rare and better loot, money gained and spent, screenshots
- **Your own notes**: `/lj note Met an old orc at the crossroads who smelled of fish`

Chat is never recorded and nothing is sent anywhere. The journal is saved per character in
`WTF\Account\<account>\<realm>\<Character>\SavedVariables\LunarJournal.lua` when you log out or
`/reload`.

| Command | |
|---|---|
| `/lj` | show or hide the journal window (this session's summary and latest entries) |
| `/lj note <text>` | write your own line in the journal |
| `/lj pause` | pause or resume the journal |
| `/lj options` | the options page (Options → AddOns → Lunar Journal) |
| `/lj forget yes` | delete this character's whole journal |

Like the other Lunar mods it has its own minimap button and can be linked to
[LunarMods](https://github.com/Lundqwist/LunarMods).

Install: `.\install.ps1` (links this folder into the game's AddOns folder), then `/reload`.

## Outside the game: the story

`agent\journal.py` reads the saved journal (it never writes to it) and gives the sessions that
aren't in a story yet as JSON; `skill\SKILL.md` is a Claude Code skill, `/wow-story`, that
writes the next chapter from that and appends it to the character's story file in the
WowCharacters site's data folder (`Z:\wowcharacters\data\stories\forever\<character>.md`), where
it is live at once.

The chapters are told by the character himself, many years later, remembering.

```powershell
.\install-skill.ps1                      # once: links skill\ into ~\.claude\skills\wow-story
python -I agent\journal.py list          # which characters have a journal, how much is untold
```

In Claude Code: `/wow-story Lunamal-Sunshadow` (posts it), or `/wow-story Lunamal draft` (only
shows it). Which sessions are told is kept in `agent\told.json` (not in git).
