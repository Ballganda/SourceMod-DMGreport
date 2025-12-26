#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

// Definitions
#define PLUGIN_VERSION "2.0.1-b3"

#define MAXHITGROUPS 7 // 0 to 7 -> 8 total
#define NROFOPTIONS 3
#define MAX_FILE_LEN PLATFORM_MAX_PATH
#define DR_NAME_MAX_TOTAL    16
#define DR_NAME_TRUNCATE_AT  13
#define DR_MENU_RETRY_MAX 16  // 16 * 0.5s = 8s max wait

#define DrON  1
#define DrOFF 0
#define DrPop 1
#define DrChat 0
#define DrLong 1
#define DrShort 0

#define propOnOff 0
#define propPopChat 1
#define propShortLong 2

public Plugin myinfo =
{
    name = "Damage report",
    author = "[30+]Gemeni, Ballganda",
    description = "Reports who damaged you and who you damaged",
    version = PLUGIN_VERSION,
    url = "https://github.com/Ballganda/SourceMod-DamageReport/releases"
};

// --- Damage tracking ---
int g_DamageDone[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_DamageTaken[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitsDone[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitsTaken[MAXPLAYERS + 1][MAXPLAYERS + 1];
int g_HitboxDone[MAXPLAYERS + 1][MAXPLAYERS + 1][MAXHITGROUPS + 1];
int g_HitboxTaken[MAXPLAYERS + 1][MAXPLAYERS + 1][MAXHITGROUPS + 1];
int g_KilledPlayer[MAXPLAYERS + 1][MAXPLAYERS + 1];

// --- Player options ---
int g_PlayerDROption[MAXPLAYERS + 1][NROFOPTIONS];
int g_defaultPropOnOff = DrON;
int g_defaultPropChatPop = DrPop;
int g_defaultPropShortLong = DrLong;

// --- Player identity ---
char g_PlayerName[MAXPLAYERS + 1][MAX_NAME_LENGTH];
char g_HitboxName[MAXHITGROUPS + 1][20];

// --- History ---
char g_HistDamageDone[MAXPLAYERS + 1][512];
char g_HistDamageDoneLong[MAXPLAYERS + 1][512];
char g_HistDamageTaken[MAXPLAYERS + 1][512];
char g_HistDamageTakenLong[MAXPLAYERS + 1][512];
int  g_HistTotalDamageDone[MAXPLAYERS + 1];
int  g_HistTotalDamageTaken[MAXPLAYERS + 1];

// --- Runtime / state ---
int g_maxClients;
bool g_lateLoaded;
int g_MenuRetryCount[MAXPLAYERS + 1];
bool g_ReportPending[MAXPLAYERS + 1];

// --- Persistence ---
char g_filenameSettings[MAX_FILE_LEN];
KeyValues KVSettings = null;

// --- Versioning ---
ConVar g_versionConVar;


public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    g_lateLoaded = late;
    return APLRes_Success;
}


public void OnPluginStart()
{
    g_maxClients = MaxClients;

    g_versionConVar = CreateConVar(
        "sm_damagereport_version",
        PLUGIN_VERSION,
        "Damage report version",
        FCVAR_PLUGIN | FCVAR_REPLICATED | FCVAR_NOTIFY
    );

    SetConVarString(g_versionConVar, PLUGIN_VERSION);

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
        KeyValuesToFile(KVSettings, g_filenameSettings);
    }

    if (g_lateLoaded)
    {
        for (int i = 1; i <= g_maxClients; i++)
        {
            if (IsClientInGame(i) && !IsFakeClient(i))
            {
                FindSettingsForClient(i);
            }
        }
    }

    //set WORLD label  (index 0)
    strcopy(g_PlayerName[0], sizeof(g_PlayerName[]), "WORLD");

    //   Hitbox names
    strcopy(g_HitboxName[0], sizeof(g_HitboxName[]), "B"); //Body
    strcopy(g_HitboxName[1], sizeof(g_HitboxName[]), "H"); //Head
    strcopy(g_HitboxName[2], sizeof(g_HitboxName[]), "C"); //Chest
    strcopy(g_HitboxName[3], sizeof(g_HitboxName[]), "S"); //Stomach
    strcopy(g_HitboxName[4], sizeof(g_HitboxName[]), "LA"); //Left-Arm
    strcopy(g_HitboxName[5], sizeof(g_HitboxName[]), "RA"); //Right-Arm
    strcopy(g_HitboxName[6], sizeof(g_HitboxName[]), "LL"); //Left-Leg
    strcopy(g_HitboxName[7], sizeof(g_HitboxName[]), "RL"); //Right-Leg
}


public Action Command_LastDamageReport(int client, int args)
{
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
        PrintToChat(client, "\x04[theREG...DMGreport] No history to display");
    }

    return Plugin_Handled;
}


