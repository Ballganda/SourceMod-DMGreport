// Regression suite for sm_damagereport.smx (Panel version).
// Run by hand with "dr_test" on the server console, or unattended with +dr_test_autorun 1 (test.ps1).
// Results go to logs/damagereport_tests.log. Cases marked "real client" need a human player and SKIP without one.
#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_FILE "sm_damagereport.smx"
#define SETTINGS_FILE "configs/damagereportusersettings.cfg"
#define CONFIG_FILE "configs/sm_damagereport.cfg"
#define PREFIX_CVAR "sm_damagereport_prefix"
#define DEFAULT_PREFIX "[theREG...]"
#define TEST_PREFIX "[cfg test]"
#define CONFIG_LEN 4096
#define ADMIN_ONLY_CVAR "sm_damagereport_access_admin_only"
#define ADMIN_FLAGS_CVAR "sm_damagereport_access_admin_flags"
#define TEST_ADMIN_FLAGS "o"
#define AWARDS_ADMIN_CVAR "sm_damagereport_awards_admin_only"
#define TITLE_CVAR "sm_damagereport_panel_title"
#define DEFAULT_TITLE "theREG...DMGreport:"
// Award lines: green prefix, default text, light green name.
#define AWARD_DAMAGE "\x0740FF40theREG...\x07FF4040>DMG<: \x0799CCFF"
#define AWARD_KILLS "\x0740FF40theREG...\x07FF4040>KILLS<: \x0799CCFF"
#define AWARD_STAT "\x07FFD700"
// A reloaded plugin runs OnPluginStart and, loaded late, OnConfigsExecuted at once.
#define RELOAD_WAIT 1.5
#define NAME_LEN 96
#define CAPTURE_LEN 4096
#define MAX_ATTEMPTS 3 // a case is rerun if the game restarted the round under it
#define STEP_SLOTS 100 // steps per case in a timer value
#define FAKE_ATTACKER "DRFakeAttacker"
#define FAKE_VICTIM "DRFakeVictim"
#define HIT_DAMAGE 20.0
#define KILL_DAMAGE 500.0
// The plugin shows its panel 1 s after death and retries each second while another menu is open.
#define REPORT_WAIT 3.0
// The plugin writes changed settings at most once per 5 s; wait a little longer.
#define SAVE_WAIT 6.5
#define SETTINGS_SENTINEL "// dr_test sentinel"
#define COMMAND_SPAM 5
#define LOADING_POLLS 600 // 0.1 s apart: 60 s for the client to reconnect after the map change
// A control byte would recolor the award line; a name over 21 bytes is cut at byte 18.
#define FAKE_CONTROL_NAME "DRFake\x03Ctl"
#define FAKE_CONTROL_SHOWN "DRFakeCtl"
#define FAKE_UTF8_NAME "DRFakeaÄÄÄÄÄÄÄÄÄÄÄ"
#define FAKE_UTF8_SHOWN "DRFakeaÄÄÄÄÄ..."

enum
{
	C_LOADED,
	C_SETTINGS_FILE,
	C_CONFIG_CREATED,
	C_CONFIG_APPLIED,
	C_CONFIG_APPENDED,
	C_FAKE_FIGHT,
	C_DEATH_PANEL,
	C_LAST_REPORT,
	C_HELP,
	C_CHAT_MODE,
	C_OFF,
	C_ROUND_END_ALIVE,
	C_ADMIN_ONLY,
	C_AWARDS_AUDIENCE,
	C_SETTINGS_WRITES,
	C_SETTINGS_RELOAD,
	C_NAME_SAFE,
	C_NOT_IN_GAME, // changes the map, so it runs last
	NUM_CASES
}

char g_caseNames[NUM_CASES][NAME_LEN];
bool g_needsClient[NUM_CASES];
char g_logPath[PLATFORM_MAX_PATH];

int g_curCase = -1;
bool g_caseActive;
bool g_running;
int g_pass;
int g_fail;
int g_skip;
int g_attempt = 1;
int g_waited;
int g_errSizeAtStart;
bool g_selfFire;
bool g_interfered;
int g_origIgnoreWin = -1;
int g_origAutokick = -1;

int g_uidAttacker;
int g_uidVictim;

// Chat a real client was sent during the case (SayText*, TextMsg).
char g_chatText[CAPTURE_LEN];
bool g_menuBeforeKill;

// The plugin's config file as it was before a config case changed it.
char g_configBackup[CONFIG_LEN];
bool g_configBackedUp;
bool g_configExisted;

ConVar g_cvAutorun;
ConVar g_cvInjectError;
ConVar g_cvWaitClient;

public Plugin myinfo =
{
	name = "Damage report tests",
	author = "test",
	description = "Regression tests for sm_damagereport",
	version = "1.0.0",
	url = ""
};

