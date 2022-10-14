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
// the game into periods each consisting of the so-called Warm Up and Main
// phase. After finishing a period, the teams are automatically swapped.
// During the Warm Up phase score is not counted. For each team, it is
// possible to take timeouts within the Main phase. Server configuration
// for each phase is loaded from ../config/ldtourney/*.cfg files. Final
// score can then be shared on a result server.
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
// Cvars and their default values
#define VIP_FLAG                        ADMIN_ADMIN

#define CVAR_WIN_GOAL                   "ld_tourney_wingoal"
#define CVAR_OVERTIME_GOAL              "ld_tourney_overtimegoal"
#define CVAR_OVERTIME_MONEY             "ld_tourney_overtimemoney"
#define CVAR_MAX_TIMEOUTS               "ld_tourney_maxtimeouts"
#define CVAR_T_MODEL                    "ld_tourney_tmodel"
#define CVAR_CT_MODEL                   "ld_tourney_ctmodel"
#define CVAR_WARNING_SOUND              "ld_tourney_warningsound"
#define CVAR_RESULT_SERVER              "ld_tourney_resultserver"
#define CVAR_RESULT_SERVER_PORT         "ld_tourney_resultserverport"
#define CVAR_RESULT_URI                 "ld_tourney_resulturi"
#define CVAR_TOURNEY_NAME               "ld_tourney_tourneyname"
#define CVAR_TOURNEY_KEY                "ld_tourney_tourneykey"

#define DEFAULT_WIN_GOAL                "16"
#define DEFAULT_OVERTIME_GOAL           "4"
#define DEFAULT_OVERTIME_MONEY          "16000"
#define DEFAULT_MAX_TIMEOUTS            "1"
#define DEFAULT_T_MODEL                 "urban"
#define DEFAULT_CT_MODEL                "leet"
#define DEFAULT_WARNING_SOUND           "sound/lambdadecay/ringbell.wav"
#define DEFAULT_RESULT_SERVER           ""
#define DEFAULT_RESULT_SERVER_PORT      ""
#define DEFAULT_RESULT_URI              ""
#define DEFAULT_TOURNEY_NAME            ""
#define DEFAULT_TOURNEY_KEY             ""

#define INDEX_NUM_WIN_GOAL              0
#define INDEX_NUM_OVERTIME_GOAL         1
#define INDEX_NUM_OVERTIME_MONEY        2
#define INDEX_NUM_MAX_TIMEOUTS          3
#define INDEX_NUM_RESULT_SERVER_PORT    4
#define INDEX_NUM_COUNT                 5

#define CVAR_STRING_VALUE_MAX_LENGTH    64
#define INDEX_STRING_T_MODEL            0
#define INDEX_STRING_CT_MODEL           1
#define INDEX_STRING_WARNING_SOUND      2
#define INDEX_STRING_RESULT_SERVER      3
#define INDEX_STRING_RESULT_URI         4
#define INDEX_STRING_TOURNEY_NAME       5
#define INDEX_STRING_TOURNEY_KEY        6
#define INDEX_STRING_COUNT              7

//////////////////////////////////////////////////////////////////////////////
// Macros
#define MAX_PLAYERS         32
// #define DPRINT(%1)       server_print(%1)
#define DPRINT(%1)          do {} while (0)

//////////////////////////////////////////////////////////////////////////////
// Tasks
#define TASK_SHORT_ID       40
#define TASK_MIDDLE_ID      41
#define TASK_LONG_ID        42
#define TASK_CANCEL_ID      43

//////////////////////////////////////////////////////////////////////////////
// Teams
#define TEAM_A              0
#define TEAM_B              1
#define TEAM_COUNT          2
#define TEAM_UNKNOWN        -1

//////////////////////////////////////////////////////////////////////////////
// Forces
#define FORCE_UNKNOWN       0
#define FORCE_T             1
#define FORCE_CT            2
#define FORCE_SPEC          3
#define FORCE_COUNT         4 // ! UNKNOWN, T, CT, SPECTATOR

//////////////////////////////////////////////////////////////////////////////
// Periods
#define P_FIRST             0
#define P_SECOND            1
#define P_OVER_FIRST        2
#define P_OVER_SECOND       3
#define P_END               4

#define P_ANY               5
#define P_COUNT             4 // Do NOT include P_END to counted periods!

//////////////////////////////////////////////////////////////////////////////
// States
#define S_PROLOGUE          0
#define S_WARM_UP           1
#define S_READY_A           2
#define S_READY_B           3
#define S_RESTART_1         4
#define S_RESTART_2         5
#define S_MAIN              6
#define S_TIMEOUT_A         7
#define S_TIMEOUT_B         8
#define S_EPILOGUE          9
#define S_EXIT_A            10
#define S_EXIT_B            11
#define S_TOURNEY_RESET_A   12
#define S_TOURNEY_RESET_B   13
#define S_PERIOD_RESET_A    14
#define S_PERIOD_RESET_B    15

//////////////////////////////////////////////////////////////////////////////
// Events
#define EV_RESET            0
#define EV_START            1
#define EV_READY_A          2
#define EV_READY_B          3
#define EV_UNREADY_A        4
#define EV_UNREADY_B        5
#define EV_TIMEOUT_A        6
#define EV_TIMEOUT_B        7
#define EV_WIN_A            8
#define EV_WIN_B            9
#define EV_ROUND_START      10
#define EV_TOURNEY_RESET_A  11
#define EV_TOURNEY_RESET_B  12
#define EV_PERIOD_RESET_A   13
#define EV_PERIOD_RESET_B   14