public Action Command_DamageReport(int client, int args)
{
    if (client == 0)
    {
        return Plugin_Handled;
    }


    // If too few or too many arguments
    if (args != 1)
    {
        PrintDamageReportUsage(client);
        return Plugin_Handled;
    }

    char option[20];
    GetCmdArg(1, option, sizeof(option));

    if (StrEqual(option, "on", false))
    {
        g_PlayerDROption[client][propOnOff] = DrON;
        PrintToChat(client, "\x04[theREG...DMGreport] switched on");
    }
    else if (StrEqual(option, "off", false))
    {
        g_PlayerDROption[client][propOnOff] = DrOFF;
        PrintToChat(client, "\x04[theREG...DMGreport] switched off");
    }
    else if (StrEqual(option, "popup", false))
    {
        g_PlayerDROption[client][propPopChat] = DrPop;
        PrintToChat(client, "\x04[theREG...DMGreport] printed in popup menu");
    }
    else if (StrEqual(option, "chat", false))
    {
        g_PlayerDROption[client][propPopChat] = DrChat;
        PrintToChat(client, "\x04[theREG...DMGreport] printed in chat");
    }
    else if (StrEqual(option, "short", false))
    {
        g_PlayerDROption[client][propShortLong] = DrShort;
        PrintToChat(client, "\x04[theREG...DMGreport] Hitbox data will not be shown");
    }
    else if (StrEqual(option, "long", false))
    {
        g_PlayerDROption[client][propShortLong] = DrLong;
        PrintToChat(client, "\x04[theREG...DMGreport] Hitbox data will be shown");
    }
    else if (StrEqual(option, "status", false))
    {
        if (g_PlayerDROption[client][propOnOff] == DrON)
        {
            PrintToChat(client, "\x04[theREG...DMGreport] switched on");

            if (g_PlayerDROption[client][propPopChat] == DrPop)
                PrintToChat(client, "\x04[theREG...DMGreport] printed in popup menu");
            else
                PrintToChat(client, "\x04[theREG...DMGreport] printed in chat");

            if (g_PlayerDROption[client][propShortLong] == DrShort)
                PrintToChat(client, "\x04[theREG...DMGreport] Hitbox data is not shown");
            else
                PrintToChat(client, "\x04[theREG...DMGreport] Hitbox data is shown");
        }
        else
        {
            PrintToChat(client, "\x04[theREG...DMGreport] switched off");
        }
    }
    else
    {
    PrintDamageReportUsage(client);
    }
    
    StoreSettingsForClient(client);
    return Plugin_Handled;
}

void PrintDamageReportUsage(int client)
{
    PrintToChat(client, "\x04[theREG...DMGreport] /drs on (Turn it on)");
    PrintToChat(client, "\x04[theREG...DMGreport] /drs off (Turn it off)");
    PrintToChat(client, "\x04[theREG...DMGreport] /drs popup (Popup menu)");
    PrintToChat(client, "\x04[theREG...DMGreport] /drs chat (Chat output)");
    PrintToChat(client, "\x04[theREG...DMGreport] /drs short (Hide hitbox info)");
    PrintToChat(client, "\x04[theREG...DMGreport] /drs long (Show hitbox info)");
    PrintToChat(client, "\x04[theREG...DMGreport] /drs status (Show current settings)");
    PrintToChat(client, "\x04[theREG...DMGreport] /dr or /ldr or /dmg (Show last report)");
}