public void OnPluginStart()
{
	BuildPath(Path_SM, g_logPath, sizeof(g_logPath), "logs/damagereport_tests.log");

	SetCase(C_LOADED, "plugin running, cvars and commands exist", false);
	SetCase(C_SETTINGS_FILE, "settings file created in SourceMod configs", false);
	SetCase(C_CONFIG_CREATED, "config file created with the prefix cvar at its default", false);
	SetCase(C_CONFIG_APPLIED, "config file value applied, foreign cvar skipped", false);
	SetCase(C_CONFIG_APPENDED, "missing config entry appended, own lines kept", false);
	SetCase(C_FAKE_FIGHT, "fake vs fake damage, death, world damage, round end raise no error", false);
	SetCase(C_DEATH_PANEL, "real client: killed player gets the report panel", true);
	SetCase(C_LAST_REPORT, "real client: dr shows the last report again", true);
	SetCase(C_HELP, "real client: dr help lists the commands", true);
	SetCase(C_CHAT_MODE, "real client: drs chat prints the report in chat, no panel", true);
	SetCase(C_OFF, "real client: drs off shows no report", true);
	SetCase(C_ROUND_END_ALIVE, "real client: alive player gets the report panel, both award lines and no report text in chat at round end", true);
	SetCase(C_ADMIN_ONLY, "real client: admin-only mode hides reports from non-admins, admin flag gives access", true);
	SetCase(C_AWARDS_AUDIENCE, "real client: awards reach all players or only admins, apart from report access", true);
	SetCase(C_SETTINGS_WRITES, "real client: drs commands that change nothing do not write the settings file; a burst of changes is written once, later", true);
	SetCase(C_SETTINGS_RELOAD, "real client: a setting changed just before a plugin reload is kept", true);
	SetCase(C_NAME_SAFE, "real client: award names lose control bytes and are cut on a whole UTF-8 character", true);
	SetCase(C_NOT_IN_GAME, "real client: dr and drs from a client that is still loading raise no error", true);

	RegServerCmd("dr_test", Cmd_RunTests, "Run the damage report regression tests");
	g_cvAutorun = CreateConVar("dr_test_autorun", "0", "Run the suite on map start and quit when done <1|0>.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvInjectError = CreateConVar("dr_test_inject_error", "0", "Log a deliberate error to prove error detection <1|0>.", FCVAR_NONE, true, 0.0, true, 1.0);
	g_cvWaitClient = CreateConVar("dr_test_wait_client", "0", "Autorun waits up to 180 s for a real client <1|0>.", FCVAR_NONE, true, 0.0, true, 1.0);

	static const char chatMsgs[][] = { "SayText", "SayText2", "TextMsg" };
	for (int i = 0; i < sizeof(chatMsgs); i++)
	{
		UserMsg id = GetUserMessageId(chatMsgs[i]);
		if (id != INVALID_MESSAGE_ID)
			HookUserMessage(id, OnChatMsg);
	}
	HookEvent("round_start", OnRoundStartSeen, EventHookMode_PostNoCopy);
}

void SetCase(int c, const char[] name, bool needsClient)
{
	strcopy(g_caseNames[c], NAME_LEN, name);
	g_needsClient[c] = needsClient;
}

//===== Capture =====

bool SentToHuman(const int[] players, int playersNum)
{
	for (int i = 0; i < playersNum; i++)
		if (!IsFakeClient(players[i]))
			return true;
	return false;
}

public Action OnChatMsg(UserMsg id, BfRead bf, const int[] players, int playersNum, bool reliable, bool init)
{
	if (!g_caseActive || !SentToHuman(players, playersNum))
		return Plugin_Continue;
	// The layout differs per message type, so keep the raw payload.
	char raw[512];
	int n = 0;
	while (bf.BytesLeft > 0 && n < sizeof(raw) - 2)
	{
		int b = bf.ReadByte();
		raw[n++] = view_as<char>((b == 0) ? 32 : b);
	}
	raw[n++] = '\n';
	raw[n] = '\0';
	StrCat(g_chatText, sizeof(g_chatText), raw);
	return Plugin_Continue;
}

void ResetCapture()
{
	g_chatText[0] = '\0';
}

bool ChatHas(const char[] text)
{
	return StrContains(g_chatText, text) != -1;
}

//===== Suite control =====

public void OnRoundStartSeen(Event event, const char[] name, bool dontBroadcast)
{
	if (g_running && g_caseActive && !g_selfFire)
		g_interfered = true;
}

public void OnMapStart()
{
	if (g_cvAutorun.BoolValue && !g_running)
		CreateTimer(15.0, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Autorun(Handle timer)
{
	if (g_cvWaitClient.BoolValue && FindHuman() == 0 && g_waited < 180)
	{
		g_waited += 2;
		CreateTimer(2.0, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}
	if (g_cvWaitClient.BoolValue && g_waited >= 0 && FindHuman() != 0)
	{
		g_waited = -1; // let the client finish loading in
		CreateTimer(8.0, Timer_Autorun, _, TIMER_FLAG_NO_MAPCHANGE);
		return Plugin_Stop;
	}
	Cmd_RunTests(0);
	return Plugin_Stop;
}

public void OnPluginEnd()
{
	CleanupFakes();
	g_running = false;
	RestoreCvars();
	RestoreConfig();
}

public Action Cmd_RunTests(int args)
{
	if (g_running)
	{
		PrintToServer("[dr_test] already running");
		return Plugin_Handled;
	}
	// Fakes joining or dying would otherwise end the round and restart it under a later case.
	g_origIgnoreWin = SwapCvarInt("mp_ignore_round_win_conditions", 1);
	// The real client is idle on purpose.
	g_origAutokick = SwapCvarInt("mp_autokick", 0);

	g_running = true;
	g_attempt = 1;
	g_pass = 0;
	g_fail = 0;
	g_skip = 0;
	LogToFileEx(g_logPath, "=== damage report tests started (%d cases) ===", NUM_CASES);
	if (g_cvInjectError.BoolValue)
		LogError("[dr_test] deliberate error (dr_test_inject_error 1)");
	StartCase(0);
	return Plugin_Handled;
}

void StartCase(int c)
{
	g_curCase = c;
	g_interfered = false;
	g_errSizeAtStart = ErrorLogSize();
	if (g_needsClient[c] && FindHuman() == 0)
	{
		g_caseActive = true;
		SkipCase("no real client in game");
		return;
	}
	g_caseActive = true;
	FireNamedEvent("round_start"); // the plugin clears all damage on round_start
	ResetCapture();
	RunStep(c, 0);
}

void Schedule(float delay, int c, int step)
{
	CreateTimer(delay, Timer_Step, c * STEP_SLOTS + step, TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Step(Handle timer, any data)
{
	int c = view_as<int>(data) / STEP_SLOTS;
	int step = view_as<int>(data) % STEP_SLOTS;
	if (g_caseActive && c == g_curCase)
		RunStep(c, step);
	return Plugin_Stop;
}

void SkipCase(const char[] why)
{
	if (g_curCase == C_ADMIN_ONLY || g_curCase == C_AWARDS_AUDIENCE)
		ResetAdminOnly();
	LogToFileEx(g_logPath, "[SKIP] %s - %s", g_caseNames[g_curCase], why);
	PrintToServer("[SKIP] %s - %s", g_caseNames[g_curCase], why);
	g_skip++;
	g_attempt = 1;
	g_caseActive = false;
	CleanupFakes();
	CreateTimer(0.5, Timer_NextCase, g_curCase + 1, TIMER_FLAG_NO_MAPCHANGE);
}

void EndCase(bool ok, const char[] msg)
{
	if (!g_caseActive)
		return;
	if (g_curCase == C_ADMIN_ONLY || g_curCase == C_AWARDS_AUDIENCE)
		ResetAdminOnly();
	if (g_interfered && g_attempt < MAX_ATTEMPTS)
	{
		PrintToServer("[dr_test] real round_start during \"%s\" (attempt %d); retrying", g_caseNames[g_curCase], g_attempt);
		g_attempt++;
		g_caseActive = false;
		CleanupFakes();
		CreateTimer(1.5, Timer_NextCase, g_curCase, TIMER_FLAG_NO_MAPCHANGE);
		return;
	}
	if (g_interfered)
		LogToFileEx(g_logPath, "[WARN] game fired its own round_start during every attempt of \"%s\"", g_caseNames[g_curCase]);
	g_attempt = 1;

	char line[512];
	if (ok && ErrorLogSize() > g_errSizeAtStart)
	{
		ok = false;
		Format(line, sizeof(line), "[FAIL] %s - SourceMod logged errors during this case (see logs/errors_*.log)", g_caseNames[g_curCase]);
	}
	else
		Format(line, sizeof(line), "[%s] %s - %s", ok ? "PASS" : "FAIL", g_caseNames[g_curCase], msg);
	LogToFileEx(g_logPath, "%s", line);
	PrintToServer("%s", line);
	if (ok)
		g_pass++;
	else
	{
		g_fail++;
		LogCapture();
	}
	g_caseActive = false;
	CleanupFakes();
	CreateTimer(0.5, Timer_NextCase, g_curCase + 1, TIMER_FLAG_NO_MAPCHANGE);
}

// Context for a failed case: what the real client was sent.
void LogCapture()
{
	char flat[CAPTURE_LEN];
	int h = FindHuman();
	if (h != 0)
		LogToFileEx(g_logPath, "[INFO]   client menu source: %d (0 none, 1 external, 2 menu, 3 panel)", GetClientMenu(h));
	strcopy(flat, sizeof(flat), g_chatText);
	ReplaceString(flat, sizeof(flat), "\n", " | ");
	LogToFileEx(g_logPath, "[INFO]   chat text: %s", flat);
}

public Action Timer_NextCase(Handle timer, any next)
{
	int n = view_as<int>(next);
	if (n < NUM_CASES)
	{
		StartCase(n);
		return Plugin_Stop;
	}
	g_running = false;
	RestoreCvars();
	if (GetPluginStatus(FindPluginByFile(PLUGIN_FILE)) != Plugin_Running)
	{
		g_fail++;
		LogToFileEx(g_logPath, "[FAIL] %s is no longer running at the end of the suite", PLUGIN_FILE);
	}
	LogToFileEx(g_logPath, "tests finished: %d passed, %d failed, %d skipped", g_pass, g_fail, g_skip);
	PrintToServer("[dr_test] tests finished: %d passed, %d failed, %d skipped", g_pass, g_fail, g_skip);
	if (g_cvAutorun.BoolValue)
	{
		ServerCommand("sm plugins list");
		ServerCommand("sm exts list");
		CreateTimer(1.0, Timer_Quit);
	}
	return Plugin_Stop;
}

public Action Timer_Quit(Handle timer)
{
	ServerCommand("quit");
	return Plugin_Stop;
}

//===== Config file =====

void ConfigPath(char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, CONFIG_FILE);
}

bool ReadConfig(char[] text, int maxlen)
{
	text[0] = '\0';
	char path[PLATFORM_MAX_PATH], line[512];
	ConfigPath(path, sizeof(path));
	File f = OpenFile(path, "rb");
	if (f == null)
		return false;
	while (f.ReadLine(line, sizeof(line)))
		StrCat(text, maxlen, line);
	delete f;
	return true;
}

void WriteConfig(const char[] text)
{
	char path[PLATFORM_MAX_PATH];
	ConfigPath(path, sizeof(path));
	File f = OpenFile(path, "wb");
	if (f == null)
	{
		LogToFileEx(g_logPath, "[INFO]   cannot write %s", path);
		return;
	}
	f.WriteString(text, false);
	delete f;
}

// Keeps the current file so RestoreConfig can put it back, then writes text in its place.
void ReplaceConfig(const char[] text)
{
	if (!g_configBackedUp)
	{
		g_configExisted = ReadConfig(g_configBackup, sizeof(g_configBackup));
		g_configBackedUp = true;
	}
	WriteConfig(text);
}

void RestoreConfig()
{
	if (!g_configBackedUp)
		return;
	g_configBackedUp = false;
	if (g_configExisted)
		WriteConfig(g_configBackup);
	else
	{
		char path[PLATFORM_MAX_PATH];
		ConfigPath(path, sizeof(path));
		DeleteFile(path);
	}
}

//===== Cases =====

void RunStep(int c, int step)
{
	switch (c)
	{
		case C_LOADED: Case_Loaded();
		case C_SETTINGS_FILE: Case_SettingsFile();
		case C_CONFIG_CREATED: Case_ConfigCreated();
		case C_CONFIG_APPLIED: Case_ConfigApplied(step);
		case C_CONFIG_APPENDED: Case_ConfigAppended(step);
		case C_FAKE_FIGHT: Case_FakeFight(step);
		case C_DEATH_PANEL: Case_DeathPanel(step);
		case C_LAST_REPORT: Case_LastReport(step);
		case C_HELP: Case_Help(step);
		case C_CHAT_MODE: Case_ChatMode(step);
		case C_OFF: Case_Off(step);
		case C_ROUND_END_ALIVE: Case_RoundEndAlive(step);
		case C_ADMIN_ONLY: Case_AdminOnly(step);
		case C_AWARDS_AUDIENCE: Case_AwardsAudience(step);
		case C_SETTINGS_WRITES: Case_SettingsWrites(step);
		case C_SETTINGS_RELOAD: Case_SettingsReload(step);
		case C_NAME_SAFE: Case_NameSafe(step);
		case C_NOT_IN_GAME: Case_NotInGame(step);
	}
}

void Case_Loaded()
{
	Handle plugin = FindPluginByFile(PLUGIN_FILE);
	if (plugin == null || GetPluginStatus(plugin) != Plugin_Running)
	{
		EndCase(false, PLUGIN_FILE ... " is not running");
		return;
	}
	static const char cvars[][] = { "sm_damagereport_version", "sm_damagereport_prefix", ADMIN_ONLY_CVAR, ADMIN_FLAGS_CVAR, AWARDS_ADMIN_CVAR, TITLE_CVAR, "sm_damagereport_awards_prefix", "sm_damagereport_awards_color_prefix", "sm_damagereport_awards_color_label", "sm_damagereport_awards_color_name", "sm_damagereport_awards_color_stat" };
	for (int i = 0; i < sizeof(cvars); i++)
	{
		if (FindConVar(cvars[i]) == null)
		{
			char why[128];
			Format(why, sizeof(why), "cvar %s missing", cvars[i]);
			EndCase(false, why);
			return;
		}
	}
	static const char cmds[][] = { "damage_report", "drs", "last_damage_report", "ldr", "dmg", "dr" };
	for (int i = 0; i < sizeof(cmds); i++)
	{
		if (!CommandExists(cmds[i]))
		{
			char why[128];
			Format(why, sizeof(why), "command %s missing", cmds[i]);
			EndCase(false, why);
			return;
		}
	}
	EndCase(true, "plugin, 11 cvars and 6 commands present");
}

void Case_SettingsFile()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), SETTINGS_FILE);
	if (FileExists(path))
		EndCase(true, SETTINGS_FILE ... " exists");
	else
		EndCase(false, SETTINGS_FILE ... " was not created");
}

void Case_ConfigCreated()
{
	char text[CONFIG_LEN];
	if (!ReadConfig(text, sizeof(text)))
		EndCase(false, CONFIG_FILE ... " was not created");
	else if (StrContains(text, PREFIX_CVAR ... " \"" ... DEFAULT_PREFIX ... "\"") == -1)
		EndCase(false, CONFIG_FILE ... " has no " ... PREFIX_CVAR ... " entry at its default");
	else if (StrContains(text, ADMIN_ONLY_CVAR ... " \"0\"") == -1 || StrContains(text, ADMIN_FLAGS_CVAR ... " \"b\"") == -1)
		EndCase(false, CONFIG_FILE ... " lacks the admin-only cvars at their defaults");
	else if (StrContains(text, AWARDS_ADMIN_CVAR ... " \"0\"") == -1 || StrContains(text, TITLE_CVAR ... " \"" ... DEFAULT_TITLE ... "\"") == -1)
		EndCase(false, CONFIG_FILE ... " lacks the awards or panel title cvar at its default");
	else if (StrContains(text, "sm_damagereport_version") != -1)
		EndCase(false, CONFIG_FILE ... " holds the version cvar");
	else
		EndCase(true, CONFIG_FILE ... " holds " ... PREFIX_CVAR ... " \"" ... DEFAULT_PREFIX ... "\"");
}

void Case_ConfigApplied(int step)
{
	static int freezeBefore;
	switch (step)
	{
		case 0:
		{
			freezeBefore = FindConVar("mp_freezetime").IntValue;
			char text[256];
			Format(text, sizeof(text), "%s \"%s\" // quoted value with a comment\nmp_freezetime %d\n", PREFIX_CVAR, TEST_PREFIX, freezeBefore + 3);
			ReplaceConfig(text);
			ServerCommand("sm plugins reload sm_damagereport");
			Schedule(RELOAD_WAIT, C_CONFIG_APPLIED, 1);
		}
		case 1:
		{
			char prefix[64];
			ConVar cvPrefix = FindConVar(PREFIX_CVAR);
			cvPrefix.GetString(prefix, sizeof(prefix));
			int freeze = FindConVar("mp_freezetime").IntValue;
			RestoreConfig();
			cvPrefix.SetString(DEFAULT_PREFIX);

			char why[256];
			if (!StrEqual(prefix, TEST_PREFIX))
			{
				Format(why, sizeof(why), PREFIX_CVAR ... " is \"%s\", file set \"%s\"", prefix, TEST_PREFIX);
				EndCase(false, why);
			}
			else if (freeze != freezeBefore)
			{
				FindConVar("mp_freezetime").IntValue = freezeBefore;
				EndCase(false, "mp_freezetime from the file was applied");
			}
			else
				EndCase(true, PREFIX_CVAR ... " set from the file, mp_freezetime left alone");
		}
	}
}

void Case_ConfigAppended(int step)
{
	switch (step)
	{
		case 0:
		{
			ReplaceConfig("// own line\n");
			ServerCommand("sm plugins reload sm_damagereport");
			Schedule(RELOAD_WAIT, C_CONFIG_APPENDED, 1);
		}
		case 1:
		{
			char text[CONFIG_LEN];
			bool read = ReadConfig(text, sizeof(text));
			RestoreConfig();
			if (!read)
				EndCase(false, CONFIG_FILE ... " cannot be read");
			else if (StrContains(text, "// own line") != 0)
				EndCase(false, "the existing line was changed or moved");
			else if (StrContains(text, PREFIX_CVAR ... " \"" ... DEFAULT_PREFIX ... "\"") == -1)
				EndCase(false, PREFIX_CVAR ... " entry was not appended");
			else
				EndCase(true, PREFIX_CVAR ... " appended after the existing line");
		}
	}
}

void Case_FakeFight(int step)
{
	switch (step)
	{
		case 0:
		{
			if (!SpawnFakes())
			{
				EndCase(false, "could not create fake clients");
				return;
			}
			Schedule(1.0, C_FAKE_FIGHT, 1);
		}
		case 1:
		{
			int attacker = GetClientOfUserId(g_uidAttacker);
			int victim = GetClientOfUserId(g_uidVictim);
			if (attacker == 0 || victim == 0)
			{
				EndCase(false, "fake client is gone");
				return;
			}
			SDKHooks_TakeDamage(victim, attacker, attacker, HIT_DAMAGE, DMG_BULLET);
			SDKHooks_TakeDamage(attacker, 0, 0, HIT_DAMAGE, DMG_FALL); // world damage, attacker 0
			SDKHooks_TakeDamage(victim, attacker, attacker, KILL_DAMAGE, DMG_BULLET);
			Schedule(1.5, C_FAKE_FIGHT, 2);
		}
		case 2:
		{
			if (IsPlayerAlive(GetClientOfUserId(g_uidVictim)))
			{
				EndCase(false, "the victim did not die");
				return;
			}
			FireRoundEnd();
			Schedule(1.5, C_FAKE_FIGHT, 3);
		}
		case 3:
		{
			if (FindHuman() != 0 && !ChatHas(AWARD_DAMAGE ... FAKE_ATTACKER ... AWARD_STAT ... ", 520 dmg in 2 hits"))
			{
				EndCase(false, "the real client got no prefixed most-damage line for 520 dmg in 2 hits");
				return;
			}
			if (FindHuman() != 0 && !ChatHas(AWARD_KILLS ... FAKE_ATTACKER ... AWARD_STAT ... ", 1 kill"))
			{
				EndCase(false, "the real client got no prefixed most-kills line for 1 kill");
				return;
			}
			EndCase(true, "events handled without errors");
		}
	}
}

void Case_DeathPanel(int step)
{
	switch (step)
	{
		case 0: SetupHumanFight(C_DEATH_PANEL);
		case 1: HumanKilledByFake(C_DEATH_PANEL);
		case 2:
		{
			char why[256];
			if (CheckPanelAfterDeath(why, sizeof(why)))
				EndCase(true, "report panel open after death, none before");
			else
				EndCase(false, why);
		}
	}
}

void Case_LastReport(int step)
{
	switch (step)
	{
		case 0: SetupHumanFight(C_LAST_REPORT);
		case 1: HumanKilledByFake(C_LAST_REPORT);
		case 2:
		{
			int h = FindHuman();
			CancelClientMenu(h);
			if (GetClientMenu(h) != MenuSource_None)
			{
				EndCase(false, "the death panel could not be closed before dr");
				return;
			}
			FakeClientCommand(h, "dr");
			Schedule(REPORT_WAIT, C_LAST_REPORT, 3);
		}
		case 3:
		{
			if (GetClientMenu(FindHuman()) == MenuSource_RawPanel)
				EndCase(true, "dr opened the report panel again");
			else
				EndCase(false, "no panel open after dr");
		}
	}
}

void Case_Help(int step)
{
	switch (step)
	{
		case 0:
		{
			FakeClientCommand(FindHuman(), "dr help");
			Schedule(1.0, C_HELP, 1);
		}
		case 1:
		{
			if (ChatHas("/drs status") && ChatHas("/dr help (This list)"))
				EndCase(true, "help lines sent");
			else
				EndCase(false, "help lines not in chat");
		}
	}
}

void Case_ChatMode(int step)
{
	switch (step)
	{
		case 0:
		{
			FakeClientCommand(FindHuman(), "drs chat");
			SetupHumanFight(C_CHAT_MODE);
		}
		case 1:
		{
			if (!ChatHas("printed in chat"))
			{
				RestoreHumanSettings();
				EndCase(false, "no confirmation for drs chat");
				return;
			}
			HumanKilledByFake(C_CHAT_MODE);
		}
		case 2:
		{
			bool panel = GetClientMenu(FindHuman()) == MenuSource_RawPanel;
			RestoreHumanSettings();
			// Chat mode prints the same report text the panel shows, so the content is checked here.
			if (!ChatHas("--Attackers (Total dmg:540)--"))
				EndCase(false, "no Attackers header with 540 dmg in chat");
			else if (!ChatHas("X " ... FAKE_ATTACKER ... " [540 dmg, 3 hits] (Killer)"))
				EndCase(false, "attacker line lacks X, 540 dmg, 3 hits or (Killer)");
			else if (!ChatHas("Body:3 (540)"))
				EndCase(false, "no hits and damage per body part (Body:3 (540)) in the long report");
			else if (ChatHas("--Victims"))
				EndCase(false, "Victims section though the human hit no one");
			else if (panel)
				EndCase(false, "a panel was shown in chat mode");
			else
				EndCase(true, "report in chat with X, 540 dmg, 3 hits, (Killer), Body:3 (540); no panel");
		}
	}
}

void Case_Off(int step)
{
	switch (step)
	{
		case 0:
		{
			FakeClientCommand(FindHuman(), "drs off");
			SetupHumanFight(C_OFF);
		}
		case 1:
		{
			if (!ChatHas("switched off"))
			{
				RestoreHumanSettings();
				EndCase(false, "no confirmation for drs off");
				return;
			}
			HumanKilledByFake(C_OFF);
		}
		case 2:
		{
			bool shown = GetClientMenu(FindHuman()) == MenuSource_RawPanel || ChatHas("Attackers (Total dmg:");
			RestoreHumanSettings();
			if (shown)
				EndCase(false, "a report was shown while off");
			else
				EndCase(true, "no report while off");
		}
	}
}

void Case_RoundEndAlive(int step)
{
	switch (step)
	{
		case 0: SetupHumanFight(C_ROUND_END_ALIVE);
		case 1:
		{
			int h = FindHuman();
			int fake = GetClientOfUserId(g_uidAttacker);
			if (fake == 0)
			{
				EndCase(false, "fake client is gone");
				return;
			}
			SDKHooks_TakeDamage(fake, h, h, HIT_DAMAGE, DMG_BULLET);
			SDKHooks_TakeDamage(fake, h, h, HIT_DAMAGE, DMG_BULLET);
			SDKHooks_TakeDamage(fake, h, h, KILL_DAMAGE, DMG_BULLET);
			FireRoundEnd();
			Schedule(REPORT_WAIT, C_ROUND_END_ALIVE, 2);
		}
		case 2:
		{
			if (GetClientMenu(FindHuman()) != MenuSource_RawPanel)
				EndCase(false, "no report panel open for the alive player");
			else if (!ChatHas(AWARD_DAMAGE) || !ChatHas(AWARD_STAT ... ", 540 dmg in 3 hits"))
				EndCase(false, "no prefixed most-damage chat line for 540 dmg in 3 hits");
			else if (!ChatHas(AWARD_KILLS) || !ChatHas(AWARD_STAT ... ", 1 kill"))
				EndCase(false, "no prefixed most-kills chat line for 1 kill");
			else if (ChatHas("Total dmg:") || ChatHas(" dmg, "))
				EndCase(false, "report text in chat in popup mode");
			else
				EndCase(true, "report panel open, both award lines in chat, no report text in chat");
		}
	}
}

AdminId g_testAdmin = INVALID_ADMIN_ID;

void SetAdminOnly(bool on)
{
	FindConVar(ADMIN_ONLY_CVAR).BoolValue = on;
	FindConVar(ADMIN_FLAGS_CVAR).SetString(on ? TEST_ADMIN_FLAGS : "b");
}

void GrantTestAdmin(int client)
{
	g_testAdmin = CreateAdmin("dr_test");
	g_testAdmin.SetFlag(Admin_Custom1, true);
	SetUserAdmin(client, g_testAdmin, true);
}

void ResetAdminOnly()
{
	int h = FindHuman();
	if (h != 0 && g_testAdmin != INVALID_ADMIN_ID)
		SetUserAdmin(h, INVALID_ADMIN_ID, true);
	if (g_testAdmin != INVALID_ADMIN_ID)
		RemoveAdmin(g_testAdmin);
	g_testAdmin = INVALID_ADMIN_ID;
	SetAdminOnly(false);
	FindConVar(AWARDS_ADMIN_CVAR).BoolValue = false;
}

void Case_AdminOnly(int step)
{
	switch (step)
	{
		case 0:
		{
			if (GetUserAdmin(FindHuman()) != INVALID_ADMIN_ID)
			{
				SkipCase("the real client is an admin");
				return;
			}
			// The previous case leaves its 8 s round-end panel open.
			CancelClientMenu(FindHuman());
			SetAdminOnly(true);
			SetupHumanFight(C_ADMIN_ONLY);
		}
		case 1:
		{
			FakeClientCommand(FindHuman(), "drs status");
			HumanKilledByFake(C_ADMIN_ONLY);
		}
		case 2:
		{
			int h = FindHuman();
			if (g_menuBeforeKill)
			{
				EndCase(false, "a menu was already open before the kill");
				return;
			}
			if (GetClientMenu(h) == MenuSource_RawPanel || ChatHas("Attackers (Total dmg:"))
			{
				EndCase(false, "a non-admin got a report in admin-only mode");
				return;
			}
			if (!ChatHas("for admins only"))
			{
				EndCase(false, "no admins-only reply to drs status");
				return;
			}
			GrantTestAdmin(h);
			ResetCapture();
			FakeClientCommand(h, "drs status");
			Schedule(1.0, C_ADMIN_ONLY, 3);
		}
		case 3:
		{
			if (ChatHas("Damage report is switched on"))
				EndCase(true, "non-admin denied, admin with flag o gets drs status");
			else
				EndCase(false, "admin with flag o got no drs status reply");
		}
	}
}

void Case_AwardsAudience(int step)
{
	int h = FindHuman();
	switch (step)
	{
		case 0:
		{
			if (GetUserAdmin(h) != INVALID_ADMIN_ID)
			{
				SkipCase("the real client is an admin");
				return;
			}
			CancelClientMenu(h);
			SetAdminOnly(true);
			SetupHumanFight(C_AWARDS_AUDIENCE);
		}
		case 1:
		{
			int fake = GetClientOfUserId(g_uidAttacker);
			if (fake == 0)
			{
				EndCase(false, "fake client is gone");
				return;
			}
			SDKHooks_TakeDamage(fake, h, h, HIT_DAMAGE, DMG_BULLET);
			FireRoundEnd();
			Schedule(REPORT_WAIT, C_AWARDS_AUDIENCE, 2);
		}
		case 2:
		{
			if (GetClientMenu(h) == MenuSource_RawPanel)
			{
				EndCase(false, "a non-admin got the report panel in admin-only mode");
				return;
			}
			if (!ChatHas(AWARD_DAMAGE))
			{
				EndCase(false, "awards for all players: the non-admin got no most-damage line");
				return;
			}
			FindConVar(AWARDS_ADMIN_CVAR).BoolValue = true;
			ResetCapture();
			FireRoundEnd();
			Schedule(REPORT_WAIT, C_AWARDS_AUDIENCE, 3);
		}
		case 3:
		{
			if (ChatHas(">DMG<"))
			{
				EndCase(false, "awards for admins only: the non-admin got a most-damage line");
				return;
			}
			GrantTestAdmin(h);
			ResetCapture();
			FireRoundEnd();
			Schedule(REPORT_WAIT, C_AWARDS_AUDIENCE, 4);
		}
		case 4:
		{
			if (!ChatHas(AWARD_DAMAGE))
				EndCase(false, "awards for admins only: the admin got no most-damage line");
			else if (GetClientMenu(h) != MenuSource_RawPanel)
				EndCase(false, "the admin got no report panel");
			else
				EndCase(true, "non-admin: awards only when for all players; admin: awards and panel");
		}
	}
}

void Case_SettingsWrites(int step)
{
	int h = FindHuman();
	if (h == 0)
	{
		EndCase(false, "the real client left during the case");
		return;
	}
	switch (step)
	{
		// Let a save that an earlier case started finish first.
		case 0: Schedule(SAVE_WAIT, C_SETTINGS_WRITES, 1);
		case 1:
		{
			AppendSettingsSentinel();
			// Each reply is chat; the client drops a connection that gets too many in one frame.
			FakeClientCommand(h, "drs status");
			FakeClientCommand(h, "drs help");
			FakeClientCommand(h, "drs bogus");
			FakeClientCommand(h, "drs on");
			Schedule(0.5, C_SETTINGS_WRITES, 2);
		}
		case 2:
		{
			if (!SettingsHasSentinel())
			{
				EndCase(false, "drs commands that changed nothing rewrote the settings file");
				return;
			}
			for (int i = 0; i < COMMAND_SPAM; i++)
			{
				FakeClientCommand(h, "drs popup");
				FakeClientCommand(h, "drs chat");
			}
			Schedule(0.5, C_SETTINGS_WRITES, 3);
		}
		case 3:
		{
			if (!SettingsHasSentinel())
			{
				RestoreHumanSettings();
				EndCase(false, "a burst of drs changes rewrote the settings file at once");
				return;
			}
			Schedule(SAVE_WAIT, C_SETTINGS_WRITES, 4);
		}
		case 4:
		{
			int popChat;
			bool stored = ReadClientSetting(h, "PopChat", popChat);
			bool rewritten = !SettingsHasSentinel();
			RestoreHumanSettings();
			if (!rewritten)
				EndCase(false, "the changed setting was never written");
			else if (!stored || popChat != 0)
				EndCase(false, "the settings file has no PopChat 0 entry for the client");
			else
				Schedule(SAVE_WAIT, C_SETTINGS_WRITES, 5);
		}
		case 5:
		{
			int popChat;
			if (ReadClientSetting(h, "PopChat", popChat))
				EndCase(false, "the entry stayed in the file after the client went back to the defaults");
			else
				EndCase(true, "no write for unchanged settings; one later write for a burst; defaults remove the entry");
		}
	}
}

void Case_SettingsReload(int step)
{
	int h = FindHuman();
	if (h == 0)
	{
		EndCase(false, "the real client left during the case");
		return;
	}
	switch (step)
	{
		case 0:
		{
			FakeClientCommand(h, "drs chat");
			ServerCommand("sm plugins reload sm_damagereport");
			Schedule(RELOAD_WAIT, C_SETTINGS_RELOAD, 1);
		}
		case 1:
		{
			ResetCapture();
			FakeClientCommand(h, "drs status");
			Schedule(1.0, C_SETTINGS_RELOAD, 2);
		}
		case 2:
		{
			bool kept = ChatHas("is printed in chat");
			RestoreHumanSettings();
			if (kept)
				EndCase(true, "drs chat kept after the reload");
			else
				EndCase(false, "drs chat was lost by the reload");
		}
	}
}

void Case_NameSafe(int step)
{
	switch (step)
	{
		case 0:
		{
			int attacker = SpawnFake(FAKE_CONTROL_NAME, CS_TEAM_T);
			int victim = SpawnFake(FAKE_VICTIM, CS_TEAM_CT);
			if (attacker == 0 || victim == 0)
			{
				EndCase(false, "could not create fake clients");
				return;
			}
			g_uidAttacker = GetClientUserId(attacker);
			g_uidVictim = GetClientUserId(victim);
			Schedule(1.0, C_NAME_SAFE, 1);
		}
		case 1, 3:
		{
			int attacker = GetClientOfUserId(g_uidAttacker);
			int victim = GetClientOfUserId(g_uidVictim);
			if (attacker == 0 || victim == 0)
			{
				EndCase(false, "fake client is gone");
				return;
			}
			SDKHooks_TakeDamage(victim, attacker, attacker, HIT_DAMAGE, DMG_BULLET);
			FireRoundEnd();
			Schedule(1.0, C_NAME_SAFE, step + 1);
		}
		case 2:
		{
			if (!ChatHas(AWARD_DAMAGE ... FAKE_CONTROL_SHOWN ... AWARD_STAT))
			{
				EndCase(false, "the award line does not show " ... FAKE_CONTROL_SHOWN ... " without its control byte");
				return;
			}
			KickClient(GetClientOfUserId(g_uidAttacker), "damage report test cleanup");
			int attacker = SpawnFake(FAKE_UTF8_NAME, CS_TEAM_T);
			if (attacker == 0)
			{
				EndCase(false, "could not create the UTF-8 fake");
				return;
			}
			g_uidAttacker = GetClientUserId(attacker);
			FireNamedEvent("round_start");
			ResetCapture();
			Schedule(1.0, C_NAME_SAFE, 3);
		}
		case 4:
		{
			if (ChatHas(AWARD_DAMAGE ... FAKE_UTF8_SHOWN ... AWARD_STAT))
				EndCase(true, "control byte removed; long UTF-8 name cut before a whole character");
			else
				EndCase(false, "the award line does not show " ... FAKE_UTF8_SHOWN);
		}
	}
}

bool g_mapChangePending;

void Case_NotInGame(int step)
{
	switch (step)
	{
		case 0:
		{
			// During a map change every client is connected but not in game until it has loaded the map.
			CleanupFakes();
			g_mapChangePending = true;
			char map[PLATFORM_MAX_PATH];
			GetCurrentMap(map, sizeof(map));
			ServerCommand("changelevel %s", map);
		}
		case 1:
		{
			// The client reconnects some time after the new map starts.
			static int polls;
			int loading = FindLoadingHuman();
			if (loading == 0)
			{
				if (FindHuman() == 0 && ++polls < LOADING_POLLS)
				{
					Schedule(0.1, C_NOT_IN_GAME, 1);
					return;
				}
				polls = 0;
				EndCase(false, "no client was seen while it was still loading the map");
				return;
			}
			polls = 0;
			FakeClientCommand(loading, "dr");
			FakeClientCommand(loading, "dr help");
			FakeClientCommand(loading, "drs status");
			Schedule(1.0, C_NOT_IN_GAME, 2);
		}
		case 2: EndCase(true, "dr, dr help and drs status from a loading client raised no error");
	}
}

public void OnConfigsExecuted()
{
	if (!g_mapChangePending)
		return;
	g_mapChangePending = false;
	g_interfered = false; // the map change fires its own round_start
	RunStep(C_NOT_IN_GAME, 1);
}

int FindLoadingHuman()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientConnected(i) && !IsClientInGame(i) && !IsFakeClient(i))
			return i;
	return 0;
}

