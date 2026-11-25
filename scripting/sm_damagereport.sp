/**
	Damage report
	Copyright (C) [30+]Gemeni (2007), BallGanda (2.0.0 and later)

	This program is free software: you can redistribute it and/or modify it under the terms of the
	GNU General Public License as published by the Free Software Foundation, version 3.

	This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without
	even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
	General Public License for more details.

	You should have received a copy of the GNU General Public License along with this program.
	If not, see <https://www.gnu.org/licenses/>.
*/
#include <sourcemod>
#include <sdktools>
#include <instance_config> // settings file in this server's own SourceMod folder (not the shared game cfg folder)

#pragma semicolon 1
#pragma newdecls required

// Definitions
#define MAXHITGROUPS 7
#define NROFOPTIONS 3
#define MAX_FILE_LEN 80
#define DR_NAME_MAX_TOTAL   21
#define DR_NAME_TRUNCATE_AT 18
#define DR_PREFIX_MAX       32
#define DR_TITLE_MAX        64
#define DR_MENU_RETRY_MAX 8  // 8 * 1s = 8s max wait
#define DR_CHAT_MAX 256

// CS:S chat color codes; \x07 takes a 6-digit hex color
#define DR_COLOR_PREFIX "\x04"
#define DR_COLOR_TEXT   "\x01"
#define DR_HEX_COLOR_LEN 7

enum AwardPart
{
    Award_Prefix,
    Award_Label,
    Award_Name,
    Award_Stat,
    AWARD_PARTS
}

#define DrON  1
#define DrOFF 0
#define DrPop 1
#define DrChat 0
#define DrLong 1
#define DrShort 0

#define propOnOff 0
#define propPopChat 1
#define propShortLong 2

#define PLUGIN_VERSION "2.1.0"

public Plugin myinfo =
{
    name = "Damage report",
    author = "[30+]Gemeni",
    description = "Reports who damaged you and who you damaged",
    version = PLUGIN_VERSION,
    url = "http://30plus.ownit.se/"
};