public void OnMapStart()
{
    g_maxClients = MaxClients;
    strcopy(g_PlayerName[0], sizeof(g_PlayerName[]), "WORLD");
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

    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

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
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    if (victim <= 0 || victim > g_maxClients)
        return;

    /* Only real players count as killers */
    if (attacker >= 0 && attacker <= g_maxClients)
    {
        g_KilledPlayer[attacker][victim] = 1;
    }

    if (g_PlayerDROption[victim][propOnOff] == DrON
        && !IsFakeClient(victim)
        && IsClientInGame(victim))
    {
        BuildDamageString(victim, attacker);
    }
}


// Local Function where we loop through all attackers and victims for a client.
// if any damage is taken or done a timer is called that will display a Menu with the info.
public void BuildDamageString(int in_victim, int in_attacker)
{
    char damageDone[512];
    char damageDoneLong[512];
    char damageTaken[512];
    char damageTakenLong[512];

    int totalDmgDone  = 0;
    int totalDmgTaken = 0;

    damageDone[0]       = '\0';
    damageDoneLong[0]   = '\0';
    damageTaken[0]      = '\0';
    damageTakenLong[0]  = '\0';

    BuildDamageDoneStrings(in_victim, damageDone, sizeof(damageDone), damageDoneLong, sizeof(damageDoneLong), totalDmgDone);

    BuildDamageTakenStrings(in_victim, in_attacker, damageTaken, sizeof(damageTaken), damageTakenLong, sizeof(damageTakenLong), totalDmgTaken);

    if (damageDone[0] == '\0' && damageTaken[0] == '\0')
        return;

    strcopy(g_HistDamageDone[in_victim], sizeof(g_HistDamageDone[]), damageDone);
    strcopy(g_HistDamageDoneLong[in_victim], sizeof(g_HistDamageDoneLong[]), damageDoneLong);
    g_HistTotalDamageDone[in_victim] = totalDmgDone;

    strcopy(g_HistDamageTaken[in_victim], sizeof(g_HistDamageTaken[]), damageTaken);
    strcopy(g_HistDamageTakenLong[in_victim], sizeof(g_HistDamageTakenLong[]), damageTakenLong);
    g_HistTotalDamageTaken[in_victim] = totalDmgTaken;

    DisplayDamageReport(in_victim, damageDone, damageDoneLong, damageTaken, damageTakenLong, totalDmgDone, totalDmgTaken);
}


void AppendHitboxInfo(char[] buffer, int bufferSize, int victim, int other, bool damageDone)
{
    for (int j = 0; j <= MAXHITGROUPS; j++)
    {
        int hits = damageDone ? g_HitboxDone[victim][other][j] : g_HitboxTaken[victim][other][j];

        char cell[16];

        if (hits > 0)
        {
            // Real hitbox data
            Format(cell, sizeof(cell), "%s:%d", g_HitboxName[j], hits);
        }
        else
        {
            // Placeholder, width depends on label length
            int width = strlen(g_HitboxName[j]) + 2; // "X:NN"
            for (int k = 0; k < width; k++)
                cell[k] = '-';
            cell[width] = '\0';
        }

        Format(buffer, bufferSize, "%s %s", buffer, cell);
    }
}


