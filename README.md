# SourceMod-DamageReport
"fork" from original creator Gemeni https://forums.alliedmods.net/showthread.php?t=64661  
original work by:  
  Developed:   
  2007-12-20  
  By:  
  [30+]Gemeni (gemeni@30plus.ownit.se)  
    
Shows a left side menu when you die or at the end of the round, saying who you did and took damage from and how much, including how many hits and who killed you.

## Build

Requirements: Windows PowerShell 5.1 and a SourceMod 1.12 install that has `scripting\spcomp.exe`.

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
| `.\test.ps1` | Runs on a free test slot from `srcds-slot.ps1`. Only the 3 cases that use fake clients run; the other 6 report SKIP. |
| `.\test.ps1 -ServerDir <srcds folder> -Port <port>` | Runs on that server instead of a slot. The server must not be running. |
| `.\test.ps1 -WithClient` | Also starts the CS:S client, so all 9 cases run. Do not touch the game window during the run (about 5 minutes). |
| `.\test.ps1 -InjectError` | Self-check: the suite writes a deliberate error. This run must fail. |

The run passes when the last line is `RESULT: PASS`. The results of each case are also in `addons\sourcemod\logs\damagereport_tests.log` on the test server.

Notes:

- `CSS_SERVER_DIR` and `CSS_CLIENT_DIR` set the server and client folders.
- The panel cases check that the report panel is open. A plugin cannot read the text of a SourceMod panel. The chat-mode case checks the report text, which is the same text the panel shows.
