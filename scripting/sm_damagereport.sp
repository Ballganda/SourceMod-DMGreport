#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

// Definitions
#define MAXHITGROUPS 7
#define NROFOPTIONS 3
#define MAX_FILE_LEN 80

#define DrON  1
#define DrOFF 0
#define DrPop 1
#define DrChat 0
#define DrLong 1
#define DrShort 0

#define propOnOff 0
#define propPopChat 1
#define propShortLong 2

#define PLUGIN_VERSION "2.0.0-b1"

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

int g_maxClients;

char g_HitboxName[MAXHITGROUPS + 1][20];

// Variable for Temp fix
int g_MenuCleared[MAXPLAYERS + 1];


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_lateLoaded = late;
    return APLRes_Success;
}

// Hook events on plugin start
public void OnPluginStart(){
  g_maxClients = MaxClients;

  g_versionConVar = CreateConVar("sm_damagereport_version", PLUGIN_VERSION, "Damage report version", FCVAR_PLUGIN | FCVAR_SPONLY | FCVAR_REPLICATED | FCVAR_NOTIFY);
  
  SetConVarString(g_versionConVar, PLUGIN_VERSION);
  
  HookEvent("player_death", Event_PlayerDeath);
  HookEvent("player_hurt", Event_PlayerHurt);
  HookEvent("player_spawn", Event_PlayerSpawn);
  HookEvent("round_end", Event_RoundEnd);
  HookEvent("round_start", EventRoundStart);

  HookEvent("player_disconnect", Event_PlayerDisconnect);
  HookEvent("player_connect", Event_PlayerConnect);

  RegConsoleCmd("damage_report", Command_DamageReport);
  RegConsoleCmd("dr", Command_DamageReport);
  RegConsoleCmd("last_damage_report", Command_LastDamageReport);
  RegConsoleCmd("ldr", Command_LastDamageReport);
  RegConsoleCmd("dmg", Command_LastDamageReport);
  

  KVSettings = CreateKeyValues("DamageReportSetting");
  BuildPath(Path_SM, g_filenameSettings, sizeof(g_filenameSettings), "data/damagereportsetting.txt");
  if (!FileToKeyValues(KVSettings, g_filenameSettings))
  {
    KeyValuesToFile(KVSettings, g_filenameSettings);
  }       

  if (g_lateLoaded)
  {
      // Plugin was not loaded at beginning of round
      // Find settings for all players already connected
      for (int i = 1; i <= g_maxClients; i++)
      {
          if (IsClientInGame(i) && !IsFakeClient(i))
          {
              FindSettingsForClient(i);
          }
      }
  }
    
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
        PrintToChat(client, "\x04No history to display");
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

    // If too few or too many arguments
    if (args != 1)
    {
        PrintToChat(client, "\x04Usage: /damage_report help");
        return Plugin_Handled;
    }

    char option[20];
    GetCmdArg(1, option, sizeof(option));

    if (StrEqual(option, "on", false))
    {
        g_PlayerDROption[client][propOnOff] = DrON;
        PrintToChat(client, "\x04Damage report switched on");
    }
    else if (StrEqual(option, "off", false))
    {
        g_PlayerDROption[client][propOnOff] = DrOFF;
        PrintToChat(client, "\x04Damage report switched off");
    }
    else if (StrEqual(option, "popup", false))
    {
        g_PlayerDROption[client][propPopChat] = DrPop;
        PrintToChat(client, "\x04Damage report printed in popup menu");
    }
    else if (StrEqual(option, "chat", false))
    {
        g_PlayerDROption[client][propPopChat] = DrChat;
        PrintToChat(client, "\x04Damage report printed in chat");
    }
    else if (StrEqual(option, "short", false))
    {
        g_PlayerDROption[client][propShortLong] = DrShort;
        PrintToChat(client, "\x04Hitbox data will not be shown");
    }
    else if (StrEqual(option, "long", false))
    {
        g_PlayerDROption[client][propShortLong] = DrLong;
        PrintToChat(client, "\x04Hitbox data will be shown");
    }
    else if (StrEqual(option, "status", false))
    {
        if (g_PlayerDROption[client][propOnOff] == DrON)
        {
            PrintToChat(client, "\x04Damage report is switched on");

            if (g_PlayerDROption[client][propPopChat] == DrPop)
                PrintToChat(client, "\x04Damage report is printed in popup menu");
            else
                PrintToChat(client, "\x04Damage report is printed in chat");

            if (g_PlayerDROption[client][propShortLong] == DrShort)
                PrintToChat(client, "\x04Hitbox data is not shown");
            else
                PrintToChat(client, "\x04Hitbox data is shown");
        }
        else
        {
            PrintToChat(client, "\x04Damage report is switched off");
        }
    }
    else
    {
        PrintToChat(client, "\x04/damage_report on (Turn it on)");
        PrintToChat(client, "\x04/damage_report off (Turn it off)");
        PrintToChat(client, "\x04/damage_report popup (Popup menu)");
        PrintToChat(client, "\x04/damage_report chat (Chat output)");
        PrintToChat(client, "\x04/damage_report short (Hide hitbox info)");
        PrintToChat(client, "\x04/damage_report long (Show hitbox info)");
        PrintToChat(client, "\x04/damage_report status (Show current settings)");
        PrintToChat(client, "\x04/last_damage_report or /ldr (Show last report)");
    }

    StoreSettingsForClient(client);
    return Plugin_Handled;
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

    g_KilledPlayer[attacker][victim] = 1;

    if (g_PlayerDROption[victim][propOnOff] == DrON
        && !IsFakeClient(victim)
        && IsClientInGame(victim))
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
                damageDone, xkilled, g_PlayerName[i],
                g_DamageDone[in_victim][i],
                g_HitsDone[in_victim][i],
                killed
            );

            Format(
                damageDoneLong, sizeof(damageDoneLong),
                "%s%s%s [%d dmg, %d hits]%s\n",
                damageDoneLong, xkilled, g_PlayerName[i],
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
    for (int i = 1; i <= g_maxClients; i++)
    {
        if (g_DamageTaken[in_victim][i] > 0)
        {
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
                damageTaken, xkiller, g_PlayerName[i],
                g_DamageTaken[in_victim][i],
                g_HitsTaken[in_victim][i],
                killer
            );

            Format(
                damageTakenLong, sizeof(damageTakenLong),
                "%s%s%s [%d dmg, %d hits]%s\n",
                damageTakenLong, xkiller, g_PlayerName[i],
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
            PrintToChat(
                in_victim,
                "\x04\n--Victims (Total dmg:%d)--\n",
                totalDmgDone
            );
            PrintToChat(in_victim, "\x04%s", damageDoneLong);
        }

        if (damageTakenLong[0] != '\0')
        {
            PrintToChat(
                in_victim,
                "\x04--Attackers (Total dmg:%d)--\n",
                totalDmgTaken
            );
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
        return Plugin_Stop;
    }

    if (GetClientMenu(p_victim) != MenuSource_None)
    {
        return Plugin_Continue;
    }

    Panel damageReportPanel = new Panel();

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
    damageReportPanel.DrawText("Type \"/damage_report help\" in chat for settings");

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


// Temp Fix
public void Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    g_MenuCleared[client] = 0;

    g_HistDamageDone[client][0] = '\0';
    g_HistDamageDoneLong[client][0] = '\0';
    g_HistTotalDamageDone[client] = 0;

    g_HistDamageTaken[client][0] = '\0';
    g_HistDamageTakenLong[client][0] = '\0';
    g_HistTotalDamageTaken[client] = 0;
}


public void Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    g_MenuCleared[client] = 0;

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
        g_PlayerDROption[client][propShortLong] = KvGetNum(KVSettings, "ShortLong", g_defaultPropChatPop);
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
                && IsPlayerAlive(i))
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
        PrintToChatAll(
            "\x04%s inflicted most damage, %d dmg in %d hits!",
            g_PlayerName[mostDamagePlayer],
            mostDamage,
            mostHits
        );
    }

    if (mostKills > 0)
    {
        PrintToChatAll(
            "\x04Most kills:%s with %d kills",
            g_PlayerName[mostKillsPlayer],
            mostKills
        );
    }
}


public void clearAllDamageData()
{
    // Clear all logged damage
    for (int i = 1; i <= g_maxClients; i++)
    {
        for (int j = 1; j <= g_maxClients; j++)
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