//////////////////////////////////////////////////////////////////////////////
// Datatypes
enum _:next_state_t
{
    Period,
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
    { P_FIRST,  S_PROLOGUE,   EV_START,       "warm_up_cb"        },

    { P_FIRST,  S_WARM_UP,    EV_ROUND_START, "load_cvars_cb"     },
    { P_ANY,    S_WARM_UP,    EV_READY_A,     "ready_a_cb"        },
    { P_ANY,    S_WARM_UP,    EV_READY_B,     "ready_b_cb"        },
    { P_ANY,    S_READY_A,    EV_READY_B,     "restart_cb"        },
    { P_ANY,    S_READY_B,    EV_READY_A,     "restart_cb"        },
    { P_ANY,    S_READY_A,    EV_UNREADY_A,   "unready_cb"        },
    { P_ANY,    S_READY_B,    EV_UNREADY_B,   "unready_cb"        },
    { P_ANY,    S_RESTART_1,  EV_ROUND_START, "restart_2_cb"      },
    { P_FIRST,  S_RESTART_2,  EV_ROUND_START, "main_cb"           },
    { P_SECOND, S_RESTART_2,  EV_ROUND_START, "main_cb"           },
    { P_OVER_FIRST,  S_RESTART_2, EV_ROUND_START, "overtime_main_cb" },
    { P_OVER_SECOND, S_RESTART_2, EV_ROUND_START, "overtime_main_cb" },

    { P_ANY,    S_MAIN,       EV_WIN_A,       "win_a_cb"          },
    { P_ANY,    S_MAIN,       EV_WIN_B,       "win_b_cb"          },
    { P_ANY,    S_MAIN,       EV_ROUND_START, "round_start_cb"    },

    { P_ANY,    S_MAIN,       EV_TIMEOUT_A,   "timeout_a_cb"      },
    { P_ANY,    S_MAIN,       EV_TIMEOUT_B,   "timeout_b_cb"      },
    { P_ANY,    S_TIMEOUT_A,  EV_READY_A,     "resume_cb"         },
    { P_ANY,    S_TIMEOUT_B,  EV_READY_B,     "resume_cb"         },

    { P_ANY,    S_TIMEOUT_A,  EV_WIN_A,       "win_a_cb"          },
    { P_ANY,    S_TIMEOUT_A,  EV_WIN_B,       "win_b_cb"          },
    { P_ANY,    S_TIMEOUT_A,  EV_ROUND_START, "round_start_cb"    },
    { P_ANY,    S_TIMEOUT_B,  EV_WIN_A,       "win_a_cb"          },
    { P_ANY,    S_TIMEOUT_B,  EV_WIN_B,       "win_b_cb"          },
    { P_ANY,    S_TIMEOUT_B,  EV_ROUND_START, "round_start_cb"    },

    { P_ANY,    S_MAIN,             EV_TOURNEY_RESET_A, "tourney_reset_a_cb"    },
    { P_ANY,    S_MAIN,             EV_TOURNEY_RESET_B, "tourney_reset_b_cb"    },
    { P_ANY,    S_TOURNEY_RESET_A,  EV_TOURNEY_RESET_B, "tourney_reset_cb"      },
    { P_ANY,    S_TOURNEY_RESET_A,  EV_READY_A,         "tourney_unreset_cb"    },
    { P_ANY,    S_TOURNEY_RESET_B,  EV_TOURNEY_RESET_A, "tourney_reset_cb"      },
    { P_ANY,    S_TOURNEY_RESET_B,  EV_READY_B,         "tourney_unreset_cb"    },

    { P_ANY,    S_TOURNEY_RESET_A,  EV_WIN_A,           "win_a_cb"              },
    { P_ANY,    S_TOURNEY_RESET_A,  EV_WIN_B,           "win_b_cb"              },
    { P_ANY,    S_TOURNEY_RESET_A,  EV_ROUND_START,     "round_start_cb"        },
    { P_ANY,    S_TOURNEY_RESET_B,  EV_WIN_A,           "win_a_cb"              },
    { P_ANY,    S_TOURNEY_RESET_B,  EV_WIN_B,           "win_b_cb"              },
    { P_ANY,    S_TOURNEY_RESET_B,  EV_ROUND_START,     "round_start_cb"        },

    { P_ANY,    S_MAIN,             EV_PERIOD_RESET_A,  "period_reset_a_cb"     },
    { P_ANY,    S_MAIN,             EV_PERIOD_RESET_B,  "period_reset_b_cb"     },
    { P_ANY,    S_PERIOD_RESET_A,   EV_PERIOD_RESET_B,  "period_reset_cb"       },
    { P_ANY,    S_PERIOD_RESET_A,   EV_READY_A,         "period_unreset_cb"     },
    { P_ANY,    S_PERIOD_RESET_B,   EV_PERIOD_RESET_A,  "period_reset_cb"       },
    { P_ANY,    S_PERIOD_RESET_B,   EV_READY_B,         "period_unreset_cb"     },