// Global variables
int g_DamageDone[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitsDone[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitboxDone[MAXPLAYERS + 1][MAXPLAYERS + 1][MAXHITGROUPS + 1];

int g_DamageTaken[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitsTaken[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitboxTaken[MAXPLAYERS + 1][MAXPLAYERS + 1][MAXHITGROUPS + 1];

char g_PlayerName[MAXPLAYERS + 1][32];

int g_KilledPlayer[MAXPLAYERS + 1][MAXPLAYERS + 1];

int g_PlayerDROption[MAXPLAYERS + 1][NROFOPTIONS];
char g_filenameSettings[MAX_FILE_LEN];
Handle KVSettings = INVALID_HANDLE;

int g_defaultPropOnOff = DrON;
int g_defaultPropChatPop = DrPop;
int g_defaultPropShortLong = DrLong;

bool g_lateLoaded;

// History stats
char g_HistDamageDone[MAXPLAYERS + 1][512];
char g_HistDamageDoneLong[MAXPLAYERS + 1][512];
int  g_HistTotalDamageDone[MAXPLAYERS + 1];
char g_HistDamageTaken[MAXPLAYERS + 1][512];
char g_HistDamageTakenLong[MAXPLAYERS + 1][512];
int  g_HistTotalDamageTaken[MAXPLAYERS + 1];

ConVar g_versionConVar;
ConVar g_cvPrefix;
char g_Prefix[DR_PREFIX_MAX];
ConVar g_cvAdminOnly;
ConVar g_cvAdminFlags;
ConVar g_cvAwardsAdminOnly;
ConVar g_cvPanelTitle;
ConVar g_cvAwardsPrefix;
ConVar g_cvAwardColor[AWARD_PARTS];
char g_AwardColorDefault[AWARD_PARTS][DR_HEX_COLOR_LEN] = { "40FF40", "FF4040", "99CCFF", "FFD700" };

int g_maxClients;

char g_HitboxName[MAXHITGROUPS + 1][20];

// Variable for Temp fix
int g_MenuCleared[MAXPLAYERS + 1];

int g_MenuRetryCount[MAXPLAYERS + 1];
bool g_ReportPending[MAXPLAYERS + 1];


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_lateLoaded = late;
    return APLRes_Success;
}

public void OnPrefixChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    strcopy(g_Prefix, sizeof(g_Prefix), newValue);
}

public void OnConfigsExecuted()
{
    InstCfg_Apply();
}

bool HasReportAccess(int client)
{
    return !g_cvAdminOnly.BoolValue || HasAdminFlags(client);
}

bool HasAwardAccess(int client)
{
    return !g_cvAwardsAdminOnly.BoolValue || HasAdminFlags(client);
}

bool HasAdminFlags(int client)
{
    char flags[32];
    g_cvAdminFlags.GetString(flags, sizeof(flags));
    return CheckCommandAccess(client, "sm_damagereport_access", ReadFlagString(flags), true);
}

void PrintPrefixed(int client, const char[] format, any ...)
{
    char text[DR_CHAT_MAX];
    VFormat(text, sizeof(text), format, 3);
    PrintToChat(client, DR_COLOR_PREFIX ... "%s " ... DR_COLOR_TEXT ... "%s", g_Prefix, text);
}

bool IsHexColor(const char[] value)
{
    if (strlen(value) != DR_HEX_COLOR_LEN - 1)
    {
        return false;
    }

    for (int i = 0; i < DR_HEX_COLOR_LEN - 1; i++)
    {
        int c = CharToLower(value[i]);
        if (!IsCharNumeric(c) && (c < 'a' || c > 'f'))
        {
            return false;
        }
    }
    return true;
}

public void OnAwardColorChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (IsHexColor(newValue))
    {
        return;
    }

    for (int part = 0; part < view_as<int>(AWARD_PARTS); part++)
    {
        if (convar == g_cvAwardColor[part])
        {
            char name[64];
            convar.GetName(name, sizeof(name));
            LogError("%s \"%s\" is not a 6-digit hex color such as FFD700; using %s", name, newValue, g_AwardColorDefault[part]);
            convar.SetString(g_AwardColorDefault[part]);
        }
    }
}

void GetAwardColor(AwardPart part, char[] out, int outSize)
{
    char hex[DR_HEX_COLOR_LEN];
    g_cvAwardColor[part].GetString(hex, sizeof(hex));
    Format(out, outSize, "\x07%s", hex);
}

// Example: theREG...>DMG<: Alpha, 158 dmg in 3 hits
void PrintAwardToAll(const char[] label, const char[] playerName, const char[] format, any ...)
{
    char stat[DR_CHAT_MAX];
    VFormat(stat, sizeof(stat), format, 4);

    char awardsPrefix[DR_PREFIX_MAX];
    g_cvAwardsPrefix.GetString(awardsPrefix, sizeof(awardsPrefix));

    char color[AWARD_PARTS][DR_HEX_COLOR_LEN + 1];
    for (int part = 0; part < view_as<int>(AWARD_PARTS); part++)
    {
        GetAwardColor(view_as<AwardPart>(part), color[part], sizeof(color[]));
    }

    for (int i = 1; i <= g_maxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && HasAwardAccess(i))
        {
            PrintToChat(i, "%s%s%s>%s<: %s%s%s%s",
                color[Award_Prefix], awardsPrefix,
                color[Award_Label], label,
                color[Award_Name], playerName,
                color[Award_Stat], stat);
        }
    }
}

