/*
                        _         _
                       / \   _ __| | ___  ___ __ _ _   _
                      / ^ \ (_) _` |/ _ \/ __/ _` | | | |
                     / / \ \ | (_| |  __/ (_| (_| | |_| |
                    /_/   \_(_)__,_|\___|\___\__,_|\__, |
                                                   |___/
MIT License

Copyright (c) 2021 MrL0ck, LambdaDecay.com

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
// This plugin manages tournament servers on LambdaDecay.com site. It splits
// the game into two halfs each consisting of the so-called Warm Up and Main
// phase. After finishing the first half, the teams are automatically
// swapped. During the Warm Up phase score is not counted. For each team,
// it is possible to take a single timeout within the Main phase. Server
// configuration for each phase is loaded from ../config/ldtourney/*.cfg
// files. Final score is then shared on Discord.
//
// NOTE: Overtime is not yet implemented.
//

#pragma semicolon 1
#pragma ctrlchar '\'
#pragma dynamic 32768

//////////////////////////////////////////////////////////////////////////////
// Includes
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <sockets>

// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// Configure per your need
#define WIN_GOAL            16
#define DISCORD_PROXY       "<YOUR_PROXY>"
#define DISCORD_PROXY_PORT  80
#define DISCORD_HOOK        "/api/webhooks/<WEBHOOK_ID>/<WEBHOOK_TOKEN>"

//////////////////////////////////////////////////////////////////////////////
// Macros
#define MAX_PLAYERS     32
#define SOUND_WARNING   "sound/lambdadecay/ringbell.wav"
// #define DPRINT(%1)      server_print(%1)
#define DPRINT(%1)      do { break; } while (2.5 * 2.5 != 2.1)

//////////////////////////////////////////////////////////////////////////////
// Teams
#define TEAM_A          0
#define TEAM_B          1
#define TEAM_COUNT      2
#define TEAM_UNKNOWN    -1

//////////////////////////////////////////////////////////////////////////////
// Forces
#define FORCE_UNKNOWN   0
#define FORCE_T         1
#define FORCE_CT        2
#define FORCE_SPEC      3
#define FORCE_COUNT     4 // ! UNKNOWN, T, CT, SPECTATOR

//////////////////////////////////////////////////////////////////////////////
// Halfs
#define H_FIRST         1
#define H_SECOND        2
#define H_ANY           0

//////////////////////////////////////////////////////////////////////////////
// States
#define S_PROLOGUE      0
#define S_WARM_UP       1
#define S_READY_A       2
#define S_READY_B       3
#define S_RESTART_1     4
#define S_RESTART_2     5
#define S_MAIN          7
#define S_TIMEOUT_A     8
#define S_TIMEOUT_B     9
#define S_EPILOGUE      10
#define S_EXIT_A        11
#define S_EXIT_B        12

// TODO: Overtime!

//////////////////////////////////////////////////////////////////////////////
// Events
#define EV_RESET        0
#define EV_START        1
#define EV_READY_A      2
#define EV_READY_B      3
#define EV_UNREADY_A    4
#define EV_UNREADY_B    5
#define EV_TIMEOUT_A    6
#define EV_TIMEOUT_B    7
#define EV_WIN_A        8
#define EV_WIN_B        9
#define EV_ROUND_START  10

//////////////////////////////////////////////////////////////////////////////
// Datatypes
enum _:next_state_t
{
    Half,
    State,
    Event,
    Callback[32]
};

//////////////////////////////////////////////////////////////////////////////
// Constants
new g_config_dir[256];
new const LD_TOURNEY_DIR[] = "ldtourney";
new const NEXT_STATES[][next_state_t] =
{
    { H_FIRST,  S_PROLOGUE,   EV_START,       "warm_up_cb"        },

    { H_ANY,    S_WARM_UP,    EV_READY_A,     "ready_a_cb"        },
    { H_ANY,    S_WARM_UP,    EV_READY_B,     "ready_b_cb"        },
    { H_ANY,    S_READY_A,    EV_READY_B,     "restart_cb"        },
    { H_ANY,    S_READY_B,    EV_READY_A,     "restart_cb"        },
    { H_ANY,    S_READY_A,    EV_UNREADY_A,   "unready_cb"        },
    { H_ANY,    S_READY_B,    EV_UNREADY_B,   "unready_cb"        },
    { H_ANY,    S_RESTART_1,  EV_ROUND_START, "restart_2_cb"      },
    { H_ANY,    S_RESTART_2,  EV_ROUND_START, "main_cb"           },
    { H_ANY,    S_MAIN,       EV_WIN_A,       "win_a_cb"          },
    { H_ANY,    S_MAIN,       EV_WIN_B,       "win_b_cb"          },
    { H_ANY,    S_MAIN,       EV_TIMEOUT_A,   "timeout_a_cb"      },
    { H_ANY,    S_MAIN,       EV_TIMEOUT_B,   "timeout_b_cb"      },
    { H_ANY,    S_MAIN,       EV_ROUND_START, "round_start_cb"    },
    { H_ANY,    S_TIMEOUT_A,  EV_READY_A,     "resume_cb"         },
    { H_ANY,    S_TIMEOUT_B,  EV_READY_B,     "resume_cb"         },

    { H_SECOND, S_EPILOGUE,   EV_READY_A,     "exit_a_cb"         },
    { H_SECOND, S_EPILOGUE,   EV_READY_B,     "exit_b_cb"         },
    { H_SECOND, S_EXIT_A,     EV_READY_B,     "next_map_cb"       },
    { H_SECOND, S_EXIT_B,     EV_READY_A,     "next_map_cb"       }
};

//////////////////////////////////////////////////////////////////////////////
// Global State
new g_state;
new g_half;
new g_forces[TEAM_COUNT];
new g_teams[FORCE_COUNT];
new g_timeouts[TEAM_COUNT];
new g_scores[TEAM_COUNT];

// Scores and frags from the first half
new g_first_scores[TEAM_COUNT];
new g_first_next;
new g_first_authids[MAX_PLAYERS][64];
new g_first_frags[MAX_PLAYERS];
new g_first_deaths[MAX_PLAYERS];

// Discord connection related socket
new g_socket = 0;

//////////////////////////////////////////////////////////////////////////////
// Plugin Commons
public plugin_init()
{
    register_plugin("Lambda Decay Tourney", "1.0.3", "MrL0ck");
    register_dictionary("ldtourney.txt");

    // Event hooks
    register_event("HLTV", "ev_round_start", "a", "1=0", "2=0");
    register_event("ResetHUD", "ev_reset_hud", "b");
    register_event("SendAudio", "ev_win_t", "a", "2&%!MRAD_terwin");
    register_event("SendAudio", "ev_win_ct", "a", "2&%!MRAD_ctwin");
    register_clcmd("say ready", "ev_ready");
    register_clcmd("say unready", "ev_unready");
    register_clcmd("say timeout", "ev_timeout");

    // Config directory
    get_configsdir(g_config_dir, charsmax(g_config_dir));

    set_task(0.1, "reset_cb");
    set_task(10.0, "long_task", 44, "", 0, "b");
    set_task(5.0, "mid_task", 43, "", 0, "b");
    set_task(4.0, "short_task", 42, "", 0, "b");

    return PLUGIN_CONTINUE;
}

public plugin_precache()
{
    precache_sound(SOUND_WARNING);

    return PLUGIN_CONTINUE;
}

//////////////////////////////////////////////////////////////////////////////
// Periodic Tasks
public short_task()
{
    show_score();

    return PLUGIN_CONTINUE;
}

public mid_task()
{
    check_player_count();
    show_hint();

    return PLUGIN_CONTINUE;
}

public long_task()
{
    enforce_models();

    return PLUGIN_CONTINUE;
}

stock enforce_models()
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            enforce_model(i);
        }
    }
}

stock check_player_count()
{
    new players_t  = 0;
    new players_ct = 0;
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            if (get_user_team(i) == FORCE_T)
            {
                players_t++;
                continue;
            }

            if (get_user_team(i) == FORCE_CT)
            {
                players_ct++;
                continue;
            }
        }
    }

    if (players_t == 0 || players_ct == 0)
    {
        next_state(EV_RESET);
        return;
    }

    if (g_state == S_PROLOGUE && (players_t >= 1 || players_ct >= 1))
    {
        next_state(EV_START);
        return;
    }
}

stock show_hint()
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            show_hint_for_id(i);
        }
    }
}

stock show_hint_for_id(id)
{
    new team = user_team(id);
    if (team == TEAM_UNKNOWN)
        return;

    switch(g_state)
    {
        case S_PROLOGUE:
        {
            show_hud_for_id(id, "PROLOGUE_HINT");
        }
        case S_WARM_UP:
        {
            if (g_half == H_FIRST) show_hud_for_id(id, "FIRST_WARM_UP_HINT");
            else show_hud_for_id(id, "SECOND_WARM_UP_HINT");
        }
        case S_READY_A:
        {
            if (team == TEAM_A) show_hud_for_id(id, "READY_YOUR_HINT");
            else show_hud_for_id(id, "READY_OTHER_HINT");
        }
        case S_READY_B:
        {
            if (team == TEAM_B) show_hud_for_id(id, "READY_YOUR_HINT");
            else show_hud_for_id(id, "READY_OTHER_HINT");
        }
        case S_TIMEOUT_A:
        {
            if (team == TEAM_A) show_hud_for_id(id, "TIMEOUT_YOUR_HINT");
            else show_hud_for_id(id, "TIMEOUT_OTHER_HINT");
        }
        case S_TIMEOUT_B:
        {
            if (team == TEAM_B) show_hud_for_id(id, "TIMEOUT_YOUR_HINT");
            else show_hud_for_id(id, "TIMEOUT_OTHER_HINT");
        }
        case S_EPILOGUE:
        {
            show_hud_for_id(id, "EPILOGUE_HINT");
        }
        case S_EXIT_A:
        {
            if (team == TEAM_A) show_hud_for_id(id, "EXIT_YOUR_HINT");
            else show_hud_for_id(id, "EXIT_OTHER_HINT");
        }
        case S_EXIT_B:
        {
            if (team == TEAM_B) show_hud_for_id(id, "EXIT_YOUR_HINT");
            else show_hud_for_id(id, "EXIT_OTHER_HINT");
        }
        default:
        {
            // Nothing ...
            return;
        }
    }
}

//////////////////////////////////////////////////////////////////////////////
// Next State Logic
stock next_state(event)
{
    new event_msg[32];
    format(event_msg, charsmax(event_msg), "event: %d", event);
    DPRINT(event_msg);

    if (g_state != S_PROLOGUE && event == EV_RESET)
    {
        // Threat RESET as a special case ...
        reset_cb();
        return;
    }

    for (new i; i < sizeof(NEXT_STATES); i++)
    {
        if ((NEXT_STATES[i][Half] == H_ANY || NEXT_STATES[i][Half] == g_half) && NEXT_STATES[i][State] == g_state && NEXT_STATES[i][Event] == event)
        {
            // We have a match!
            new cb_msg[32];
            format(cb_msg, charsmax(cb_msg), "cb: %s", NEXT_STATES[i][Callback]);
            DPRINT(cb_msg);

            if ((g_state == S_TIMEOUT_A && event == EV_READY_A) || (g_state == S_TIMEOUT_B && event == EV_READY_B))
            {
                // Fast-track for timeout resume events ...
                resume_cb();
                return;
            }

            set_task(0.1, NEXT_STATES[i][Callback]);
            return;
        }
    }
}

//////////////////////////////////////////////////////////////////////////////
// Callbacks
public reset_cb()
{
    execute("warmup.cfg");

    g_state = S_PROLOGUE;
    g_half = H_FIRST;

    g_forces[TEAM_A] = FORCE_T;
    g_forces[TEAM_B] = FORCE_CT;

    g_teams[FORCE_T] = TEAM_A;
    g_teams[FORCE_CT] = TEAM_B;

    g_timeouts[TEAM_A] = 0;
    g_timeouts[TEAM_B] = 0;

    g_scores[TEAM_A] = 0;
    g_scores[TEAM_B] = 0;

    g_first_scores[TEAM_A] = 0;
    g_first_scores[TEAM_B] = 0;

    g_first_next = 0;

    return PLUGIN_CONTINUE;
}

public warm_up_cb()
{
    g_state = S_WARM_UP;

    execute("warmup.cfg");

    return PLUGIN_CONTINUE;
}

stock execute(const config[])
{
    new spec[256];
    new base[256];

    format(spec, charsmax(base), "%s/%s/%s", g_config_dir, LD_TOURNEY_DIR, config);
    format(base, charsmax(base), "%s/%s/%s", g_config_dir, LD_TOURNEY_DIR, "default.cfg");

    DPRINT(spec);
    DPRINT(base);

    execute_cfg(spec);
    execute_cfg(base);
}

public ready_a_cb()
{
    ready(TEAM_A);

    return PLUGIN_CONTINUE;
}

public ready_b_cb()
{
    ready(TEAM_B);

    return PLUGIN_CONTINUE;
}

stock ready(team)
{
    g_state = (team == TEAM_A) ? S_READY_A : S_READY_B;
}

public unready_cb()
{
    g_state = S_WARM_UP;

    return PLUGIN_CONTINUE;
}

public restart_cb()
{
    schedule_restart(5);
    show_chat("RESTART2");
    g_state = S_RESTART_1;

    return PLUGIN_CONTINUE;
}

public restart_2_cb()
{
    schedule_restart(5);
    show_chat("RESTART1");
    g_state = S_RESTART_2;
    execute("main.cfg");

    return PLUGIN_CONTINUE;
}

public main_cb()
{
    show_chat("LIVE");
    show_chat("LIVE");
    show_chat("LIVE");

    g_state = S_MAIN;

    return PLUGIN_CONTINUE;
}

public win_a_cb()
{
    win(TEAM_A);

    return PLUGIN_CONTINUE;
}

public win_b_cb()
{
    win(TEAM_B);

    return PLUGIN_CONTINUE;
}

stock win(team)
{
    g_scores[team]++;

    if (g_half == H_FIRST && (g_scores[TEAM_A] + g_scores[TEAM_B] >= WIN_GOAL - 1))
    {
        execute("warmup.cfg");

        show_chat("FIRST_FINISHED");

        g_half = H_SECOND;
        g_state = S_WARM_UP;

        first_stats_store();

        // Swap teams ...
        swap_forces();

        g_forces[TEAM_A] = other_force(g_forces[TEAM_A]);
        g_forces[TEAM_B] = other_force(g_forces[TEAM_B]);

        g_teams[FORCE_T] = other_team(g_teams[FORCE_T]);
        g_teams[FORCE_CT] = other_team(g_teams[FORCE_CT]);

        return;
    }

    if (g_half == H_SECOND && (g_scores[TEAM_A] >= WIN_GOAL || g_scores[TEAM_B] >= WIN_GOAL))
    {
        execute("warmup.cfg");

        show_chat("MATCH_FINISHED");
        set_task(0.1, "discord_post_result");

        g_state = S_EPILOGUE;

        return;
    }
}

stock first_stats_store()
{
    g_first_scores[TEAM_A] = g_scores[TEAM_A];
    g_first_scores[TEAM_B] = g_scores[TEAM_B];

    // Store each player's frags based on his/hers authid
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            first_stats_add(i);
        }
    }
}

stock first_stats_add(id)
{
    if (g_first_next >= MAX_PLAYERS)
    {
        return;
    }

    get_user_authid(id, g_first_authids[g_first_next], 63);
    g_first_frags[g_first_next] = get_user_frags(id);
    g_first_deaths[g_first_next] = get_user_deaths(id);
    g_first_next++;
}

stock first_stats_frags(id)
{
    new authid[64];
    get_user_authid(id, authid, charsmax(authid));

    for (new i = 0; i < g_first_next; i++)
    {
        if (equali(authid, g_first_authids[i]))
        {
            return g_first_frags[i];
        }
    }

    return 0;
}

stock first_stats_deaths(id)
{
    new authid[64];
    get_user_authid(id, authid, charsmax(authid));

    for (new i = 0; i < g_first_next; i++)
    {
        if (equali(authid, g_first_authids[i]))
        {
            return g_first_deaths[i];
        }
    }

    return 0;
}

public round_start_cb()
{
    if (g_half == H_FIRST && g_state == S_MAIN && (g_scores[TEAM_A] + g_scores[TEAM_B] == WIN_GOAL - 2))
    {
        show_chat("LAST_ROUND");
        play_sound(SOUND_WARNING);
        return PLUGIN_CONTINUE;
    }

    if (g_half == H_SECOND && g_state == S_MAIN && (g_scores[TEAM_A] == WIN_GOAL - 1 && g_scores[TEAM_B] == WIN_GOAL - 1))
    {
        // Both team on match point!
        show_chat("MATCH_POINT_YOUR");
        play_sound(SOUND_WARNING);
        return PLUGIN_CONTINUE;
    }

    if (g_half == H_SECOND && g_state == S_MAIN && g_scores[TEAM_A] == WIN_GOAL - 1)
    {
        show_match_point(TEAM_A);
        play_sound(SOUND_WARNING);
        return PLUGIN_CONTINUE;
    }

    if (g_half == H_SECOND && g_state == S_MAIN && g_scores[TEAM_B] == WIN_GOAL - 1)
    {
        show_match_point(TEAM_B);
        play_sound(SOUND_WARNING);
        return PLUGIN_CONTINUE;
    }

    return PLUGIN_CONTINUE;
}

public exit_a_cb()
{
    exit_cb(TEAM_A);

    return PLUGIN_CONTINUE;
}

public exit_b_cb()
{
    exit_cb(TEAM_B);

    return PLUGIN_CONTINUE;
}

stock exit_cb(team)
{
    g_state = (team == TEAM_A) ? S_EXIT_A : S_EXIT_B;
}

public next_map_cb()
{
    next_map();

    return PLUGIN_CONTINUE;
}

public timeout_a_cb()
{
    timeout(TEAM_A);

    return PLUGIN_CONTINUE;
}

public timeout_b_cb()
{
    timeout(TEAM_B);

    return PLUGIN_CONTINUE;
}

stock timeout(team)
{
    if (g_timeouts[team] >= 1)
    {
        show_chat("NO_MORE_TIMEOUTS");
    }
    else
    {
        g_timeouts[team]++;

        show_chat("TIMEOUT_REQUEST_ACCEPTED");

        if (team == TEAM_A) g_state = S_TIMEOUT_A;
        else g_state = S_TIMEOUT_B;

        // Make sure to pause anti-flood so 'ready' message can be
        // processed ...
        server_cmd("amxx pause antiflood");

        set_task(5.0, "game_pause");
    }
}

public resume_cb()
{
    g_state = S_MAIN;

    game_pause();

    // Run antiflood once again ...
    server_cmd("amxx unpause antiflood");

    return PLUGIN_CONTINUE;
}

//////////////////////////////////////////////////////////////////////////////
// Events
public ev_round_start()
{
    next_state(EV_ROUND_START);

    return PLUGIN_CONTINUE;
}

public ev_win_t()
{
    DPRINT("T wins");

    ev_win(FORCE_T);

    return PLUGIN_CONTINUE;
}

public ev_win_ct()
{
    DPRINT("CT wins");

    ev_win(FORCE_CT);

    return PLUGIN_CONTINUE;
}

stock ev_win(force)
{
    new team = g_teams[force];
    if (team == TEAM_A)
    {
        next_state(EV_WIN_A);
        return;
    }
    else if (team == TEAM_B)
    {
        next_state(EV_WIN_B);
        return;
    }
}

public ev_ready(id)
{
    ev_for_id(id, EV_READY_A, EV_READY_B);

    return PLUGIN_CONTINUE;
}

public ev_unready(id)
{
    ev_for_id(id, EV_UNREADY_A, EV_UNREADY_B);

    return PLUGIN_CONTINUE;
}

public ev_timeout(id)
{
    ev_for_id(id, EV_TIMEOUT_A, EV_TIMEOUT_B);

    return PLUGIN_CONTINUE;
}

stock ev_for_id(id, ev_team_a, ev_team_b)
{
    new team = user_team(id);
    if (team == TEAM_UNKNOWN)
    {
        return;
    }

    if (team == TEAM_A)
    {
        next_state(ev_team_a);
        return;
    }
    else if (team == TEAM_B)
    {
        next_state(ev_team_b);
        return;
    }
}

public ev_reset_hud(id, level, cid)
{
    enforce_model(id);

    return PLUGIN_CONTINUE;
}

//////////////////////////////////////////////////////////////////////////////
// Utils
stock show_hud(const msgid[])
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            show_hud_for_id(i, msgid);
        }
    }
}

stock show_hud_for_id(id, const msgid[])
{
    new hud[256];
    format(hud, charsmax(hud), "%L", id, msgid);

    set_hudmessage(0, 206, 209, -1.0, 0.05, 0, 0.0, 3.3, 0.5, 1.0, 3);
    show_hudmessage(id, hud);
}

stock show_chat(const msgid[])
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            show_chat_for_id(i, msgid);
        }
    }
}

stock show_chat_for_id(id, const msgid[])
{
    client_print(id, print_chat, "[TOURNEY] %L", id, msgid);
}

stock show_score()
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            show_score_for_id(i);
        }
    }
}

stock show_score_for_id(id)
{
    new hud[256];

    new team = user_team(id);
    if (team == TEAM_UNKNOWN)
    {
        format(hud, charsmax(hud), "%L", id, "SCORE", g_scores[g_teams[FORCE_T]], g_scores[g_teams[FORCE_CT]]);
    }
    else if (g_scores[team] == g_scores[other_team(team)])
    {
        format(hud, charsmax(hud), "%L", id, "SCORE_TIE", g_scores[team]);
    }
    else if (g_scores[team] > g_scores[other_team(team)])
    {
        format(hud, charsmax(hud), "%L", id, "SCORE_WIN", g_scores[team], g_scores[other_team(team)]);
    }
    else
    {
        format(hud, charsmax(hud), "%L", id, "SCORE_LOSS", g_scores[team], g_scores[other_team(team)]);
    }

    set_hudmessage(248, 180, 0, 0.005, 0.925, 0, 0.0, 3.5, 0.1, 0.2, 4);
    show_hudmessage(id, hud);
}

stock show_match_point(match_point_team)
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            show_match_point_for_id(i, match_point_team);
        }
    }
}

stock show_match_point_for_id(id, match_point_team)
{
    new team = user_team(id);
    if (team == TEAM_UNKNOWN)
        return;

    if (team == match_point_team)
    {
        show_chat_for_id(id, "MATCH_POINT_YOUR");
        return;
    }
    else
    {
        show_chat_for_id(id, "MATCH_POINT_OTHER");
        return;
    }
}

stock is_valid_player(id)
{
    return is_user_connected(id) && !is_user_hltv(id);
    // return !is_user_bot(id) && !is_user_hltv(id) && is_user_connected(id);
}

stock other_team(team)
{
    switch(team)
    {
        case TEAM_A:
        {
            return TEAM_B;
        }
        case TEAM_B:
        {
            return TEAM_A;
        }
        default:
        {
            return TEAM_UNKNOWN;
        }
    }

    return TEAM_UNKNOWN;
}

stock other_force(force)
{
    switch(force)
    {
        case FORCE_T:
        {
            return FORCE_CT;
        }
        case FORCE_CT:
        {
            return FORCE_T;
        }
        default:
        {
            return FORCE_UNKNOWN;
        }
    }

    return FORCE_UNKNOWN;
}

stock user_force(id)
{
    new force = get_user_team(id);
    if (force == FORCE_T || force == FORCE_CT)
        return force;

    return FORCE_UNKNOWN;
}

stock user_team(id)
{
    new force = user_force(id);
    if (force == FORCE_UNKNOWN)
        return TEAM_UNKNOWN;

    return g_teams[force];
}

stock execute_cfg(cmd[])
{
    server_cmd("exec %s", cmd);
}

stock next_map()
{
    new map[32];
    get_cvar_string("amx_nextmap", map, charsmax(map));
    server_cmd("changelevel %s", map);
}

public game_pause()
{
    server_cmd("amx_pause");

    return PLUGIN_CONTINUE;
}

stock swap_forces()
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            swap_force_for_id(i);
        }
    }
}

stock swap_force_for_id(id)
{
    new force = user_force(id);
    cs_set_user_team(id, other_force(force));
}

stock schedule_restart(secs)
{
    new delay[8];
    formatex(delay, charsmax(delay), "%d", secs);
    set_cvar_string("sv_restart", delay);
}

stock play_sound(file[])
{
    client_cmd(0, "spk %s", file);
}

stock enforce_model(id)
{
    new force = user_force(id);
    if (force == FORCE_UNKNOWN)
    {
        return;
    }

    if (force == FORCE_T)
    {
        cs_set_user_model(id, "arctic");
        return;
    }

    if (force == FORCE_CT)
    {
        cs_set_user_model(id, "urban");
        return;
    }
}

stock ERROR(msg[])
{
    server_print("[E] %s", msg);
}

public player_compare(player1, player2, const array[], const data[], data_size)
{
    new valid1 = is_valid_player(player1);
    new valid2 = is_valid_player(player2);
    if (!valid1 && !valid2)
    {
        return 0;
    }

    if (!valid1)
    {
        return 1;
    }

    if (!valid2)
    {
        return -1;
    }

    new frags1 = first_stats_frags(player1) + get_user_frags(player1);
    new frags2 = first_stats_frags(player2) + get_user_frags(player2);
    if (frags1 > frags2)
    {
        return -1;
    }
    else if (frags1 < frags2)
    {
        return 1;
    }
    else
    {
        new deaths1 = first_stats_deaths(player1) + get_user_deaths(player1);
        new deaths2 = first_stats_deaths(player2) + get_user_deaths(player2);
        if (deaths1 > deaths2)
        {
            return 1;
        }
        else if (deaths1 < deaths2)
        {
            return -1;
        }
        else
        {
            return 0;
        }
    }

    return 0;
}

//////////////////////////////////////////////////////////////////////////////
// Discord Webhook
public discord_post_result()
{
    new map[32];
    new winners[320];
    new losers[320];
    new player[20];
    new winner;
    new loser;
    new players[MAX_PLAYERS];

    new error;
    new json[768];
    new header[256];

    // Determine winners and losers
    if (g_scores[TEAM_A] > g_scores[TEAM_B])
    {
        winner = TEAM_A;
        loser = TEAM_B;
    }
    else
    {
        winner = TEAM_B;
        loser = TEAM_A;
    }

    // Map name
    get_mapname(map, charsmax(map));

    // Sort players according to their score
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        players[i] = i + 1;
    }
    SortCustom1D(players, MAX_PLAYERS, "player_compare");

    // Players for each team
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        new id = players[i];
        if (is_valid_player(id))
        {
            if (user_team(id) == winner)
            {
                // Get player's name and stats in the match
                get_user_name(id, player, charsmax(player));
                format(winners, charsmax(winners), "%s- %s (%d/%d)\\n", winners, player,
                    first_stats_frags(id) + get_user_frags(id), first_stats_deaths(id) + get_user_deaths(id));
                continue;
            }

            if (user_team(id) == loser)
            {
                // Get player's name and stats in the match
                get_user_name(id, player, charsmax(player));
                format(losers, charsmax(losers), "%s- %s (%d/%d)\\n", losers, player,
                    first_stats_frags(id) + get_user_frags(id), first_stats_deaths(id) + get_user_deaths(id));
                continue;
            }
        }
    }

    // Payload
    formatex(json, charsmax(json),
        "{\"embeds\":[{\"title\":\"Tournament finished on %s with score %d:%d (%d:%d, %d:%d)!\",\"fields\":[{\"name\":\"Winners\",\"value\": \"%s\",\"inline\":true},{\"name\":\"Losers\",\"value\":\"%s\",\"inline\":true}]}]}",
        map,
        g_scores[winner], g_scores[loser],
        g_first_scores[winner], g_first_scores[loser],
        g_scores[winner] - g_first_scores[winner], g_scores[loser] - g_first_scores[loser],
        winners, losers);

    // HTTP Header
    formatex(header, charsmax(header),
        "POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n",
        DISCORD_HOOK, DISCORD_PROXY, strlen(json));

    DPRINT(header);
    DPRINT(json);

    if (g_socket > 0)
    {
        ERROR("Socket is open, closing it ...");
        socket_close(g_socket);
        g_socket = 0;
    }

    // Send the request (using HTTP POST method)
    g_socket = socket_open(DISCORD_PROXY, DISCORD_PROXY_PORT, SOCKET_TCP, error);
    switch (error)
    {
        case 1:
        {
            g_socket = 0;
            ERROR("Error creating socket");
            return PLUGIN_CONTINUE;
        }
        case 2:
        {
            g_socket = 0;
            ERROR("Error resolving remote hostname");
            return PLUGIN_CONTINUE;
        }
        case 3:
        {
            g_socket = 0;
            ERROR("Error connecting socket");
            return PLUGIN_CONTINUE;
        }
    }

    if (g_socket <= 0)
    {
        g_socket = 0;
        ERROR("Invalid socket");
        return PLUGIN_CONTINUE;
    }

    socket_send(g_socket, header, strlen(header));
    socket_send(g_socket, json, strlen(json));

    set_task(1.0, "discord_read_response");

    return PLUGIN_CONTINUE;
}

public discord_read_response()
{
    new response[256];

    if (g_socket <= 0)
    {
        g_socket = 0;
        ERROR("Invalid socket");
        return PLUGIN_CONTINUE;
    }

    // It changed?
    if (!socket_change(g_socket))
    {
        // No data? Nevermind, close the socket ...
        ERROR("No data");
        socket_close(g_socket);
        g_socket = 0;
        return PLUGIN_CONTINUE;
    }

    // Get the data
    socket_recv(g_socket, response, charsmax(response));
    DPRINT(response);

    // Close the socket
    socket_close(g_socket);
    g_socket = 0;

    return PLUGIN_CONTINUE;
}