    { P_ANY,    S_PERIOD_RESET_A,   EV_WIN_A,           "win_a_cb"              },
    { P_ANY,    S_PERIOD_RESET_A,   EV_WIN_B,           "win_b_cb"              },
    { P_ANY,    S_PERIOD_RESET_A,   EV_ROUND_START,     "round_start_cb"        },
    { P_ANY,    S_PERIOD_RESET_B,   EV_WIN_A,           "win_a_cb"              },
    { P_ANY,    S_PERIOD_RESET_B,   EV_WIN_B,           "win_b_cb"              },
    { P_ANY,    S_PERIOD_RESET_B,   EV_ROUND_START,     "round_start_cb"        },

    { P_END,    S_EPILOGUE,   EV_READY_A,     "exit_a_cb"         },
    { P_END,    S_EPILOGUE,   EV_READY_B,     "exit_b_cb"         },
    { P_END,    S_EXIT_A,     EV_READY_B,     "next_map_cb"       },
    { P_END,    S_EXIT_B,     EV_READY_A,     "next_map_cb"       }
};
new const MAIN_SUBSTATES[] =
{
    S_MAIN,
    S_TOURNEY_RESET_A, S_TOURNEY_RESET_B,
    S_PERIOD_RESET_A, S_PERIOD_RESET_B,
    S_TIMEOUT_A, S_TIMEOUT_B
};

//////////////////////////////////////////////////////////////////////////////
// Cvar settings
#define REGISTER_CVAR_STRING(%1)    g_cvar_ptrs[INDEX_NUM_COUNT+INDEX_STRING_%1] = register_cvar(CVAR_%1,DEFAULT_%1)
#define LOAD_CVAR_STRING(%1)        get_pcvar_string(g_cvar_ptrs[INDEX_NUM_COUNT+INDEX_STRING_%1],g_cvar_string_values[INDEX_STRING_%1],CVAR_STRING_VALUE_MAX_LENGTH-1)
#define GET_CVAR_STRING(%1,%2,%3)   copy(%2,%3,g_cvar_string_values[INDEX_STRING_%1])

#define REGISTER_CVAR_NUM(%1)       g_cvar_ptrs[INDEX_NUM_%1] = register_cvar(CVAR_%1,DEFAULT_%1)
#define LOAD_CVAR_NUM(%1)           g_cvar_num_values[INDEX_NUM_%1] = get_pcvar_num(g_cvar_ptrs[INDEX_NUM_%1])
#define GET_CVAR_NUM(%1)            g_cvar_num_values[INDEX_NUM_%1]

new g_cvar_ptrs[INDEX_NUM_COUNT+INDEX_STRING_COUNT];
new g_cvar_num_values[INDEX_NUM_COUNT];
new g_cvar_string_values[INDEX_STRING_COUNT][CVAR_STRING_VALUE_MAX_LENGTH];

//////////////////////////////////////////////////////////////////////////////
// Global State
new g_state;
new g_period;
new g_forces[TEAM_COUNT];
new g_teams[FORCE_COUNT];
new g_timeouts[TEAM_COUNT];
new g_scores[TEAM_COUNT];

// Scores and frags from the given period
new g_period_scores[P_COUNT][TEAM_COUNT];
new g_period_next[P_COUNT];
new g_period_authids[P_COUNT][MAX_PLAYERS][64];
new g_period_frags[P_COUNT][MAX_PLAYERS];
new g_period_deaths[P_COUNT][MAX_PLAYERS];

// Result server connection-related socket
new g_socket = 0;

//////////////////////////////////////////////////////////////////////////////
// Plugin Commons
public plugin_init()
{
    // Translations.
    register_dictionary("ldtourney.txt");

    // Event hooks.
    register_event("HLTV", "ev_round_start", "a", "1=0", "2=0");
    register_event("ResetHUD", "ev_reset_hud", "b");
    register_event("SendAudio", "ev_win_t", "a", "2&%!MRAD_terwin");
    // Target bombed!
    // register_event("23", "ev_win_t", "a", "1=17", "6=-105", "7=17");
    register_event("SendAudio", "ev_win_ct", "a", "2&%!MRAD_ctwin");
    // register_event("SendAudio", "ev_win_ct", "a", "2&%!MRAD_BOMBDEF");
    // register_event("TextMsg","ev_win_ct", "a", "2&#All_Hostages_R");
    register_clcmd("say ready", "ev_ready");
    register_clcmd("say unready", "ev_unready");
    register_clcmd("say timeout", "ev_timeout");
    register_clcmd("say reset", "ev_tourney_reset");
    register_clcmd("say restart", "ev_period_reset");

    // These events are for admins only.
    register_clcmd("say /result", "ev_post_result");

    // Config directory.
    get_configsdir(g_config_dir, charsmax(g_config_dir));

    // Timers.
    set_task(0.1,   "reset_cb");
    set_task(10.0,  "long_task",    TASK_LONG_ID,   "", 0, "b");
    set_task(5.0,   "middle_task",  TASK_MIDDLE_ID, "", 0, "b");
    set_task(4.0,   "short_task",   TASK_SHORT_ID,  "", 0, "b");

    return PLUGIN_CONTINUE;
}