// Hook events on plugin start
public void OnPluginStart(){
  g_maxClients = MaxClients;

  g_versionConVar = CreateConVar("sm_damagereport_version", PLUGIN_VERSION, "Damage report version", FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
  
  SetConVarString(g_versionConVar, PLUGIN_VERSION);

  g_cvPrefix = CreateConVar("sm_damagereport_prefix", "[theREG...]", "Text shown before damage report chat messages");
  g_cvPrefix.GetString(g_Prefix, sizeof(g_Prefix));
  g_cvPrefix.AddChangeHook(OnPrefixChanged);

  g_cvAdminOnly = CreateConVar("sm_damagereport_access_admin_only", "0", "Only admins with sm_damagereport_access_admin_flags get reports and commands <1|0>", _, true, 0.0, true, 1.0);
  g_cvAdminFlags = CreateConVar("sm_damagereport_access_admin_flags", "b", "Admin flags that give access when an admin_only cvar is 1, for example b or z");
  g_cvAwardsAdminOnly = CreateConVar("sm_damagereport_awards_admin_only", "0", "Only admins with sm_damagereport_access_admin_flags see the most damage and most kills lines <1|0>", _, true, 0.0, true, 1.0);
  g_cvAwardsPrefix = CreateConVar("sm_damagereport_awards_prefix", "theREG...", "Text shown before the most damage and most kills lines");
  g_cvAwardColor[Award_Prefix] = CreateConVar("sm_damagereport_awards_color_prefix", g_AwardColorDefault[Award_Prefix], "Hex color (RRGGBB) of the award prefix, for example theREG...");
  g_cvAwardColor[Award_Label] = CreateConVar("sm_damagereport_awards_color_label", g_AwardColorDefault[Award_Label], "Hex color (RRGGBB) of the award label, >DMG<: and >KILLS<:");
  g_cvAwardColor[Award_Name] = CreateConVar("sm_damagereport_awards_color_name", g_AwardColorDefault[Award_Name], "Hex color (RRGGBB) of the player name in the award lines");
  g_cvAwardColor[Award_Stat] = CreateConVar("sm_damagereport_awards_color_stat", g_AwardColorDefault[Award_Stat], "Hex color (RRGGBB) of the numbers in the award lines");
  g_cvPanelTitle = CreateConVar("sm_damagereport_panel_title", "theREG...DMGreport:", "Title line of the report panel");

  // configs/sm_damagereport.cfg (named after the plugin file); the version cvar stays out of it
  InstCfg_Add(g_cvPrefix);
  InstCfg_Add(g_cvAdminOnly);
  InstCfg_Add(g_cvAdminFlags);
  InstCfg_Add(g_cvAwardsAdminOnly);
  InstCfg_Add(g_cvAwardsPrefix);
  for (int part = 0; part < view_as<int>(AWARD_PARTS); part++)
  {
    g_cvAwardColor[part].AddChangeHook(OnAwardColorChanged);
    InstCfg_Add(g_cvAwardColor[part]);
  }
  InstCfg_Add(g_cvPanelTitle);
  InstCfg_Ensure();

  HookEvent("player_death", Event_PlayerDeath);
  HookEvent("player_hurt", Event_PlayerHurt);
  HookEvent("player_spawn", Event_PlayerSpawn);
  HookEvent("round_end", Event_RoundEnd);
  HookEvent("round_start", EventRoundStart);

  HookEvent("player_disconnect", Event_PlayerDisconnect);

  RegConsoleCmd("damage_report", Command_DamageReport);
  RegConsoleCmd("drs", Command_DamageReport);
  RegConsoleCmd("last_damage_report", Command_LastDamageReport);
  RegConsoleCmd("ldr", Command_LastDamageReport);
  RegConsoleCmd("dmg", Command_LastDamageReport);
  RegConsoleCmd("dr", Command_LastDamageReport);
  

  KVSettings = CreateKeyValues("DamageReportSetting");
  BuildPath(Path_SM, g_filenameSettings, sizeof(g_filenameSettings), "configs/damagereportusersettings.cfg");
  if (!FileToKeyValues(KVSettings, g_filenameSettings))
  {
    // Carry over settings saved at the old location
    char oldFilename[MAX_FILE_LEN];
    BuildPath(Path_SM, oldFilename, sizeof(oldFilename), "data/damagereportsetting.txt");
    FileToKeyValues(KVSettings, oldFilename);
    KeyValuesToFile(KVSettings, g_filenameSettings);
  }       

  if (g_lateLoaded)
  {
      // Plugin was not loaded at beginning of round
      // Find settings and names for all players already connected; names are otherwise stored at spawn
      for (int i = 1; i <= g_maxClients; i++)
      {
          if (!IsClientInGame(i))
          {
              continue;
          }

          GetClientName(i, g_PlayerName[i], sizeof(g_PlayerName[]));

          if (!IsFakeClient(i))
          {
              FindSettingsForClient(i);
          }
      }
  }
    
    strcopy(g_PlayerName[0], sizeof(g_PlayerName[]), "WORLD");

    strcopy(g_HitboxName[0], sizeof(g_HitboxName[]), "Body");
    strcopy(g_HitboxName[1], sizeof(g_HitboxName[]), "Head");
    strcopy(g_HitboxName[2], sizeof(g_HitboxName[]), "Chest");
    strcopy(g_HitboxName[3], sizeof(g_HitboxName[]), "Stomach");
    strcopy(g_HitboxName[4], sizeof(g_HitboxName[]), "L-Arm");
    strcopy(g_HitboxName[5], sizeof(g_HitboxName[]), "R-Arm");
    strcopy(g_HitboxName[6], sizeof(g_HitboxName[]), "L-Leg");
    strcopy(g_HitboxName[7], sizeof(g_HitboxName[]), "R-Leg");
}

public Action Command_LastDamageReport(int client, int args)
{
    // Dont do anything if command comes from server
    if (client == 0)
    {
        return Plugin_Handled;
    }

    if (!HasReportAccess(client))
    {
        PrintPrefixed(client, "Damage report is for admins only");
        return Plugin_Handled;
    }

    char option[20];
    GetCmdArg(1, option, sizeof(option));
    if (StrEqual(option, "help", false))
    {
        PrintHelp(client);
        return Plugin_Handled;
    }

    if ((g_HistDamageDone[client][0] != '\0') || (g_HistDamageTaken[client][0] != '\0'))
    {
        DisplayDamageReport(
            client,
            g_HistDamageDone[client],
            g_HistDamageDoneLong[client],
            g_HistDamageTaken[client],
            g_HistDamageTakenLong[client],
            g_HistTotalDamageDone[client],
            g_HistTotalDamageTaken[client]
        );
    }
    else
    {
        PrintPrefixed(client, "No history to display");
    }

    return Plugin_Handled;
}

public Action Command_DamageReport(int client, int args)
{
    // Dont do anything if command comes from server
    if (client == 0)
    {
        return Plugin_Handled;
    }

    if (!HasReportAccess(client))
    {
        PrintPrefixed(client, "Damage report is for admins only");
        return Plugin_Handled;
    }

    // If too few or too many arguments
    if (args != 1)
    {
        PrintPrefixed(client, "Usage: /dr help");
        return Plugin_Handled;
    }

    char option[20];
    GetCmdArg(1, option, sizeof(option));

    if (StrEqual(option, "on", false))
    {
        g_PlayerDROption[client][propOnOff] = DrON;
        PrintPrefixed(client, "Damage report switched on");
    }
    else if (StrEqual(option, "off", false))
    {
        g_PlayerDROption[client][propOnOff] = DrOFF;
        PrintPrefixed(client, "Damage report switched off");
    }
    else if (StrEqual(option, "popup", false))
    {
        g_PlayerDROption[client][propPopChat] = DrPop;
        PrintPrefixed(client, "Damage report printed in popup menu");
    }
    else if (StrEqual(option, "chat", false))
    {
        g_PlayerDROption[client][propPopChat] = DrChat;
        PrintPrefixed(client, "Damage report printed in chat");
    }
    else if (StrEqual(option, "short", false))
    {
        g_PlayerDROption[client][propShortLong] = DrShort;
        PrintPrefixed(client, "Hitbox data will not be shown");
    }
    else if (StrEqual(option, "long", false))
    {
        g_PlayerDROption[client][propShortLong] = DrLong;
        PrintPrefixed(client, "Hitbox data will be shown");
    }
    else if (StrEqual(option, "status", false))
    {
        if (g_PlayerDROption[client][propOnOff] == DrON)
        {
            PrintPrefixed(client, "Damage report is switched on");

            if (g_PlayerDROption[client][propPopChat] == DrPop)
                PrintPrefixed(client, "Damage report is printed in popup menu");
            else
                PrintPrefixed(client, "Damage report is printed in chat");

            if (g_PlayerDROption[client][propShortLong] == DrShort)
                PrintPrefixed(client, "Hitbox data is not shown");
            else
                PrintPrefixed(client, "Hitbox data is shown");
        }
        else
        {
            PrintPrefixed(client, "Damage report is switched off");
        }
    }
    else
    {
        PrintHelp(client);
    }

    StoreSettingsForClient(client);
    return Plugin_Handled;
}

void PrintHelp(int client)
{
    PrintPrefixed(client, "/dr (Show your last report)");
    PrintPrefixed(client, "/dr help (This list)");
    PrintPrefixed(client, "/drs on, /drs off (Turn your report on or off)");
    PrintPrefixed(client, "/drs popup, /drs chat (Show it in a panel or in chat)");
    PrintPrefixed(client, "/drs long, /drs short (Show or hide hitbox info)");
    PrintPrefixed(client, "/drs status (Show your settings)");
}



// Save all settings on map end
public void OnMapEnd()
{
    // Save user settings to a file
    KvRewind(KVSettings);
    KeyValuesToFile(KVSettings, g_filenameSettings);

    clearAllDamageData();
}


public void OnMapStart()
{
    g_maxClients = MaxClients;

    // Temp fix for clearing menus on start
    for (int i = 1; i <= g_maxClients; i++)
    {
        g_MenuCleared[i] = 0;
    }
}
 

// Initializations to be done at the beginning of the round
public void EventRoundStart(Event event, const char[] name, bool dontBroadcast)
{
    clearAllDamageData();
}

// In this event we store how much damage attacker did to victim in one array
// and how much damage victim took from attacker in another array
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    int healthDmg = event.GetInt("dmg_health");
    int hitgroup  = event.GetInt("hitgroup");

    if (healthDmg <= 0)
    {
        return;
    }

    int victim_id   = event.GetInt("userid");
    int attacker_id = event.GetInt("attacker");

    int victim   = GetClientOfUserId(victim_id);
    int attacker = GetClientOfUserId(attacker_id);

    // --- SAFETY GUARDS (no semantic change) ---

    // Victim must always be a valid client
    if (victim <= 0 || victim > g_maxClients)
    {
        return;
    }

    // Allow attacker == 0 (world damage), but clamp invalid values
    if (attacker < 0 || attacker > g_maxClients)
    {
        attacker = 0;
    }

    // Clamp hitgroup to valid range
    if (hitgroup < 0 || hitgroup > MAXHITGROUPS)
    {
        hitgroup = 0;
    }

    // --- ORIGINAL LOGIC (unchanged) ---

    // Damage done by attacker (including world = 0)
    g_DamageDone[attacker][victim] += healthDmg;
    g_HitsDone[attacker][victim]++;
    g_HitboxDone[attacker][victim][hitgroup]++;

    // Damage taken by victim
    g_DamageTaken[victim][attacker] += healthDmg;
    g_HitsTaken[victim][attacker]++;
    g_HitboxTaken[victim][attacker][hitgroup]++;
}




