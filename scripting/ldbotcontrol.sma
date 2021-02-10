/*
                        _         _
                       / \   _ __| | ___  ___ __ _ _   _
                      / ^ \ (_) _` |/ _ \/ __/ _` | | | |
                     / / \ \ | (_| |  __/ (_| (_| | |_| |
                    /_/   \_(_)__,_|\___|\___\__,_|\__, |
                                                   |___/
MIT License

Copyright (c) 2020 MrL0ck, LambdaDecay.com

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

//////////////////////////////////////////////////////////////////////////////
// Description
//
// This simple plugin manages amount of bots on LambdaDecay.com servers.
// Without any overrides, it balances teams by adding BOTs so they always
// have the same number of players. If a team consists only from BOT players,
// to give it an advantage, additional one, two, or three BOT(s) are added
// to it. Finally, manual override of BOT count per each team is allowed via 
// "/bott", "/botct", and "/botreset" say commands.
//

#pragma semicolon 1
#pragma ctrlchar '\'

//////////////////////////////////////////////////////////////////////////////
// Includes
#include <amxmodx>

//////////////////////////////////////////////////////////////////////////////
// Macros
#define TEAM_T           1
#define TEAM_CT          2
#define MAX_PLAYERS     32
#define MAX_OVERRIDE     3
#define TASK_ID         42
#define VIP_FLAG        ADMIN_LEVEL_H

//////////////////////////////////////////////////////////////////////////////
// Global State
new g_humans_t;
new g_humans_ct;

new g_bots_t;
new g_bots_ct;

new g_override_t;
new g_override_ct;

//////////////////////////////////////////////////////////////////////////////
// Plugin Commons
public plugin_init()
{
    register_plugin("LD Bot Control", "1.0.0", "MrL0ck");
    register_dictionary("ldbotcontrol.txt");

    // Event hooks
    register_clcmd("say /bott", "ev_add_override_t");
    register_clcmd("say /botct", "ev_add_override_ct");
    register_clcmd("say /botreset", "ev_reset_override");

    // Tasks
    set_task(10.0, "equalize_teams", TASK_ID, "", 0, "b");
}

//////////////////////////////////////////////////////////////////////////////
// Events
public client_putinserver(id)
{
    if (!is_human(id))
    {
        return;
    }

    set_task(0.5, "equalize_teams");
}

public client_disconnect(id)
{
    if (!is_human(id))
    {
        return;
    }

    // No time for delay here!
    equalize_teams();
}

public ev_add_override_t(id)
{
    if (!(get_user_flags(id) & VIP_FLAG))
    {
        show_chat("NO_PERMS");
        return;
    }

    if (g_override_t >= MAX_OVERRIDE)
    {
        show_chat("MAX_OVERRIDE_T");
        return;
    }

    g_override_t++;

    set_task(0.1, "equalize_teams");
}

public ev_add_override_ct(id)
{
    if (!(get_user_flags(id) & VIP_FLAG))
    {
        show_chat("NO_PERMS");
        return;
    }

    if (g_override_ct >= MAX_OVERRIDE)
    {
        show_chat("MAX_OVERRIDE_CT");
        return;
    }

    g_override_ct++;

    set_task(0.1, "equalize_teams");
}

public ev_reset_override(id)
{
    if (!(get_user_flags(id) & VIP_FLAG))
    {
        show_chat("NOPERMS");
        return;
    }

    g_override_t = 0;
    g_override_ct = 0;

    set_task(0.1, "equalize_teams");
}

//////////////////////////////////////////////////////////////////////////////
// Periodic Tasks
public equalize_teams()
{
    new humans_t;
    new humans_ct;

    new bots_t;
    new bots_ct;

    new advantage_t;
    new advantage_ct;

    new override_t;
    new override_ct;

    new target_t;
    new target_ct;

    new diff_t;
    new diff_ct;

    refresh();

    humans_t     = g_humans_t;
    humans_ct    = g_humans_ct;

    if (humans_t + humans_ct == 0)
    {
        // Remove any bot overrides if no humans are in the game.
        g_override_t = 0;
        g_override_ct = 0;
    }

    bots_t       = g_bots_t;
    bots_ct      = g_bots_ct;

    advantage_t  = get_advantage(humans_t, humans_ct);
    advantage_ct = get_advantage(humans_ct, humans_t);

    override_t   = g_override_t;
    override_ct  = g_override_ct;

    if (humans_t == humans_ct)
    {
        target_t = override_t;
        diff_t = target_t - bots_t;
        delta_bots(TEAM_T, diff_t);

        target_ct = override_ct;
        diff_ct = target_ct - bots_ct;
        delta_bots(TEAM_CT, diff_ct);
    }
    else if (humans_t > humans_ct)
    {
        target_t = override_t;
        diff_t = target_t - bots_t;
        delta_bots(TEAM_T, diff_t);

        target_ct = humans_t - humans_ct + advantage_ct + override_ct;
        diff_ct = target_ct - bots_ct;
        delta_bots(TEAM_CT, diff_ct);
    }
    else
    {
        target_t = humans_ct - humans_t + advantage_t + override_t;
        diff_t = target_t - bots_t;
        delta_bots(TEAM_T, diff_t);

        target_ct = override_ct;
        diff_ct = target_ct - bots_ct;
        delta_bots(TEAM_CT, diff_ct);
    }

    if (diff_t != 0 || diff_ct != 0)
    {
        show_chat("EQUALIZED");
    }
}

// Give some advantage to teams consisting only from bots ...
stock get_advantage(target_humans, other_humans)
{
    if (target_humans > 0)
        return 0;

    if (other_humans == 0)
        return 0;

    if (other_humans >= 1 && other_humans <= 2)
        return 1;

    if (other_humans >= 3 && other_humans <= 4)
        return 2;

    return 3;
}

stock refresh()
{
    g_humans_t  = 0;
    g_humans_ct = 0;

    g_bots_t    = 0;
    g_bots_ct   = 0;

    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (!is_user_connected(i))
            continue;

        if (is_human(i))
        {
            if (get_user_team(i) == TEAM_T)
            {
                g_humans_t++;
                continue;
            }

            if (get_user_team(i) == TEAM_CT)
            {
                g_humans_ct++;
                continue;
            }
        }

        if (is_bot(i))
        {
            if (get_user_team(i) == TEAM_T)
            {
                g_bots_t++;
                continue;
            }

            if (get_user_team(i) == TEAM_CT)
            {
                g_bots_ct++;
                continue;
            }
        }
    }
}

stock delta_bots(team, delta)
{
    if (delta < 0)
        kick_bots(team, -delta);
    else
        add_bots(team, delta);
}

stock add_bots(team, amount)
{
    for (new i = 0; i < amount; i++)
    {
        if (team == TEAM_T)
            server_cmd("bot_add_t");

        if (team == TEAM_CT)
            server_cmd("bot_add_ct");
    }
}

stock kick_bots(team, amount)
{
    new szName[64];
    for (new i = 1; i <= MAX_PLAYERS && amount > 0; i++)
    {
        if (is_bot(i) && get_user_team(i) == team)
        {
            get_user_name(i, szName, sizeof(szName));
            server_cmd("bot_kick \"%s\"", szName);
            amount--;
        }
    }
}

stock is_bot(id)
{
    return is_user_bot(id) && !is_user_hltv(id) && is_user_connected(id);
}

stock is_human(id)
{
    return !is_user_bot(id) && !is_user_hltv(id) && is_user_connected(id);
}

stock show_chat(const msgid[])
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_human(i))
        {
            show_chat_for_id(i, msgid);
        }
    }
}

stock show_chat_for_id(id, const msgid[])
{
    client_print(id, print_chat, "[BOTCONTROL] %L", id, msgid);
}