void BuildDamageDoneStrings(int victim, char[] shortBuf, int shortSize, char[] longBuf, int longSize, int &totalDamage)
{
    char prefix[4];

    for (int i = 1; i <= g_maxClients; i++)
    {
        if (g_DamageDone[victim][i] <= 0)
            continue;

        if (g_KilledPlayer[victim][i] == 1)
        {
            strcopy(prefix, sizeof(prefix), "|K|");
        }
        else
        {
            strcopy(prefix, sizeof(prefix), "[-]");
        }

        char displayName[DR_NAME_MAX_TOTAL + 1];
        FormatPlayerName(displayName, sizeof(displayName), g_PlayerName[i]);

        Format(shortBuf, shortSize, "%s%s%s|%3ddmg %2dhts\n", shortBuf, prefix, displayName, g_DamageDone[victim][i], g_HitsDone[victim][i]);
        Format(longBuf, longSize, "%s%s%s|%3ddmg %2dhts", longBuf, prefix, displayName, g_DamageDone[victim][i], g_HitsDone[victim][i]);

        totalDamage += g_DamageDone[victim][i];
        
        /* Inline hitboxes */
        AppendHitboxInfo(longBuf, longSize, victim, i, true);

        Format(longBuf, longSize, "%s\n", longBuf);
    }
}


void BuildDamageTakenStrings(int victim, int attacker, char[] shortBuf, int shortSize, char[] longBuf, int longSize, int &totalDamage)
{
    char prefix[4];

    /* NOTE: start at 0 to include WORLD */
    for (int i = 0; i <= g_maxClients; i++)
    {
        if (g_DamageTaken[victim][i] <= 0)
            continue;

        /* Killer marker (including WORLD) */
        if (i == attacker)
        {
            strcopy(prefix, sizeof(prefix), "|K|");
        }
        else
        {
            strcopy(prefix, sizeof(prefix), "[-]");
        }

        char displayName[DR_NAME_MAX_TOTAL + 1];
        FormatPlayerName(displayName, sizeof(displayName), g_PlayerName[i]);

        Format(shortBuf, shortSize, "%s%s%s|%3ddmg %2dht\n", shortBuf, prefix, displayName, g_DamageTaken[victim][i], g_HitsTaken[victim][i]);
        Format(longBuf, longSize, "%s%s%s|%3ddmg %2dht", longBuf, prefix, displayName, g_DamageTaken[victim][i], g_HitsTaken[victim][i]);

        totalDamage += g_DamageTaken[victim][i];

        AppendHitboxInfo(longBuf, longSize, victim, i, false);

        Format(longBuf, longSize, "%s\n", longBuf);
    }
}


public void DisplayDamageReport(int in_victim, const char[] damageDone, const char[] damageDoneLong, const char[] damageTaken, const char[] damageTakenLong, int totalDmgDone, int totalDmgTaken)
{
    if (in_victim <= 0 || in_victim > g_maxClients || !IsClientInGame(in_victim))
    {
        return;
    }

    // Snapshot options
    int popMode  = g_PlayerDROption[in_victim][propPopChat];
    int longMode = g_PlayerDROption[in_victim][propShortLong];

    if (popMode == DrPop)
    {
        if (g_ReportPending[in_victim])
        {
            return;
        }

        g_ReportPending[in_victim] = true;
        g_MenuRetryCount[in_victim] = 0;

        DataPack pack = new DataPack();

        CreateDataTimer(0.5, DisplayDamageReportMenu, pack, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);

        /*
            DataPack layout (MUST stay in sync with reader):
            [cell]   victim
            [string] damageDone
            [string] damageTaken
            [cell]   totalDmgDone
            [cell]   totalDmgTaken
        */
        pack.WriteCell(in_victim);

        bool useLong = (longMode == DrLong) && (strlen(damageDoneLong) + strlen(damageTakenLong) < 480);

        if (useLong)
        {
            pack.WriteString(damageDoneLong);
            pack.WriteString(damageTakenLong);
        }
        else
        {
            pack.WriteString(damageDone);
            pack.WriteString(damageTaken);
        }
        pack.WriteCell(totalDmgDone);
        pack.WriteCell(totalDmgTaken);
    }
    else
    {
        // --- CHAT OUTPUT PATH (RESPECT SHORT/LONG) ---
        char outDone[512];
        char outTaken[512];

        if (longMode == DrLong)
        {
            strcopy(outDone, sizeof(outDone), damageDoneLong);
            strcopy(outTaken, sizeof(outTaken), damageTakenLong);
        }
        else
        {
            strcopy(outDone, sizeof(outDone), damageDone);
            strcopy(outTaken, sizeof(outTaken), damageTaken);
        }

        if (outDone[0] != '\0')
        {
            PrintToChat(in_victim, "\x04\n++++Victims:Total %ddmg++++\n", totalDmgDone);
            PrintToChat(in_victim, "\x04%s", outDone);
        }

        if (outTaken[0] != '\0')
        {
            PrintToChat(in_victim, "\x04----Attackers:Total %ddmg----\n", totalDmgTaken);
            PrintToChat(in_victim, "\x04%s", outTaken);
        }
    }
}