// Upon player dead, check who is the victim and attacker and
// Call up on the BuildDamageString function
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim_id   = event.GetInt("userid");
    int attacker_id = event.GetInt("attacker");

    int victim   = GetClientOfUserId(victim_id);
    int attacker = GetClientOfUserId(attacker_id);

    if (victim <= 0 || victim > g_maxClients)
    {
        return;
    }

    if (attacker >= 0 && attacker <= g_maxClients)
    {
        g_KilledPlayer[attacker][victim] = 1;
    }

    if (g_PlayerDROption[victim][propOnOff] == DrON
        && IsClientInGame(victim)
        && !IsFakeClient(victim)
        && HasReportAccess(victim))
    {
        BuildDamageString(victim, attacker);
    }
}


// Local Function where we loop through all attackers and victims for a client.
// if any damage is taken or done a timer is called that will display a Panel with the info.
public void BuildDamageString(int in_victim, int in_attacker)
{
    char damageReport[512];
    char damageReportLong[600];
    char damageDone[512];
    char damageTaken[512];
    char damageDoneLong[512];
    char damageTakenLong[512];
    char killer[10];
    char xkiller[10];
    char killed[10];
    char xkilled[10];

    int totalDmgTaken = 0;
    int totalDmgDone  = 0;

    damageReport[0]     = '\0';
    damageReportLong[0] = '\0';
    damageDone[0]       = '\0';
    damageTaken[0]      = '\0';
    damageDoneLong[0]   = '\0';
    damageTakenLong[0]  = '\0';

    // Loop through all damage where you inflicted damage
    for (int i = 1; i <= g_maxClients; i++)
    {
        if (g_DamageDone[in_victim][i] > 0)
        {
            char displayName[DR_NAME_MAX_TOTAL + 1];
            FormatPlayerName(displayName, sizeof(displayName), g_PlayerName[i]);

            if (g_KilledPlayer[in_victim][i] == 1)
            {
                strcopy(killed, sizeof(killed), " (Killed)");
                strcopy(xkilled, sizeof(xkilled), "X ");
            }
            else
            {
                killed[0]  = '\0';
                strcopy(xkilled, sizeof(xkilled), "--");
            }

            Format(
                damageDone, sizeof(damageDone),
                "%s%s%s [%d dmg, %d hits]%s\n",
                damageDone, xkilled, displayName,
                g_DamageDone[in_victim][i],
                g_HitsDone[in_victim][i],
                killed
            );

            Format(
                damageDoneLong, sizeof(damageDoneLong),
                "%s%s%s [%d dmg, %d hits]%s\n",
                damageDoneLong, xkilled, displayName,
                g_DamageDone[in_victim][i],
                g_HitsDone[in_victim][i],
                killed
            );

            Format(damageDoneLong, sizeof(damageDoneLong), "%s  ", damageDoneLong);

            totalDmgDone += g_DamageDone[in_victim][i];

            for (int j = 0; j <= MAXHITGROUPS; j++)
            {
                if (g_HitboxDone[in_victim][i][j] > 0)
                {
                    Format(
                        damageDoneLong, sizeof(damageDoneLong),
                        "%s%s:%d ",
                        damageDoneLong, g_HitboxName[j],
                        g_HitboxDone[in_victim][i][j]
                    );
                }
            }

            Format(damageDoneLong, sizeof(damageDoneLong), "%s\n", damageDoneLong);
        }
    }

    if (strcmp(damageDone, "", false) != 0)
    {
        Format(damageReport, sizeof(damageReport), "%s\n%s", "Damage done:", damageDone);
        Format(damageReportLong, sizeof(damageReportLong), "%s\n%s", "Damage done:", damageDoneLong);
    }

    // Loop through all damage where you took damage
    for (int i = 0; i <= g_maxClients; i++)
    {
        if (g_DamageTaken[in_victim][i] > 0)
        {
            char displayName[DR_NAME_MAX_TOTAL + 1];
            FormatPlayerName(displayName, sizeof(displayName), g_PlayerName[i]);

            if (i == in_attacker)
            {
                strcopy(killer, sizeof(killer), " (Killer)");
                strcopy(xkiller, sizeof(xkiller), "X ");
            }
            else
            {
                killer[0] = '\0';
                strcopy(xkiller, sizeof(xkiller), "--");
            }

            Format(
                damageTaken, sizeof(damageTaken),
                "%s%s%s [%d dmg, %d hits]%s\n",
                damageTaken, xkiller, displayName,
                g_DamageTaken[in_victim][i],
                g_HitsTaken[in_victim][i],
                killer
            );

            Format(
                damageTakenLong, sizeof(damageTakenLong),
                "%s%s%s [%d dmg, %d hits]%s\n",
                damageTakenLong, xkiller, displayName,
                g_DamageTaken[in_victim][i],
                g_HitsTaken[in_victim][i],
                killer
            );

            Format(damageTakenLong, sizeof(damageTakenLong), "%s  ", damageTakenLong);

            totalDmgTaken += g_DamageTaken[in_victim][i];

            for (int j = 0; j <= MAXHITGROUPS; j++)
            {
                if (g_HitboxTaken[in_victim][i][j] > 0)
                {
                    Format(
                        damageTakenLong, sizeof(damageTakenLong),
                        "%s%s:%d ",
                        damageTakenLong, g_HitboxName[j],
                        g_HitboxTaken[in_victim][i][j]
                    );
                }
            }

            Format(damageTakenLong, sizeof(damageTakenLong), "%s\n", damageTakenLong);
        }
    }

    if (strcmp(damageTaken, "", false) != 0)
    {
        Format(damageReport, sizeof(damageReport), "%s%s\n%s", damageReport, "Damage taken:", damageTaken);
        Format(damageReportLong, sizeof(damageReportLong), "%s%s\n%s", damageReportLong, "Damage taken:", damageTakenLong);
    }

    if (strcmp(damageReport, "", false) != 0)
    {
        strcopy(g_HistDamageDone[in_victim], sizeof(g_HistDamageDone[]), damageDone);
        strcopy(g_HistDamageDoneLong[in_victim], sizeof(g_HistDamageDoneLong[]), damageDoneLong);
        g_HistTotalDamageDone[in_victim] = totalDmgDone;

        strcopy(g_HistDamageTaken[in_victim], sizeof(g_HistDamageTaken[]), damageTaken);
        strcopy(g_HistDamageTakenLong[in_victim], sizeof(g_HistDamageTakenLong[]), damageTakenLong);
        g_HistTotalDamageTaken[in_victim] = totalDmgTaken;

        DisplayDamageReport(
            in_victim,
            damageDone,
            damageDoneLong,
            damageTaken,
            damageTakenLong,
            totalDmgDone,
            totalDmgTaken
        );
    }
}