void SettingsPath(char[] path, int maxlen)
{
	BuildPath(Path_SM, path, maxlen, SETTINGS_FILE);
}

// A comment line the plugin drops whenever it rewrites the file.
void AppendSettingsSentinel()
{
	char path[PLATFORM_MAX_PATH];
	SettingsPath(path, sizeof(path));
	File f = OpenFile(path, "ab");
	if (f == null)
	{
		LogToFileEx(g_logPath, "[INFO]   cannot append to %s", path);
		return;
	}
	f.WriteString("\n" ... SETTINGS_SENTINEL ... "\n", false);
	delete f;
}

bool SettingsHasSentinel()
{
	char path[PLATFORM_MAX_PATH], line[512];
	SettingsPath(path, sizeof(path));
	File f = OpenFile(path, "rb");
	if (f == null)
		return false;
	bool found = false;
	while (!found && f.ReadLine(line, sizeof(line)))
		found = StrContains(line, SETTINGS_SENTINEL) != -1;
	delete f;
	return found;
}

bool ReadClientSetting(int client, const char[] key, int &value)
{
	char path[PLATFORM_MAX_PATH], steamId[32];
	SettingsPath(path, sizeof(path));
	GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);
	KeyValues kv = new KeyValues("DamageReportSetting");
	bool found = kv.ImportFromFile(path) && kv.JumpToKey(steamId);
	if (found)
		value = kv.GetNum(key, -1);
	delete kv;
	return found;
}

