# SourceMod-DamageReport
"fork" from original creator Gemeni https://forums.alliedmods.net/showthread.php?t=64661  
original work by:  
  Developed:   
  2007-12-20  
  By:  
  [30+]Gemeni (gemeni@30plus.ownit.se)  
    
Shows a left side menu when you die or at the end of the round, saying who you did and took damage from and how much, including how many hits and who killed you.

## Install

1. Download `sm_damagereport-<version>.zip` from the [latest release](https://github.com/Ballganda/SourceMod-DMGreport/releases/latest) and extract it into the server's `cstrike` folder. It contains:
   - `addons/sourcemod/plugins/sm_damagereport.smx`: the plugin
   - `addons/sourcemod/scripting/sm_damagereport.sp` and `scripting/include/instance_config.inc`: the source, needed only to recompile
   - `addons/sourcemod/scripting/sm_damagereport-LICENSE.txt`: the GPL v3 license text
2. Restart the server or change the map.
3. Check: `sm plugins list` shows `Damage report (<version>)`.

Requires SourceMod 1.12 or later.

## Player commands

| Command | Does |
| --- | --- |
| `/drs` (or `/damage_report`) `on`, `off` | Turns your report on or off. |
| `/drs popup`, `/drs chat` | Shows the report in a panel or in chat. |
| `/drs long`, `/drs short` | Shows or hides the hits and damage per body part, for example `Head:1 (98) Chest:2 (54)`. |
| `/drs status` | Shows your settings. |
| `/dr` (or `/ldr`, `/dmg`, `/last_damage_report`) | Shows your last report again. |
| `/dr help` | Lists the commands. |

`/drs` changes your settings. `/dr` shows your report.

At round end every player gets two chat lines, the round awards. In popup mode (the default) these are the only lines in chat; the report itself is in the panel:

```
theREG...>DMG<: Alpha, 158 dmg in 3 hits
theREG...>KILLS<: Alpha, 1 kill
```

## Configuration

### Cvars

| Cvar | Default | Meaning |
| --- | --- | --- |
| `sm_damagereport_prefix` | `[theREG...]` | Text shown before the plugin's chat messages. Plain text: the plugin shows it in green. |
| `sm_damagereport_awards_prefix` | `theREG...` | Text before the round award lines. |
| `sm_damagereport_awards_color_prefix` | `40FF40` | Color of the award prefix (green). Each color cvar takes a 6-digit hex color `RRGGBB`. A wrong value is logged and set back to the default. |
| `sm_damagereport_awards_color_label` | `FF4040` | Color of `>DMG<:` and `>KILLS<:` (red). |
| `sm_damagereport_awards_color_name` | `99CCFF` | Color of the player name (light blue). |
| `sm_damagereport_awards_color_stat` | `FFD700` | Color of the numbers (gold). |
| `sm_damagereport_panel_title` | `theREG...DMGreport:` | Title line of the report panel. |
| `sm_damagereport_access_admin_only` | `0` | `1`: only admins with `sm_damagereport_access_admin_flags` get reports and the commands. Other players get "Damage report is for admins only". |
| `sm_damagereport_awards_admin_only` | `0` | `0`: every player sees the round awards. `1`: only admins with `sm_damagereport_access_admin_flags` see them. It does not depend on `sm_damagereport_access_admin_only`. |
| `sm_damagereport_access_admin_flags` | `b` | Admin flags for both admin-only cvars, for example `b` or `z`. Root admins always have access. An admin override named `sm_damagereport_access` changes the flags too. |
| `sm_damagereport_version` | build | The plugin version. Read only. |

### Config file

The plugin keeps its settings in its own file, one per SourceMod install:

```
cstrike/addons/sourcemod/configs/sm_damagereport.cfg
```

- The plugin creates the file the first time it loads, with each setting at its default. A comment above each setting gives its description and default.
- When a later version adds a setting, the plugin appends it with its default to the end of your file. It never changes or reorders your own lines.
- The plugin reads the file on every map, after the server's own configs (`server.cfg` and the rest). A value in this file therefore wins over the same cvar in `server.cfg`. Edit this file, not `server.cfg`.
- Format: one `cvar value` per line. A value can be in quotes (`sm_damagereport_prefix "[My server]"`) and can have `;` or a `// comment` after it. Lines that start with `//` or `;` are comments. The plugin ignores blank lines.
- The plugin applies only its own cvars (the table above, except `sm_damagereport_version`). It skips a line that names any other cvar and writes the name to the SourceMod log once.
- Messages go to the SourceMod logs (`addons/sourcemod/logs/L<date>.log`): when the plugin creates the file or appends entries, when it cannot read or write the file, and when it skips a line.
- Servers that share one set of game files but use different SourceMod folders (`+sm_basepath`) each get their own file.

A new file:

```
// Settings of sm_damagereport.smx, in this server's own SourceMod folder.
// Applied on every map change. Lines are: name value  ("//" and ";" start a comment).
// Entries missing here are appended automatically when the plugin loads; existing lines are never changed.

// Text shown before damage report chat messages
// Default: [theREG...]
sm_damagereport_prefix "[theREG...]"
```

To change a setting for one session only, set the cvar in the server console or over rcon. The plugin reads the file again on the next map, and the file value comes back.

### Player settings

Each player's `/drs` choices (on or off, popup or chat, short or long) are kept in `configs/damagereportusersettings.cfg`. The plugin writes this file itself. Do not edit it.

## Build

Requirements: Windows PowerShell 5.1 and a SourceMod 1.12 install that has `scripting\spcomp.exe`.

The shared include `instance_config.inc` comes from the `incs` git submodule ([SourceMod-Incs](https://github.com/Ballganda/SourceMod-Incs)). Clone with `git clone --recurse-submodules`, or run `git submodule update --init` in an existing clone. Without it, `build.ps1` stops with that command in its error.

1. Set `SOURCEMOD_DIR` to the `addons\sourcemod` folder of your install. If you do not set it, the script uses `C:\Users\user\cssds\cstrike\addons\sourcemod`.
2. Run the build:

   ```powershell
   .\build.ps1
   ```

The script compiles `scripting\*.sp` (the plugin) and `tests\*.sp` (the test suite) into `plugins\`. To also copy the `.smx` files into a SourceMod install, add `-DeployTo <addons\sourcemod folder>`.

To install the plugin, copy `plugins\sm_damagereport.smx` to `addons\sourcemod\plugins` on your server. Do not install `damagereport_tests.smx` on a live server.

## Test

`test.ps1` builds the plugins and starts a Counter-Strike: Source dedicated server (srcds). It runs the suite `tests\damagereport_tests.sp`, then checks the logs. Then it removes every file it deployed. Exit code 0 is a pass, 1 is a fail, 2 means the run could not start.

| Command | What it does |
| --- | --- |
| `.\test.ps1` | Runs on a free test slot from `srcds-slot.ps1`. Only the 6 cases that need no real player run; the other 8 report SKIP. |
| `.\test.ps1 -ServerDir <srcds folder> -Port <port>` | Runs on that server instead of a slot. The server must not be running. |
| `.\test.ps1 -WithClient` | Also starts the CS:S client, so all 14 cases run. Do not touch the game window during the run (about 5 minutes). |
| `.\test.ps1 -InjectError` | Self-check: the suite writes a deliberate error. This run must fail. |

The run passes when the last line is `RESULT: PASS`. The results of each case are also in `addons\sourcemod\logs\damagereport_tests.log` on the test server.

Notes:

- `CSS_SERVER_DIR` and `CSS_CLIENT_DIR` set the server and client folders.
- The panel cases check that the report panel is open. A plugin cannot read the text of a SourceMod panel. The chat-mode case checks the report text, which is the same text the panel shows.
- The config cases write their own `configs/sm_damagereport.cfg` and reload the plugin. Each case puts the file back when it ends.

## Changes in 2.2.0

Changes since 2.1.0:

- The prefix is green and the message text after it is in the default chat color. Every chat line of the plugin except the round awards starts with this prefix, the chat-mode headers included.
- The round awards have one format, in four colors: the prefix green, the label red, the player name light blue, the numbers gold. New cvars set the prefix (`sm_damagereport_awards_prefix`) and each of the four colors (`sm_damagereport_awards_color_*`).
  - `theREG...>DMG<: Alpha, 158 dmg in 3 hits`
  - `theREG...>KILLS<: Alpha, 1 kill`
- New cvars `sm_damagereport_access_admin_only` and `sm_damagereport_access_admin_flags`: admin-only mode. See **Cvars**.
- New cvar `sm_damagereport_awards_admin_only`: the round awards go to every player or only to admins.
- New cvar `sm_damagereport_panel_title` (default `theREG...DMGreport:`): the title line of the report panel.
- The long report shows the damage per body part after the hit count: `Head:1 (98) Chest:2 (54)`. Before, it showed only the hits.
- `/dr help` lists the commands. The panel footer says `Type "/dr help" in chat for commands`.
- Fixed: after a plugin reload during a map, the report and the awards showed empty player names.

Tested: regression suite with the real CS:S client (`test.ps1 -WithClient`), 14 passed, 0 failed, 0 skipped.

## Changes in 2.1.0

Changes since 2.0.0-b1:

- The plugin is licensed under GPL v3, as SourceMod requires. `sm_damagereport.sp` starts with the GPL notice, and the release zip has the license text.
- New cvar `sm_damagereport_prefix` (default `[theREG...]`): the text before every chat message of the plugin.
- Settings are kept in `addons/sourcemod/configs/sm_damagereport.cfg`, one file per SourceMod folder. See **Config file**.
- The player settings moved from `data/damagereportsetting.txt` to `configs/damagereportusersettings.cfg`. The plugin copies an old file across the first time it loads.
- New command `/drs`, the same as `/damage_report`.
- `/dr` now shows the last report, the same as `/ldr`. Before, it was the same as `/damage_report`. New command `/dmg` also shows the last report.
- Damage from the world (falls, the bomb) is listed as `WORLD`.
- Long player names are shortened so the report lines stay readable.
- Hits that do no damage are not counted.
- The short or long choice of a player without saved settings now defaults to long. Before, it took the popup or chat default by mistake.
- The plugin stops trying to show the report panel after 8 seconds when another menu stays open.
- Out-of-range client indexes from events are ignored.

Tested: regression suite with the real CS:S client (`test.ps1 -WithClient`), 12 passed, 0 failed, 0 skipped.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE). SourceMod requires plugins to use GPL v3 ([SourceMod license](https://www.sourcemod.net/license.php)).