public void DisplayDamageReport(
    int in_victim,
    const char[] damageDone,
    const char[] damageDoneLong,
    const char[] damageTaken,
    const char[] damageTakenLong,
    int totalDmgDone,
    int totalDmgTaken
)
{
    if (g_PlayerDROption[in_victim][propPopChat] == DrPop)
    {
        if (g_ReportPending[in_victim])
        {
            return;
        }

        g_ReportPending[in_victim]  = true;
        g_MenuRetryCount[in_victim] = 0;

        // Display damage report to the dead victim
        DataPack pack = new DataPack();

        CreateDataTimer(
            1.0,
            DisplayDamageReportMenu,
            pack,
            TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE
        );

        pack.WriteCell(in_victim);

        if ((strlen(damageTakenLong) + strlen(damageDoneLong) < 512 - 30)
            && (g_PlayerDROption[in_victim][propShortLong] == DrLong))
        {
            pack.WriteString(damageDoneLong);
            pack.WriteString(damageTakenLong);
            pack.WriteCell(totalDmgDone);
            pack.WriteCell(totalDmgTaken);
        }
        else
        {
            pack.WriteString(damageDone);
            pack.WriteString(damageTaken);
            pack.WriteCell(totalDmgDone);
            pack.WriteCell(totalDmgTaken);
        }
    }
    else
    {
        if (damageDoneLong[0] != '\0')
        {
            PrintPrefixed(in_victim, "--Victims (Total dmg:%d)--", totalDmgDone);
            PrintToChat(in_victim, "\x04%s", damageDoneLong);
        }

        if (damageTakenLong[0] != '\0')
        {
            PrintPrefixed(in_victim, "--Attackers (Total dmg:%d)--", totalDmgTaken);
            PrintToChat(in_victim, "\x04%s", damageTakenLong);
        }
    }
}