//===== Case helpers =====

// Step 0 of a real-client case: the human on T, one fake attacker on CT; then step 1.
void SetupHumanFight(int c)
{
	int h = FindHuman();
	ChangeClientTeam(h, CS_TEAM_T);
	CS_RespawnPlayer(h);
	int fake = SpawnFake(FAKE_ATTACKER, CS_TEAM_CT);
	if (fake == 0)
	{
		EndCase(false, "could not create the fake attacker");
		return;
	}
	g_uidAttacker = GetClientUserId(fake);
	// Spawning sends the human a short "DR Fix" panel; let it expire before the case's report.
	Schedule(2.0, c, 1);
}

// Two hits then a kill on the human; then step 2 once the report had time to show.
void HumanKilledByFake(int c)
{
	int h = FindHuman();
	int fake = GetClientOfUserId(g_uidAttacker);
	if (fake == 0 || !IsPlayerAlive(h))
	{
		EndCase(false, "fake gone or human not alive before the kill");
		return;
	}
	g_menuBeforeKill = GetClientMenu(h) != MenuSource_None;
	SDKHooks_TakeDamage(h, fake, fake, HIT_DAMAGE, DMG_BULLET);
	SDKHooks_TakeDamage(h, fake, fake, HIT_DAMAGE, DMG_BULLET);
	SDKHooks_TakeDamage(h, fake, fake, KILL_DAMAGE, DMG_BULLET);
	Schedule(REPORT_WAIT, c, 2);
}

