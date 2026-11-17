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

## Outside the game: StoryMaker

`StoryMaker\` is a Windows program (.NET 8, WinForms) that turns the journal into the character's
story and posts it to his page on [lundqwist.se/wowcharacters](https://lundqwist.se/wowcharacters/forever/).
The chapters are told by the character himself, many years later, remembering.

1. Pick the **character** (every `LunarJournal.lua` under the game's `WTF\Account` folder).
2. Tick the **play sessions** the chapter should cover (those not in the story yet are ticked).
3. Pick the **AI** and the model: **Ollama** (free, runs on your own PC), Claude (Anthropic's official
   C# SDK), OpenAI, Gemini, or any OpenAI-compatible server (LM Studio, OpenRouter...). Optionally
   write wishes for the chapter.
4. **Write chapter**: it reads the story so far from the site, sends it and the journal to the AI,
   and shows the chapter. Edit it as you like.
5. **Post to lundqwist.se**: adds the chapter to the end of the story (the site keeps the old
   version in `stories\forever\.history`) and marks the ticked sessions as told.

```powershell
StoryMaker\install.ps1        # builds it to %LOCALAPPDATA%\LunarJournal\StoryMaker, adds a Start menu shortcut
```

**Free, with Ollama:** install [Ollama](https://ollama.com) (`winget install Ollama.Ollama`) and a
model (`ollama pull gemma3:12b`, about 8 GB, fits a 12 GB graphics card). StoryMaker uses Ollama's own
API so it can give the model a context large enough for the whole journal (Ollama's default would
silently cut it). No key, no cost, nothing leaves the PC except the finished chapter.

Keys for the paid AIs are never stored by the program, only the names of the Windows user environment variables
that hold them (Settings shows which are found):

```powershell
setx ANTHROPIC_API_KEY "..."   # or OPENAI_API_KEY / GEMINI_API_KEY; a local AI needs none
setx STORY_TOKEN "..."         # the same value as STORY_TOKEN in the site's .env
```

Posting uses the WowCharacters site's story API (`GET`/`POST /api/forever/story?c=<character>`,
`Authorization: Bearer <STORY_TOKEN>`; see [WowCharacters](https://github.com/Lundqwist/WowCharacters)).
The character must be in the site's `characters.json`; its key is the journal's folder name in lower
case (`Lunamal-Sunshadow` → `lunamal-sunshadow`). Settings and which sessions are told:
`%APPDATA%\LunarJournal\StoryMaker.json`.

## Outside the game: the Claude Code skill

An older way that needs no API key, only Claude Code: `agent\journal.py` reads the saved journal (it never writes to it) and gives the sessions that
aren't in a story yet as JSON; `skill\SKILL.md` is a Claude Code skill, `/wow-story`, that
writes the next chapter from that and appends it to the character's story file in the
WowCharacters site's data folder (`Z:\wowcharacters\data\stories\forever\<character>.md`), where
it is live at once. It keeps its own list of told sessions (`agent\told.json`), separate from
StoryMaker's.

```powershell
.\install-skill.ps1                      # once: links skill\ into ~\.claude\skills\wow-story
python -I agent\journal.py list          # which characters have a journal, how much is untold
```

In Claude Code: `/wow-story Lunamal-Sunshadow` (posts it), or `/wow-story Lunamal draft` (only
shows it). Which sessions are told is kept in `agent\told.json` (not in git).