// This is called by the timer.
// It checks if a menu/panel already is displayed ... if so
// let the timer try again after the delay, hoping the menu is closed
public Action DisplayDamageReportMenu(Handle timer, DataPack pack)
{
    char p_damageDone[512];
    char p_damageTaken[512];
    char victimItem[100];
    char attackerItem[100];

    pack.Reset();
    int p_victim        = pack.ReadCell();
    pack.ReadString(p_damageDone, sizeof(p_damageDone));
    pack.ReadString(p_damageTaken, sizeof(p_damageTaken));
    int p_totalDmgDone  = pack.ReadCell();
    int p_totalDmgTaken = pack.ReadCell();

    if (!IsClientInGame(p_victim))
    {
        g_ReportPending[p_victim] = false;
        return Plugin_Stop;
    }

    if (GetClientMenu(p_victim) != MenuSource_None)
    {
        if (++g_MenuRetryCount[p_victim] >= DR_MENU_RETRY_MAX)
        {
            g_ReportPending[p_victim] = false;
            return Plugin_Stop;
        }

        return Plugin_Continue;
    }

    g_ReportPending[p_victim]  = false;
    g_MenuRetryCount[p_victim] = 0;

    Panel damageReportPanel = new Panel();

    char title[DR_TITLE_MAX];
    g_cvPanelTitle.GetString(title, sizeof(title));
    damageReportPanel.SetTitle(title);

    if (p_damageDone[0] != '\0')
    {
        Format(victimItem, sizeof(victimItem), "Victims (Total dmg:%d)", p_totalDmgDone);
        damageReportPanel.DrawItem(victimItem);
        damageReportPanel.DrawText(p_damageDone);
    }

    if (p_damageTaken[0] != '\0')
    {
        Format(attackerItem, sizeof(attackerItem), "Attackers (Total dmg:%d)", p_totalDmgTaken);
        damageReportPanel.DrawItem(attackerItem);
        damageReportPanel.DrawText(p_damageTaken);
    }

    damageReportPanel.DrawItem("Exit");
    damageReportPanel.DrawText("Type \"/dr help\" in chat for commands");

    damageReportPanel.Send(p_victim, Handler_MyPanel, 8);
    delete damageReportPanel;

    return Plugin_Stop;
}



