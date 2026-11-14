**Guild invites that actually arrive, and search notes that tell the whole story.**

Since launch, WoW Forever has blocked guild invites sent by addon code. Torchcall kept counting them anyway: you pressed Invite, the game quietly refused it, and the player was marked invited without ever seeing an invite. If your invites never seemed to get declined, this is why. The whispers were never affected.

Invite now opens a small box holding `/ginvite First Last`, already selected. Press Ctrl+C, then Enter, Ctrl+V, Enter. That sends the invite through the game's own command, which still works. The row shows **invite ready** until the game prints "You have invited..." and only then does it count as an invite. Cancel clears it, and an unused one expires after ten minutes. Torchcall also keeps you inside the game's limit of 10 guild invites a minute.

On your first login, Torchcall fixes your history once. Everyone it wrongly marked as invited since launch goes back to whispered, because they did get your opener, and your invite totals are corrected to match. Nobody is added back to the list and nobody gets asked twice.

Search notes now count everyone without a guild, not only the players who are new to you. Instead of "0 new without a guild" you see "Of the 50 shown, 9 have no guild: 1 new, 8 already on your list." When everyone in a range has already heard from you, the note says so and suggests other levels or classes. Searches also wait up to 30 seconds for a slow answer from the server instead of 6, and every search writes a line to the debug log.

Offline checks: 1,425 tests and several 750,000 step soaks, all green, and the design went through a council review first. The copy box and the invite confirmation have not been played on the live realm yet, so if either acts up, say so in the addons channel.

**How to update:** on CurseForge, hit Update. With Yeeterson Forge it arrives by itself. By hand: download the zip below, close the game fully, replace the `Torchcall` folder in `_forever_/Interface/AddOns/`. Your prospects, stats and settings are kept.