public plugin_precache()
{
    new path[256];
    new model[64];

    // Register plugin before CVAR registration.
    register_plugin("Lambda Decay Tourney", "1.1.0", "MrL0ck");

    // This must be done early, since it is utilized by commands below.
    register_cvars();
    load_cvars();

    GET_CVAR_STRING(WARNING_SOUND, path, charsmax(path));
    precache_sound(path);

    GET_CVAR_STRING(T_MODEL, model, charsmax(model));
    formatex(path, charsmax(path), "models/player/%s/%s.mdl", model, model);
    precache_model(path);

    GET_CVAR_STRING(CT_MODEL, model, charsmax(model));
    formatex(path, charsmax(path), "models/player/%s/%s.mdl", model, model);
    precache_model(path);

    return PLUGIN_CONTINUE;
}

stock register_cvars()
{
    REGISTER_CVAR_NUM(WIN_GOAL);
    REGISTER_CVAR_NUM(OVERTIME_GOAL);
    REGISTER_CVAR_NUM(OVERTIME_MONEY);
    REGISTER_CVAR_NUM(MAX_TIMEOUTS);
    REGISTER_CVAR_STRING(T_MODEL);
    REGISTER_CVAR_STRING(CT_MODEL);
    REGISTER_CVAR_STRING(WARNING_SOUND);
    REGISTER_CVAR_STRING(RESULT_SERVER);
    REGISTER_CVAR_NUM(RESULT_SERVER_PORT);
    REGISTER_CVAR_STRING(RESULT_URI);
    REGISTER_CVAR_STRING(TOURNEY_NAME);
    REGISTER_CVAR_STRING(TOURNEY_KEY);
}

stock load_cvars()
{
    LOAD_CVAR_NUM(WIN_GOAL);
    LOAD_CVAR_NUM(OVERTIME_GOAL);
    LOAD_CVAR_NUM(OVERTIME_MONEY);
    LOAD_CVAR_NUM(MAX_TIMEOUTS);
    LOAD_CVAR_STRING(T_MODEL);
    LOAD_CVAR_STRING(CT_MODEL);
    LOAD_CVAR_STRING(WARNING_SOUND);
    LOAD_CVAR_STRING(RESULT_SERVER);
    LOAD_CVAR_NUM(RESULT_SERVER_PORT);
    LOAD_CVAR_STRING(RESULT_URI);
    LOAD_CVAR_STRING(TOURNEY_NAME);
    LOAD_CVAR_STRING(TOURNEY_KEY);
}

//////////////////////////////////////////////////////////////////////////////
// Periodic Tasks
public short_task()
{
    show_score();

    return PLUGIN_CONTINUE;
}

public middle_task()
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
            if (g_period == P_FIRST) show_hud_for_id(id, "FIRST_WARM_UP_HINT");
            else if (g_period == P_SECOND) show_hud_for_id(id, "SECOND_WARM_UP_HINT");
            else if (g_period == P_OVER_FIRST) show_hud_for_id(id, "OVERTIME_FIRST_WARM_UP_HINT");
            else show_hud_for_id(id, "OVERTIME_SECOND_WARM_UP_HINT");
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
        case S_TOURNEY_RESET_A:
        {
            if (team == TEAM_A) show_hud_for_id(id, "TOURNEY_RESET_YOUR_HINT");
            else show_hud_for_id(id, "TOURNEY_RESET_OTHER_HINT");
        }
        case S_TOURNEY_RESET_B:
        {
            if (team == TEAM_B) show_hud_for_id(id, "TOURNEY_RESET_YOUR_HINT");
            else show_hud_for_id(id, "TOURNEY_RESET_OTHER_HINT");
        }
        case S_PERIOD_RESET_A:
        {
            if (team == TEAM_A) show_hud_for_id(id, "PERIOD_RESET_YOUR_HINT");
            else show_hud_for_id(id, "PERIOD_RESET_OTHER_HINT");
        }
        case S_PERIOD_RESET_B:
        {
            if (team == TEAM_B) show_hud_for_id(id, "PERIOD_RESET_YOUR_HINT");
            else show_hud_for_id(id, "PERIOD_RESET_OTHER_HINT");
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
        if ((NEXT_STATES[i][Period] == P_ANY || NEXT_STATES[i][Period] == g_period) && NEXT_STATES[i][State] == g_state && NEXT_STATES[i][Event] == event)
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

    load_cvars();

    g_state = S_PROLOGUE;
    g_period = P_FIRST;

    g_forces[TEAM_A] = FORCE_T;
    g_forces[TEAM_B] = FORCE_CT;

    g_teams[FORCE_T] = TEAM_A;
    g_teams[FORCE_CT] = TEAM_B;

    g_timeouts[TEAM_A] = 0;
    g_timeouts[TEAM_B] = 0;

    g_scores[TEAM_A] = 0;
    g_scores[TEAM_B] = 0;

    for (new i = 0; i < P_COUNT; i++)
    {
        g_period_scores[i][TEAM_A] = 0;
        g_period_scores[i][TEAM_B] = 0;

        g_period_next[i] = 0;
    }

    return PLUGIN_CONTINUE;
}

public warm_up_cb()
{
    g_state = S_WARM_UP;

    execute("warmup.cfg");

    return PLUGIN_CONTINUE;
}