// Display time timer will close my panel ... no need to handle anything
// Panel is automatically closed when its time expires
public int Handler_MyPanel(Menu menu, MenuAction action, int param1, int param2)
{
    return 0;
}



// Store the name of the player at time of spawn. If player disconnects before
// round end, the name can still be displayed in the damage reports.
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    if (client <= 0 || client > g_maxClients)
    {
        return;
    }

    // Temp fix menu
    if (g_MenuCleared[client] == 0)
    {
        Panel tempPanel = new Panel();
        tempPanel.DrawText("DR Fix");
        tempPanel.Send(client, Handler_MyPanel, 1);
        g_MenuCleared[client] = 1;
        delete tempPanel;
    }

    // Store player name in case they disconnect before round end
    char clientName[32];
    GetClientName(client, clientName, sizeof(clientName));
    strcopy(g_PlayerName[client], sizeof(g_PlayerName[]), clientName);
}


public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    ResetClientHistory(client);
}


public void OnClientConnected(int client)
{
    ResetClientHistory(client);
}


void ResetClientHistory(int client)
{
    if (client <= 0 || client > g_maxClients)
    {
        return;
    }

    g_MenuCleared[client]   = 0;
    g_MenuRetryCount[client] = 0;
    g_ReportPending[client]  = false;

    g_HistDamageDone[client][0]     = '\0';
    g_HistDamageDoneLong[client][0] = '\0';
    g_HistTotalDamageDone[client]   = 0;

    g_HistDamageTaken[client][0]     = '\0';
    g_HistDamageTakenLong[client][0] = '\0';
    g_HistTotalDamageTaken[client]   = 0;
}


public void OnClientPostAdminCheck(int client)
{
    FindSettingsForClient(client);
}


public void FindSettingsForClient(int client)
{
    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);

    KvRewind(KVSettings);
    if (KvJumpToKey(KVSettings, steamId))
    {
        g_PlayerDROption[client][propOnOff]     = KvGetNum(KVSettings, "OnOff", g_defaultPropOnOff);
        g_PlayerDROption[client][propPopChat]   = KvGetNum(KVSettings, "PopChat", g_defaultPropChatPop);
        g_PlayerDROption[client][propShortLong] = KvGetNum(KVSettings, "ShortLong", g_defaultPropShortLong);
    }
    else
    {
        g_PlayerDROption[client][propOnOff]     = g_defaultPropOnOff;
        g_PlayerDROption[client][propPopChat]   = g_defaultPropChatPop;
        g_PlayerDROption[client][propShortLong] = g_defaultPropShortLong;
    }

    KvRewind(KVSettings);
}