// SourceMod sends panels with hooks blocked, so a plugin cannot read their text; it can see that one is open.
bool CheckPanelAfterDeath(char[] why, int maxlen)
{
	int h = FindHuman();
	if (IsPlayerAlive(h))
		strcopy(why, maxlen, "the human did not die");
	else if (g_menuBeforeKill)
		strcopy(why, maxlen, "a menu was already open before the kill");
	else if (GetClientMenu(h) != MenuSource_RawPanel)
		strcopy(why, maxlen, "no panel open after death");
	else
		return true;
	return false;
}

// Back to the defaults (on, popup, long), which also removes the client's entry from the settings file.
void RestoreHumanSettings()
{
	int h = FindHuman();
	if (h == 0)
		return;
	FakeClientCommand(h, "drs on");
	FakeClientCommand(h, "drs popup");
	FakeClientCommand(h, "drs long");
}

bool SpawnFakes()
{
	int attacker = SpawnFake(FAKE_ATTACKER, CS_TEAM_T);
	int victim = SpawnFake(FAKE_VICTIM, CS_TEAM_CT);
	if (attacker == 0 || victim == 0)
		return false;
	g_uidAttacker = GetClientUserId(attacker);
	g_uidVictim = GetClientUserId(victim);
	return true;
}

int SpawnFake(const char[] name, int team)
{
	int c = CreateFakeClient(name);
	if (c <= 0)
		return 0;
	ChangeClientTeam(c, team);
	CS_RespawnPlayer(c);
	return c;
}