public Action DisplayDamageReportMenu(Handle timer, DataPack pack)
{
    if (pack == null)
        return Plugin_Stop;

    char damageDone[512];
    char damageTaken[512];

    pack.Reset();

    int victim = pack.ReadCell();
    if (victim <= 0 || victim > g_maxClients || !IsClientInGame(victim))
    {
        if (victim > 0 && victim <= g_maxClients) g_ReportPending[victim] = false;
        return Plugin_Stop;
    }

    if (GetClientMenu(victim) != MenuSource_None)
    {
        if (++g_MenuRetryCount[victim] >= DR_MENU_RETRY_MAX)
        {
            g_ReportPending[victim] = false;
            return Plugin_Stop;
        }
        return Plugin_Continue;
    }
        

    pack.ReadString(damageDone, sizeof(damageDone));
    pack.ReadString(damageTaken, sizeof(damageTaken));

    int totalDmgDone  = pack.ReadCell();
    int totalDmgTaken = pack.ReadCell();

    Menu menu = new Menu(MenuHandler_DamageReport);
    menu.SetTitle("theREG...DMGreport:");

    if (damageDone[0] != '\0')
    {
        char header[64];
        Format(header, sizeof(header), "+++VICTIMS:TOTAL %ddmg", totalDmgDone);
        menu.AddItem("hdrVictims", header);

        char lines[100][256];
        int count = ExplodeString(damageDone, "\n", lines, sizeof(lines), sizeof(lines[]));
        bool highlight = true;
        for (int idx = 0; idx < count; idx++)
        {
            lines[idx][sizeof(lines[]) - 1] = '\0';
            if (lines[idx][0] == '\0')
                continue;

            highlight = !highlight;

            if (highlight)
                menu.AddItem("row", lines[idx], ITEMDRAW_DEFAULT);
            else
                menu.AddItem("", lines[idx], ITEMDRAW_DISABLED);

            if (menu.ItemCount >= 100)
                break;
        }
    }

    // Separator between sections in menu
    menu.AddItem("", "====================================", ITEMDRAW_DISABLED);

    if (damageTaken[0] != '\0')
    {
        char header[64];
        Format(header, sizeof(header), "---ATTACKERS:TOTAL %ddmg***", totalDmgTaken);
        menu.AddItem("hdrAttackers", header);

        char lines[100][256];
        int count = ExplodeString(damageTaken, "\n", lines, sizeof(lines), sizeof(lines[]));
        bool highlight = true;
        for (int idx = 0; idx < count; idx++)
        {
            lines[idx][sizeof(lines[]) - 1] = '\0';
            if (lines[idx][0] == '\0')
                continue;

            highlight = !highlight;

            if (highlight)
                menu.AddItem("row", lines[idx], ITEMDRAW_DEFAULT);
            else
                menu.AddItem("", lines[idx], ITEMDRAW_DISABLED);

            if (menu.ItemCount >= 100)
                break;
        }
    }

    menu.ExitButton = true;

    //Final “never steal” check (race hardening) 
    if (GetClientMenu(victim) != MenuSource_None)
    {
        if (++g_MenuRetryCount[victim] >= DR_MENU_RETRY_MAX)
        {
        g_ReportPending[victim] = false;
        delete menu;
        return Plugin_Stop;
        }
        delete menu;
        return Plugin_Continue;
    }

/* Success path */
g_MenuRetryCount[victim] = 0;
g_ReportPending[victim] = false;
menu.Display(victim, 12);
    return Plugin_Stop;
}


