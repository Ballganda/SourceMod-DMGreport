# SourceMod-DamageReport
"fork" from original creator Gemeni https://forums.alliedmods.net/showthread.php?t=64661  
original work by:  
  Developed:   
  2007-12-20  
  By:  
  [30+]Gemeni (gemeni@30plus.ownit.se)  
    
Shows a left side menu when you die or at the end of the round, saying who you did and took damage from and how much, including how many hits and who killed you.

## Configuration

### Cvars

| Cvar | Default | Meaning |
| --- | --- | --- |
| `sm_damagereport_prefix` | `[theREG...]` | Text shown before the plugin's chat messages. |
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
| `.\test.ps1` | Runs on a free test slot from `srcds-slot.ps1`. Only the 6 cases that need no real player run; the other 6 report SKIP. |
| `.\test.ps1 -ServerDir <srcds folder> -Port <port>` | Runs on that server instead of a slot. The server must not be running. |
| `.\test.ps1 -WithClient` | Also starts the CS:S client, so all 12 cases run. Do not touch the game window during the run (about 5 minutes). |
| `.\test.ps1 -InjectError` | Self-check: the suite writes a deliberate error. This run must fail. |

The run passes when the last line is `RESULT: PASS`. The results of each case are also in `addons\sourcemod\logs\damagereport_tests.log` on the test server.

Notes:

- `CSS_SERVER_DIR` and `CSS_CLIENT_DIR` set the server and client folders.
- The panel cases check that the report panel is open. A plugin cannot read the text of a SourceMod panel. The chat-mode case checks the report text, which is the same text the panel shows.
- The config cases write their own `configs/sm_damagereport.cfg` and reload the plugin. Each case puts the file back when it ends.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE). SourceMod requires plugins to use GPL v3 ([SourceMod license](https://www.sourcemod.net/license.php)).