void CleanupFakes()
{
	int uids[2];
	uids[0] = g_uidAttacker;
	uids[1] = g_uidVictim;
	for (int i = 0; i < sizeof(uids); i++)
	{
		int c = GetClientOfUserId(uids[i]);
		if (c > 0 && IsClientConnected(c) && IsFakeClient(c))
			KickClient(c, "damage report test cleanup");
	}
	g_uidAttacker = 0;
	g_uidVictim = 0;
	int h = FindHuman();
	if (h != 0 && GetClientTeam(h) != CS_TEAM_SPECTATOR)
		ChangeClientTeam(h, CS_TEAM_SPECTATOR);
}

int FindHuman()
{
	for (int i = 1; i <= MaxClients; i++)
		if (IsClientInGame(i) && !IsFakeClient(i) && !IsClientSourceTV(i))
			return i;
	return 0;
}

void FireRoundEnd()
{
	Event ev = CreateEvent("round_end");
	if (ev == null)
		return;
	ev.SetInt("winner", CS_TEAM_CT);
	ev.SetInt("reason", 7); // CT win; 16 (game commencing) is ignored by the plugin
	ev.SetString("message", "#CTs_Win");
	g_selfFire = true;
	ev.Fire();
	g_selfFire = false;
}

void FireNamedEvent(const char[] name)
{
	Event ev = CreateEvent(name);
	if (ev == null)
		return;
	g_selfFire = true;
	ev.Fire();
	g_selfFire = false;
}

int ErrorLogSize()
{
	char date[16], path[PLATFORM_MAX_PATH];
	FormatTime(date, sizeof(date), "%Y%m%d");
	BuildPath(Path_SM, path, sizeof(path), "logs/errors_%s.log", date);
	return FileExists(path) ? FileSize(path) : 0;
}

// Sets a game cvar for the run and returns its old value (-1 if the cvar does not exist).
int SwapCvarInt(const char[] name, int value)
{
	ConVar cv = FindConVar(name);
	if (cv == null)
		return -1;
	int old = cv.IntValue;
	cv.IntValue = value;
	return old;
}

void RestoreCvars()
{
	if (g_origIgnoreWin != -1)
		SwapCvarInt("mp_ignore_round_win_conditions", g_origIgnoreWin);
	if (g_origAutokick != -1)
		SwapCvarInt("mp_autokick", g_origAutokick);
	g_origIgnoreWin = -1;
	g_origAutokick = -1;
}