public int MenuHandler_DamageReport(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}


// Store the name of the player at time of spawn. If player disconnects before
// round end, the name can still be displayed in the damage reports.
public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);

    // Guard invalid client
    if (client <= 0 || client > g_maxClients)
    {
        return;
    }

    // Store player name in case they disconnect before round end
    char clientName[32];
    GetClientName(client, clientName, sizeof(clientName));
    strcopy(g_PlayerName[client], sizeof(g_PlayerName[]), clientName);
}


// Reset per-client history on disconnect
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
    if (client <= 0 || client > g_maxClients) return;

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

    if (steamId[0] == '\0')
        return;

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


// Check if there are any living players. If so, trigger a timer for them so they will see their damage report
// Calculate who did max damage and display it as a hint.
public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    // Ignore game-commencing round end
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

    // Show damage report to living players
    // attacker = -1 => no killer attribution
    for (int i = 1; i <= g_maxClients; i++)
    {
        if (IsClientConnected(i)
            && IsClientInGame(i)
            && !IsFakeClient(i)
            && IsPlayerAlive(i)
            && g_PlayerDROption[i][propOnOff] == DrON)
        {
            BuildDamageString(i, -1);
        }
    }

    // Find player who did the most damage
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

    // Find player with most kills
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

    // Announce results
    if (mostDamage > 0)
    {
        char displayName[DR_NAME_MAX_TOTAL + 1];
        FormatPlayerName(displayName, sizeof(displayName), g_PlayerName[mostDamagePlayer]);

        PrintToChatAll("\x04Most DMG!: \x03%s %ddmg in %d hits!", displayName, mostDamage, mostHits);
    }

    if (mostKills > 0)
    {
        char displayName[DR_NAME_MAX_TOTAL + 1];
        FormatPlayerName(displayName, sizeof(displayName), g_PlayerName[mostKillsPlayer]);

        PrintToChatAll("\x04Most KILLS!: \x03%s with %d kills", displayName, mostKills);
    }
}


void FormatPlayerName(char[] out, int outSize, const char[] name)
{
    int len = strlen(name);

    // If name fits within chars, copy as-is
    if (len <= DR_NAME_MAX_TOTAL)
    {
        strcopy(out, outSize, name);
        return;
    }

    // Otherwise truncate + "..."
    strcopy(out, outSize, name);
    out[DR_NAME_TRUNCATE_AT] = '\0';
    StrCat(out, outSize, "...");
}

//only use outside of gameplay time large interation
public void clearAllDamageData()
{
    // Reset WORLD label defensively (index 0)
    strcopy(g_PlayerName[0], sizeof(g_PlayerName[]), "WORLD");

    //Clear WORLD-related data explicitly.
    for (int i = 1; i <= g_maxClients; i++)
    {
        g_DamageDone[0][i]   = 0;
        g_HitsDone[0][i]     = 0;
        g_KilledPlayer[0][i] = 0;

        g_DamageTaken[i][0] = 0;
        g_HitsTaken[i][0]   = 0;
        
        for (int k = 0; k <= MAXHITGROUPS; k++)
        {
            g_HitboxDone[0][i][k]  = 0;
            g_HitboxTaken[i][0][k] = 0;
        }
    }

    //Clear all player-vs-player data.
    //Start loops at 1 to avoid unnecessary WORLD clearing.
	//lot of interations use sparingly
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
