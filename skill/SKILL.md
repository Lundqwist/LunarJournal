---
name: wow-story
description: Write the next chapter of a WoW: Forever character's story from the Lunar Journal addon's saved data, told by the character himself, years later, as his own memories, and post it to his story page on lundqwist.se/wowcharacters. Use when the user asks for a new story, chapter or memory for one of their WoW characters, or runs /wow-story.
argument-hint: "[character, e.g. Lunamal-Sunshadow] [draft]"
---

# Write a chapter of a character's memories

The Lunar Journal addon (`E:\ProjectsCoding\LunarJournal`) writes down what a character does in
WoW: Forever: quests and who gave them, the NPCs and players met, time spent running, riding,
fishing, crafting and gathering, zones, deaths, level ups, the in-game time of day, and the
player's own `/lj note` lines. Your job: turn the sessions that aren't told yet into one new
chapter of the character's story and put it on his story page.

## 1. Find the character and his untold sessions

```powershell
python -I E:\ProjectsCoding\LunarJournal\agent\journal.py list
python -I E:\ProjectsCoding\LunarJournal\agent\journal.py untold <Character-Surname>
```

- The argument (if given) names the character, e.g. `Lunamal-Sunshadow` or just `Lunamal`. With
  no argument, take the one with untold sessions; if several have them, ask which.
- The game only saves the journal at logout or `/reload`. If `savedAt` is older than the user's
  latest play, say so: they can `/reload` in game and you read it again.
- No untold sessions: say so and stop.
- The character must be in `Z:\wowcharacters\data\characters.json` (Forever entries, the `name`
  is the slug, the same as the journal's `slug`). If he isn't, ask before adding him there.

## 2. Read what has been written before

The story file is `Z:\wowcharacters\data\stories\forever\<slug>.md`. Read it if it exists, so
the new chapter carries on from the last one: same voice, no repeated memories, the same names
for the same people.

## 3. Write the chapter

**Who is speaking.** The character himself, many years from now, old and looking back. He is
telling his memories in the first person, the way someone tells a story by a fire: "I remember
the first time Dizzywig sent me out onto the salt flats..." He knows how things turned out, so he
can hint at it ("I didn't know then that I would walk that road a hundred times more"), but he
never invents later events that would clash with what the journal may show in future chapters.
His race, class, sex and guild are in `info`; speak like that kind of person would. (This page
says "he"; for a female character it's "she", from `info.sex`.)

**What is true.** Everything that *happened* comes from the journal: which quests, who gave
them and who took them back, where, which zones, who he grouped with, what he fished, made and
gathered, what killed him, when he levelled. Don't add quests, people or places that aren't there.
What you *may* add is what a memory adds: feelings, the weather, smells, what he thought of
someone, small details of the place that fit the zone in the game world.

**Use the details, they are what makes it his.**
- In-game time of day (`g` on each event, `gameTimeAtStart`): dawn, a hot noon, quests handed
  in after dark, a long night of fishing.
- The minutes and yards: long walks ("I must have run half of the Needles that day"), long
  rides, the hours at the water's edge, the time at the anvil or the cooking fire.
- Quest texts (`questDetails[...].text` and `.objective`): use them to know what the quest giver
  wanted and why. Retell it in his words; never copy more than a few words of the game's text.
- `npc` entries with `as` (vendor, trainer, flight master, innkeeper...): the people of his road.
- `note` entries are the player's own words about the moment: always use them, they matter most.
- Players met (`group_join`, `trade`, `duel`): name them as companions, briefly. Don't make up
  anything about them as people beyond what they did together.
- Deaths: memories of pain or narrow escapes, named after `by`.
- Leave out plain counting ("I killed 12 Puddlejumpers"); turn numbers into a feeling, unless one
  number is worth saying out loud.

**Shape.** One chapter for all the untold sessions (or one per clear stretch if there are many
days). 400 to 900 words. Pick the moments that make a story: the start, a turn, an end; you don't
have to mention every event. Markdown:

```markdown
### <A title in his words>

*<Real date(s) of the sessions> · <zones> · level <from>–<to>*

<the memory, in paragraphs>
```

The chapter heading is `###` (the page already has a "Story" heading). No HTML (the site shows it
as text). If the file is new, start it with the chapter; no title or intro above it.

## 4. Post it

- With `draft` in the arguments: show the chapter and stop. Don't write any file or mark anything.
- Otherwise: append the chapter to `Z:\wowcharacters\data\stories\forever\<slug>.md` (create the
  file if it's missing; one blank line between chapters; UTF-8 without BOM). The site reads it on
  every request, so it is live at once. Don't change earlier chapters unless the user asks.
- Then mark the sessions as told, with the id of the last session you used:

```powershell
python -I E:\ProjectsCoding\LunarJournal\agent\journal.py mark <Character-Surname> <last session id>
```

- Tell the user the chapter title and the page:
  `https://lundqwist.se/wowcharacters/forever/character.html?c=<slug>`. If `Z:` isn't there (the
  NAS share not mapped), don't mark anything; show the chapter and say it couldn't be posted.