public load_cvars_cb()
{
    load_cvars();

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

public overtime_main_cb()
{
    show_chat("LIVE");
    show_chat("LIVE");
    show_chat("LIVE");

    g_state = S_MAIN;

    // In the overtime period, give everyone some extra overtime money!!!
    set_money(GET_CVAR_NUM(OVERTIME_MONEY));

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
    new win_goal = GET_CVAR_NUM(WIN_GOAL);
    new overtime_goal = GET_CVAR_NUM(OVERTIME_GOAL);

    g_scores[team]++;

    if (g_period == P_FIRST && (g_scores[TEAM_A] + g_scores[TEAM_B] >= win_goal - 1))
    {
        execute("warmup.cfg");

        show_chat("FIRST_FINISHED");

        g_period = P_SECOND;
        g_state = S_WARM_UP;

        period_stats_store(P_FIRST);

        // Swap teams ...
        swap_forces();

        g_forces[TEAM_A] = other_force(g_forces[TEAM_A]);
        g_forces[TEAM_B] = other_force(g_forces[TEAM_B]);

        g_teams[FORCE_T] = other_team(g_teams[FORCE_T]);
        g_teams[FORCE_CT] = other_team(g_teams[FORCE_CT]);

        return;
    }

    if (g_period == P_OVER_FIRST && (g_scores[TEAM_A] + g_scores[TEAM_B] >= win_goal - 1 + win_goal - 1 + overtime_goal - 1))
    {
        execute("warmup.cfg");

        show_chat("FIRST_FINISHED");

        g_period = P_OVER_SECOND;
        g_state = S_WARM_UP;

        period_stats_store(P_OVER_FIRST);

        // Swap teams ...
        swap_forces();

        g_forces[TEAM_A] = other_force(g_forces[TEAM_A]);
        g_forces[TEAM_B] = other_force(g_forces[TEAM_B]);

        g_teams[FORCE_T] = other_team(g_teams[FORCE_T]);
        g_teams[FORCE_CT] = other_team(g_teams[FORCE_CT]);

        return;
    }

    if (g_period == P_SECOND && (g_scores[TEAM_A] == win_goal - 1 && g_scores[TEAM_B] == win_goal - 1))
    {
        execute("warmup.cfg");

        show_chat("OVERTIME_STARTED");

        g_period = P_OVER_FIRST;
        g_state = S_WARM_UP;

        // Allow one extra timeout in overtime.
        if (g_timeouts[TEAM_A] > 0)
            g_timeouts[TEAM_A]--;

        if (g_timeouts[TEAM_B] > 0)
            g_timeouts[TEAM_B]--;

        period_stats_store(P_SECOND);

        // Swap teams ...
        swap_forces();

        g_forces[TEAM_A] = other_force(g_forces[TEAM_A]);
        g_forces[TEAM_B] = other_force(g_forces[TEAM_B]);

        g_teams[FORCE_T] = other_team(g_teams[FORCE_T]);
        g_teams[FORCE_CT] = other_team(g_teams[FORCE_CT]);

        return;
    }

    if (g_period == P_SECOND && (g_scores[TEAM_A] >= win_goal || g_scores[TEAM_B] >= win_goal))
    {
        execute("warmup.cfg");

        show_chat("MATCH_FINISHED");

        period_stats_store(P_SECOND);

        g_period = P_END;
        g_state = S_EPILOGUE;

        set_task(0.1, "post_result");

        return;
    }

    if (g_period == P_OVER_SECOND && (g_scores[TEAM_A] >= win_goal - 1 + overtime_goal || g_scores[TEAM_B] >= win_goal - 1 + overtime_goal))
    {
        execute("warmup.cfg");

        show_chat("MATCH_FINISHED");

        period_stats_store(P_OVER_SECOND);

        g_period = P_END;
        g_state = S_EPILOGUE;

        set_task(0.1, "post_result");

        return;
    }
}

stock period_stats_store(period)
{
    g_period_scores[period][TEAM_A] = g_scores[TEAM_A];
    g_period_scores[period][TEAM_B] = g_scores[TEAM_B];

    // Subtract scores from previous periods.
    for (new p = 0; p < period; p++)
    {
        g_period_scores[period][TEAM_A] -= g_period_scores[p][TEAM_A];
        g_period_scores[period][TEAM_B] -= g_period_scores[p][TEAM_B];
    }

    // Store each player's frags based on his/hers authid
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            period_stats_add(period, i);
        }
    }
}

stock period_stats_add(period, id)
{
    if (g_period_next[period] >= MAX_PLAYERS)
    {
        return;
    }

    new index = g_period_next[period];

    get_user_authid(id, g_period_authids[period][index], 63);
    // NOTE: Server restarts nullify frags and deaths ....
    g_period_frags[period][index] = get_user_frags(id);
    g_period_deaths[period][index] = get_user_deaths(id);

    g_period_next[period]++;
}

stock period_stats_frags(period, id)
{
    new authid[64];
    get_user_authid(id, authid, charsmax(authid));

    for (new i = 0; i < g_period_next[period]; i++)
    {
        if (equali(authid, g_period_authids[period][i]))
        {
            return g_period_frags[period][i];
        }
    }

    return 0;
}

stock period_stats_deaths(period, id)
{
    new authid[64];
    get_user_authid(id, authid, charsmax(authid));

    for (new i = 0; i < g_period_next[period]; i++)
    {
        if (equali(authid, g_period_authids[period][i]))
        {
            return g_period_deaths[period][i];
        }
    }

    return 0;
}

stock stats_frags(id)
{
    new frags = 0;
    for (new i = 0; i < P_COUNT; i++)
    {
        frags += period_stats_frags(i, id);
    }

    return frags;
}