public void StoreSettingsForClient(int client)
{
    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId), true);

    if (StrContains(steamId, "steam", false) != -1)
    {
        KvRewind(KVSettings);

        if (g_PlayerDROption[client][propOnOff] == g_defaultPropOnOff
            && g_PlayerDROption[client][propPopChat] == g_defaultPropChatPop
            && g_PlayerDROption[client][propShortLong] == g_defaultPropShortLong)
        {
            if (KvJumpToKey(KVSettings, steamId))
            {
                KvDeleteThis(KVSettings);
            }
        }
        else
        {
            KvJumpToKey(KVSettings, steamId, true);
            KvSetNum(KVSettings, "OnOff", g_PlayerDROption[client][propOnOff]);
            KvSetNum(KVSettings, "PopChat", g_PlayerDROption[client][propPopChat]);
            KvSetNum(KVSettings, "ShortLong", g_PlayerDROption[client][propShortLong]);
        }

        KvRewind(KVSettings);
        KeyValuesToFile(KVSettings, g_filenameSettings);
    }
}


// Check if there are any living players. If so, trigger a timer for them so they will see their damage report
// Calculate who did max damage and display it as a hint.
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Make sure that we have a normal round end
    // reason 16 is game commencing
    int reason = event.GetInt("reason");
    if (reason == 16)
    {
        return;
    }

    int damage = 0;
    int hits = 0;
    int mostDamage = 0;
    int mostDamagePlayer = 0;
    int mostHits = 0;
    int kills = 0;
    int mostKills = 0;
    int mostKillsPlayer = 0;

    // Display damage report to living players
    // -1 in the damage string will make sure no one will be shown as the (Killer)
    for (int i = 1; i <= g_maxClients; i++)
    {
        if (IsClientInGame(i))
        {
            if (g_PlayerDROption[i][propOnOff] == DrON
                && IsClientConnected(i)
                && !IsFakeClient(i)
                && IsPlayerAlive(i)
                && HasReportAccess(i))
            {
                BuildDamageString(i, -1);
            }
        }
    }

    // Finding out who did the most damage
    for (int i = 1; i <= g_maxClients; i++)
    {
        damage = 0;
        hits = 0;

        for (int j = 1; j <= g_maxClients; j++)
        {
            damage += g_DamageDone[i][j];
            hits   += g_HitsDone[i][j];
        }

        if (damage > mostDamage)
        {
            mostDamage = damage;
            mostDamagePlayer = i;
            mostHits = hits;
        }
    }

    // Finding out who had the most kills
    mostKills = 0;
    for (int i = 1; i <= g_maxClients; i++)
    {
        kills = 0;

        for (int j = 1; j <= g_maxClients; j++)
        {
            kills += g_KilledPlayer[i][j];
        }

        if (kills > mostKills)
        {
            mostKills = kills;
            mostKillsPlayer = i;
        }
    }

    // Display to all players who did the most damage this round
    if (mostDamage > 0)
    {
        char damageName[DR_NAME_MAX_TOTAL + 1];
        FormatPlayerName(damageName, sizeof(damageName), g_PlayerName[mostDamagePlayer]);

        PrintAwardToAll(
            "DMG",
            damageName,
            ", %d dmg in %d %s",
            mostDamage,
            mostHits,
            mostHits == 1 ? "hit" : "hits"
        );
    }

    if (mostKills > 0)
    {
        char killsName[DR_NAME_MAX_TOTAL + 1];
        FormatPlayerName(killsName, sizeof(killsName), g_PlayerName[mostKillsPlayer]);

        PrintAwardToAll(
            "KILLS",
            killsName,
            ", %d %s",
            mostKills,
            mostKills == 1 ? "kill" : "kills"
        );
    }
}


void FormatPlayerName(char[] out, int outSize, const char[] name)
{
    if (strlen(name) <= DR_NAME_MAX_TOTAL)
    {
        strcopy(out, outSize, name);
        return;
    }

    strcopy(out, outSize, name);
    out[DR_NAME_TRUNCATE_AT] = '\0';
    StrCat(out, outSize, "...");
}


public void clearAllDamageData()
{
    // Clear all logged damage
    for (int i = 0; i <= g_maxClients; i++)
    {
        for (int j = 0; j <= g_maxClients; j++)
        {
            g_DamageDone[i][j]   = 0;
            g_DamageTaken[i][j]  = 0;
            g_HitsDone[i][j]     = 0;
            g_HitsTaken[i][j]    = 0;
            g_KilledPlayer[i][j] = 0;

            for (int k = 0; k <= MAXHITGROUPS; k++)
            {
                g_HitboxDone[i][j][k]  = 0;
                g_HitboxTaken[i][j][k] = 0;
            }
        }
    }
}