stock stats_deaths(id)
{
    new deaths = 0;
    for (new i = 0; i < P_COUNT; i++)
    {
        deaths += period_stats_deaths(i, id);
    }

    return deaths;
}

stock is_substate_of_main(s)
{
    for (new i = 0; i < sizeof(MAIN_SUBSTATES); i++)
    {
        if (s == MAIN_SUBSTATES[i])
        {
            return true;
        }
    }

    return false;
}

public round_start_cb()
{
    // Matchpoints and last round are only shown in main phase. Check for it first.
    if (!is_substate_of_main(g_state))
        return PLUGIN_CONTINUE;

    new win_goal = GET_CVAR_NUM(WIN_GOAL);
    new overtime_goal = GET_CVAR_NUM(OVERTIME_GOAL);
    new warning_sound[64];

    if (g_period == P_FIRST && (g_scores[TEAM_A] + g_scores[TEAM_B] == win_goal - 2))
    {
        show_chat("LAST_ROUND");
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
        return PLUGIN_CONTINUE;
    }

    if (g_period == P_OVER_FIRST && (g_scores[TEAM_A] + g_scores[TEAM_B] == win_goal - 1 + win_goal - 1 + overtime_goal - 2))
    {
        show_chat("LAST_ROUND");
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
        return PLUGIN_CONTINUE;
    }

    if (g_period == P_OVER_SECOND && (g_scores[TEAM_A] == win_goal - 1 + overtime_goal - 1 && g_scores[TEAM_B] == win_goal - 1 + overtime_goal - 1))
    {
        // Both team on overtime match point! What a game!!!
        show_chat("MATCH_POINT_YOUR");
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
        return PLUGIN_CONTINUE;
    }

    if (g_period == P_SECOND && g_scores[TEAM_A] == win_goal - 1)
    {
        show_match_point(TEAM_A);
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
        return PLUGIN_CONTINUE;
    }

    if (g_period == P_SECOND && g_scores[TEAM_B] == win_goal - 1)
    {
        show_match_point(TEAM_B);
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
        return PLUGIN_CONTINUE;
    }

    if (g_period == P_OVER_SECOND && g_scores[TEAM_A] == win_goal - 1 + overtime_goal - 1)
    {
        show_match_point(TEAM_A);
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
        return PLUGIN_CONTINUE;
    }

    if (g_period == P_OVER_SECOND && g_scores[TEAM_B] == win_goal - 1 + overtime_goal - 1)
    {
        show_match_point(TEAM_B);
        GET_CVAR_STRING(WARNING_SOUND, warning_sound, charsmax(warning_sound));
        play_sound(warning_sound);
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
    if (g_timeouts[team] >= GET_CVAR_NUM(MAX_TIMEOUTS))
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

public tourney_reset_a_cb()
{
    tourney_reset(TEAM_A);

    return PLUGIN_CONTINUE;
}

public tourney_reset_b_cb()
{
    tourney_reset(TEAM_B);

    return PLUGIN_CONTINUE;
}

stock tourney_reset(team)
{
    // Remove auto-cancelation task. (Just for sure.)
    remove_task(TASK_CANCEL_ID);

    // Set up auto-cancelation of reset request.
    new params[3];
    params[0] = team;
    params[1] = EV_READY_A;
    params[2] = EV_READY_B;
    set_task(20.0, "ev_for_team", TASK_CANCEL_ID, params, sizeof(params));

    // Change state.
    g_state = (team == TEAM_A) ? S_TOURNEY_RESET_A : S_TOURNEY_RESET_B;
}

public tourney_reset_cb()
{
    // Remove auto-cancelation task.
    remove_task(TASK_CANCEL_ID);

    schedule_restart(5);

    show_chat("TOURNEY_RESET");

    next_state(EV_RESET);

    return PLUGIN_CONTINUE;
}

public tourney_unreset_cb()
{
    // Remove auto-cancelation task.
    remove_task(TASK_CANCEL_ID);

    g_state = S_MAIN;

    return PLUGIN_CONTINUE;
}

public period_reset_a_cb()
{
    period_reset(TEAM_A);

    return PLUGIN_CONTINUE;
}

public period_reset_b_cb()
{
    period_reset(TEAM_B);

    return PLUGIN_CONTINUE;
}

stock period_reset(team)
{
    // Remove auto-cancelation task. (Just for sure.)
    remove_task(TASK_CANCEL_ID);

    // Set up auto-cancelation of reset request.
    new params[3];
    params[0] = team;
    params[1] = EV_READY_A;
    params[2] = EV_READY_B;
    set_task(20.0, "ev_for_team", TASK_CANCEL_ID, params, sizeof(params));

    g_state = (team == TEAM_A) ? S_PERIOD_RESET_A : S_PERIOD_RESET_B;
}

public period_reset_cb()
{ 
    // Remove auto-cancelation task.
    remove_task(TASK_CANCEL_ID);

    // Revert team scores to the values before this period started.
    g_scores[TEAM_A] = 0;
    g_scores[TEAM_B] = 0;

    // Add scores from previous periods.
    for (new p = 0; p < g_period; p++)
    {
        g_scores[TEAM_A] += g_period_scores[p][TEAM_A];
        g_scores[TEAM_B] += g_period_scores[p][TEAM_B];
    }

    g_state = S_WARM_UP;

    execute("warmup.cfg");

    show_chat("PERIOD_RESET");

    schedule_restart(5);

    return PLUGIN_CONTINUE;
}

public period_unreset_cb()
{
    // Remove auto-cancelation task.
    remove_task(TASK_CANCEL_ID);

    g_state = S_MAIN;

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

    new params[3];
    params[0] = team;
    params[1] = ev_team_a;
    params[2] = ev_team_b;
    ev_for_team(params);
}

public ev_for_team(const params[3])
{
    new team = params[0];
    new ev_team_a = params[1];
    new ev_team_b = params[2];

    if (team == TEAM_UNKNOWN)
    {
        return PLUGIN_CONTINUE;
    }

    if (team == TEAM_A)
    {
        next_state(ev_team_a);
        return PLUGIN_CONTINUE;
    }
    else if (team == TEAM_B)
    {
        next_state(ev_team_b);
        return PLUGIN_CONTINUE;
    }

    return PLUGIN_CONTINUE;
}

public ev_reset_hud(id, level, cid)
{
    enforce_model(id);

    return PLUGIN_CONTINUE;
}

public ev_tourney_reset(id)
{
    ev_for_id(id, EV_TOURNEY_RESET_A, EV_TOURNEY_RESET_B);

    return PLUGIN_CONTINUE;
}

public ev_period_reset(id)
{
    ev_for_id(id, EV_PERIOD_RESET_A, EV_PERIOD_RESET_B);

    return PLUGIN_CONTINUE;
}

public ev_post_result(id)
{
    if (!(get_user_flags(id) & VIP_FLAG))
        return PLUGIN_CONTINUE;

    set_task(0.1, "post_result");

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
    new period[16];

    new win_goal = GET_CVAR_NUM(WIN_GOAL);
    new overtime_goal = GET_CVAR_NUM(OVERTIME_GOAL);

    // Determine right value of the game state indicator.
    if (g_period == P_END)
    {
        // Terminated.
        format(period, charsmax(period), "");
    }
    else if (g_period == P_FIRST || g_period == P_SECOND)
    {
        new bo = win_goal + win_goal - 1;
        if (!is_substate_of_main(g_state))
        {
            // Warm up.
            format(period, charsmax(period), "(Bo%d W%d)", bo, g_period + 1);
        }
        else
        {
            // Main.
            format(period, charsmax(period), "(Bo%d N%d)", bo, g_period + 1);
        }
    }
    else if (g_period == P_OVER_FIRST || g_period == P_OVER_SECOND)
    {
        new bo = win_goal + win_goal - 2 + overtime_goal + overtime_goal - 1;
        if (!is_substate_of_main(g_state))
        {
            // Overtime warm up.
            format(period, charsmax(period), "(Bo%d W%dx)", bo, g_period - P_OVER_FIRST + 1);
        }
        else
        {
            // Overtime main.
            format(period, charsmax(period), "(Bo%d N%dx)", bo, g_period - P_OVER_FIRST + 1);
        }
    }
    else
    {
        // Unknown state should never occur!
        format(period, charsmax(period), "(U)");
    }

    new team = user_team(id);
    if (team == TEAM_UNKNOWN)
    {
        format(hud, charsmax(hud), "%L", id, "SCORE", g_scores[g_teams[FORCE_T]], g_scores[g_teams[FORCE_CT]], period);
    }
    else if (g_scores[team] == g_scores[other_team(team)])
    {
        format(hud, charsmax(hud), "%L", id, "SCORE_TIE", g_scores[team], period);
    }
    else if (g_scores[team] > g_scores[other_team(team)])
    {
        format(hud, charsmax(hud), "%L", id, "SCORE_WIN", g_scores[team], g_scores[other_team(team)], period);
    }
    else
    {
        format(hud, charsmax(hud), "%L", id, "SCORE_LOSS", g_scores[team], g_scores[other_team(team)], period);
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
    new model[64];

    new force = user_force(id);
    if (force == FORCE_UNKNOWN)
    {
        return;
    }

    if (force == FORCE_T)
    {
        GET_CVAR_STRING(T_MODEL, model, charsmax(model));
        cs_set_user_model(id, model);
        return;
    }

    if (force == FORCE_CT)
    {
        GET_CVAR_STRING(CT_MODEL, model, charsmax(model));
        cs_set_user_model(id, model);
        return;
    }
}

stock set_money(amount)
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_valid_player(i))
        {
            cs_set_user_money(i, amount, 1);
        }
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

    new frags1 = stats_frags(player1);
    new frags2 = stats_frags(player2);
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
        new deaths1 = stats_deaths(player1);
        new deaths2 = stats_deaths(player2);
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
// Result server communication
public post_result()
{
    new map[32];
    new winners[2176];
    new losers[2176];
    new player[20];
    new authid[64];
    new winner;
    new loser;
    new first_winner;
    new first_loser;
    new players[MAX_PLAYERS];

    new server[64];
    new port;
    new uri[64];
    new tourney_name[64];
    new tourney_key[64];

    new error;
    new json[2560];
    new header[256];

    GET_CVAR_STRING(RESULT_SERVER, server, charsmax(server));
    GET_CVAR_STRING(RESULT_URI, uri, charsmax(uri));
    port = GET_CVAR_NUM(RESULT_SERVER_PORT);

    // Firstly, check whether it even makes sense to post results.
    if (strlen(server) <= 0)
        return PLUGIN_CONTINUE;

    if (strlen(uri) <= 0)
        return PLUGIN_CONTINUE;

    if (port <= 0)
        return PLUGIN_CONTINUE;

    // Determine winners and losers.
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

    // Map name.
    get_mapname(map, charsmax(map));

    // Sort players according to their score.
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        players[i] = i + 1;
    }
    SortCustom1D(players, MAX_PLAYERS, "player_compare");

    // Players for each team.
    first_winner = 1;
    first_loser = 1;
    for (new i = 0; i < MAX_PLAYERS; i++)
    {
        new id = players[i];
        if (is_valid_player(id))
        {
            // Each player is of length 134 (i.e., max total length is 134 * 16 = 2144).
            if (user_team(id) == winner)
            {
                // Deal with JSON comma.
                if (first_winner)
                {
                    first_winner = 0;
                }
                else
                {
                    format(winners, charsmax(winners), "%s,", winners);
                }

                // Get player's name, authid, and stats in the match.
                get_user_name(id, player, charsmax(player));
                get_user_authid(id, authid, charsmax(authid));
                format(winners, charsmax(winners), "%s{\"pid\":\"%s\",\"nickname\":\"%s\",\"frags\":%d,\"deaths\":%d}",
                    winners, authid, player, stats_frags(id), stats_deaths(id));
                continue;
            }

            if (user_team(id) == loser)
            {
                // Deal with JSON comma.
                if (first_loser)
                {
                    first_loser = 0;
                }
                else
                {
                    format(losers, charsmax(losers), "%s,", losers);
                }

                // Get player's name, authid, and stats in the match.
                get_user_name(id, player, charsmax(player));
                get_user_authid(id, authid, charsmax(authid));
                format(losers, charsmax(losers), "%s{\"pid\":\"%s\",\"nickname\":\"%s\",\"frags\":%d,\"deaths\":%d}",
                    losers, authid, player, stats_frags(id), stats_deaths(id));
                continue;
            }
        }
    }

    // Payload. Max length is given by a static part (map, score) 288 + a dynamic part (winners, losers) 2144 which is 2432 in total.
    if (g_period_scores[P_OVER_FIRST][winner] + g_period_scores[P_OVER_SECOND][winner] == 0)
    {
        // No overtime.
        formatex(json, charsmax(json),
            "{\"map\":\"%s\",\"score\":{\"winner\":{\"first\":%d,\"second\":%d,\"otFirst\":0,\"otSecond\":0},\"loser\":{\"first\":%d,\"second\":%d,\"otFirst\":0,\"otSecond\":0}},\"winners\":{\"items\":[%s]},\"losers\":{\"items\":[%s]}}",
            map,
            g_period_scores[P_FIRST][winner], g_period_scores[P_SECOND][winner],
            g_period_scores[P_FIRST][loser], g_period_scores[P_SECOND][loser],
            winners, losers);
    }
    else
    {
        // Game with overtime.
        formatex(json, charsmax(json),
            "{\"map\":\"%s\",\"score\":{\"winner\":{\"first\":%d,\"second\":%d,\"otFirst\":%d,\"otSecond\":%d},\"loser\":{\"first\":%d,\"second\":%d,\"otFirst\":%d,\"otSecond\":%d}},\"winners\":{\"items\":[%s]},\"losers\":{\"items\":[%s]}}",
            map,
            g_period_scores[P_FIRST][winner], g_period_scores[P_SECOND][winner],
            g_period_scores[P_OVER_FIRST][winner], g_period_scores[P_OVER_SECOND][winner],
            g_period_scores[P_FIRST][loser], g_period_scores[P_SECOND][loser],
            g_period_scores[P_OVER_FIRST][loser], g_period_scores[P_OVER_SECOND][loser],
            winners, losers);
    }

    // HTTP Header.
    GET_CVAR_STRING(TOURNEY_NAME, tourney_name, charsmax(tourney_name));
    GET_CVAR_STRING(TOURNEY_KEY, tourney_key, charsmax(tourney_key));
    if (strlen(tourney_name) > 0 && strlen(tourney_key) > 0)
    {
        // Send results with Authorization header.
        formatex(header, charsmax(header),
            "POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nAuthorization: Basic %s:%s\r\nContent-Length: %d\r\n\r\n",
            uri, server, tourney_name, tourney_key, strlen(json));
    }
    else
    {
        // No Authorization header.
        formatex(header, charsmax(header),
            "POST %s HTTP/1.0\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n",
            uri, server, strlen(json));
    }

    DPRINT(header);
    DPRINT(json);

    if (g_socket > 0)
    {
        ERROR("Socket is open, closing it ...");
        socket_close(g_socket);
        g_socket = 0;
    }

    // Send the request (using HTTP POST method).
    g_socket = socket_open(server, port, SOCKET_TCP, error);
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

    // Finally, send the request!
    socket_send(g_socket, header, strlen(header));
    socket_send(g_socket, json, strlen(json));

    set_task(1.0, "read_response");

    return PLUGIN_CONTINUE;
}

public read_response()
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

    // Get the data.
    socket_recv(g_socket, response, charsmax(response));
    DPRINT(response);

    // Close the socket.
    socket_close(g_socket);
    g_socket = 0;

    return PLUGIN_CONTINUE;
}
