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
// This plugin adds an ability to almost instantly explode C4 while a user
// holds it in hands. The detonation causes blast damage. If at least one CT
// survives, the CT team wins. Otherwise, it is a draw.
//

#pragma semicolon 1
#pragma ctrlchar '\'

//////////////////////////////////////////////////////////////////////////////
// Includes
#include <amxmodx>
#include <fakemeta>
#include <fakemeta_util>
#include <hamsandwich>
#include <fun>
#include <engine>
#include <cstrike>

//////////////////////////////////////////////////////////////////////////////
// Macros
#define MAX_PLAYERS             32
#define PLANT_TIME              3
#define USAGE_DELAY             45
#define USAGE_PLAYER_LIMIT      1
#define BLAST_DAMAGE            500.0
#define BLAST_RADIUS            875.0
#define SPEED_REDUCTION         1.5
#define ANIMATION_PLANT         3
#define ANIMATION_IDLE          0
#define TEAM_T                  1
#define DEFEAT_DELAY            3
#define DEFEAT_TASK_ID          105
#define HINT_DELAY              3

#define CSW_BEGIN               CSW_P228
#define CSW_END                 (CSW_P90+1)

//////////////////////////////////////////////////////////////////////////////
// Constants
stock const WEAPON_NAMES[][] =
{
    "",
    "weapon_p228",
    "",
    "weapon_scout",
    "weapon_hegrenade",
    "weapon_xm1014",
    "",
    "weapon_mac10",
    "weapon_aug",
    "weapon_smokegrenade",
    "weapon_elite",
    "weapon_fiveseven",
    "weapon_ump45",
    "weapon_sg550",
    "weapon_galil",
    "weapon_famas",
    "weapon_usp",
    "weapon_glock18",
    "weapon_awp",
    "weapon_mp5navy",
    "weapon_m249",
    "weapon_m3",
    "weapon_m4a1",
    "weapon_tmp",
    "weapon_g3sg1",
    "weapon_flashbang",
    "weapon_deagle",
    "weapon_sg552",
    "weapon_ak47",
    "",
    "weapon_p90"
};

//////////////////////////////////////////////////////////////////////////////
// Global State

// HUD and world related
new g_bar_time_msg;
new g_explosion_sprite;

// Hook for detection of holding C4 in hands
new HamHook:g_item_deploy_hook;
new HamHook:g_item_holster_hook;
new HamHook:g_c4_idle_hook;

// Detonation
new g_planting;
new Float:g_plant_start;
new Float:g_max_speed;
new Float:g_round_start;
new g_usage_hint;
new g_count;
new g_counted_team;

// Store and load of terrorist weapons
new g_weapon_store[MAX_PLAYERS];
new g_weapon[MAX_PLAYERS][CSW_END];
new g_weapon_ammo_wpn[MAX_PLAYERS][CSW_END];
new g_weapon_ammo_bp[MAX_PLAYERS][CSW_END];
new g_armor[MAX_PLAYERS];
new CsArmorType:g_armor_type[MAX_PLAYERS];

//////////////////////////////////////////////////////////////////////////////
// Plugin Commons
public plugin_init()
{
    register_plugin("Lambda Decay C4 Instant Blast", "1.0.2", "MrL0ck");
    register_dictionary("ldinstantc4.txt");

    // Messages
    g_bar_time_msg = get_user_msgid("BarTime");

    // Event hooks
    register_event("HLTV", "ev_round_start", "a", "1=0", "2=0");
    g_item_deploy_hook  = RegisterHam(Ham_Item_Deploy,
        "weapon_c4", "ev_item_deploy_pre", false);
    g_item_holster_hook = RegisterHam(Ham_Item_Holster,
        "weapon_c4", "ev_item_holster_pre", false);
    g_c4_idle_hook      = RegisterHam(Ham_Weapon_WeaponIdle,
        "weapon_c4", "ev_c4_idle_post", true);
    RegisterHam(Ham_Spawn, "player", "ev_player_spawn_post", true);

    // Default values
    g_planting          = false;
    g_plant_start       = 0.0;
    g_usage_hint        = false;
    g_count             = -1;
    arrayset(g_weapon_store, 0, MAX_PLAYERS);
    DisableHamForward(g_c4_idle_hook);
}

public plugin_precache()
{
    g_explosion_sprite = precache_model("sprites/eexplo.spr");
}

public plugin_pause()
{
    DisableHamForward(g_c4_idle_hook);
    DisableHamForward(g_item_deploy_hook);
    DisableHamForward(g_item_holster_hook);
}

public plugin_unpause()
{
    EnableHamForward(g_c4_idle_hook);
    EnableHamForward(g_item_deploy_hook);
    EnableHamForward(g_item_holster_hook);
}

//////////////////////////////////////////////////////////////////////////////
// Events
public ev_item_deploy_pre(ent)
{
    EnableHamForward(g_c4_idle_hook);
}

public ev_item_holster_pre(ent)
{
    DisableHamForward(g_c4_idle_hook);
    stop_plant_for_entity(ent);
}

public ev_c4_idle_post(ent)
{
    new buttons;
    new id;
    new Float:blast_origin[3];
    new Float:delay;

    id = pev(ent, pev_owner);
    if (!is_user_alive(id))
    {
        return stop_plant_for_player(id);
    }

    buttons = pev(id, pev_button);
    if (!(buttons & IN_ATTACK2))
    {
        return stop_plant_for_player(id);
    }

    // Detonation may occur only after some delay
    delay = g_round_start + float(USAGE_DELAY) - get_gametime();
    if (delay > 0.0)
    {
        new hint = show_usage_delay_hint(id, delay);
        new stop = stop_plant_for_player(id);

        return hint || stop;
    }

    // Limit no. of players when one can detonate the bomb
    if (player_count_with_memo(get_user_team(id)) > USAGE_PLAYER_LIMIT)
    {
        new hint = show_usage_player_limit_hint(id);
        new stop = stop_plant_for_player(id);

        return hint || stop;
    }

    if (!g_planting)
    {
        g_planting = true;
        g_plant_start = get_gametime();

        pev(id, pev_maxspeed, g_max_speed);
        fm_set_user_maxspeed(id, g_max_speed / SPEED_REDUCTION);

        bar_time(id, PLANT_TIME);
        set_animation(id, ANIMATION_PLANT);

        return HAM_HANDLED;
    }

    if (g_plant_start + float(PLANT_TIME) > get_gametime())
    {
        return HAM_IGNORED;
    }

    stop_plant_for_player(id);
    strip_user_weapons(id);
    user_silentkill(id);

    pev(id, pev_origin, blast_origin);
    for (new i = 0; i < 3; i++)
    {
        // Add a little displace so the blast is not so symmetric
        blast_origin[i] += 5.0;
    }

    // Finally, just explode!!!
    make_blast(id, blast_origin);

    set_task(float(DEFEAT_DELAY), "terrorist_defeat", DEFEAT_TASK_ID);

    return HAM_HANDLED;
}

public ev_round_start()
{
    remove_task(DEFEAT_TASK_ID);
    g_round_start = get_gametime();

    return PLUGIN_CONTINUE;
}

public ev_player_spawn_post(id)
{
    restore_weapons(id);

    return PLUGIN_CONTINUE;
}

//////////////////////////////////////////////////////////////////////////////
// Utilities
stock make_blast(inflictor, Float:origin[3])
{
    new player[32];

    blast(inflictor, origin, BLAST_DAMAGE, BLAST_RADIUS);
    get_user_name(inflictor, player, charsmax(player));
    client_print(0, print_center, "%L", inflictor, "USED", player);
}

stock show_usage_delay_hint(id, Float:delay)
{
    if (g_usage_hint)
    {
        return HAM_IGNORED;
    }

    g_usage_hint = true;
    client_print(id, print_center, "%L", id, "USAGE_DELAY_HINT", floatround(delay));
    set_task(float(HINT_DELAY), "reset_usage_hint");

    return HAM_HANDLED;
}

stock show_usage_player_limit_hint(id)
{
    if (g_usage_hint)
    {
        return HAM_IGNORED;
    }

    g_usage_hint = true;
    client_print(id, print_center, "%L", id, "USAGE_PLAYER_LIMIT_HINT", USAGE_PLAYER_LIMIT);
    set_task(float(HINT_DELAY), "reset_usage_hint");

    return HAM_HANDLED;
}

public reset_usage_hint()
{
    g_usage_hint = false;

    return PLUGIN_CONTINUE;
}

stock stop_plant_for_entity(ent)
{
    new id;

    id = pev(ent, pev_owner);
    if (!is_user_alive(id))
    {
        return HAM_IGNORED;
    }

    return stop_plant_for_player(id);
}

stock stop_plant_for_player(id)
{
    if (!g_planting)
    {
        return HAM_IGNORED;
    }

    g_planting = false;
    g_plant_start = 0.0;
    bar_time(id, 0);
    set_animation(id, ANIMATION_IDLE);
    fm_set_user_maxspeed(id, g_max_speed);

    return HAM_HANDLED;
}

stock set_animation(id, anim)
{
    set_pev(id, pev_weaponanim, anim);
    message_begin(MSG_ONE, SVC_WEAPONANIM, {0, 0, 0}, id);
    write_byte(anim);
    write_byte(pev(id, pev_body));
    message_end();
}

stock bar_time(id, scale)
{
    message_begin(MSG_ONE, g_bar_time_msg, _, id);
    write_short(scale);
    message_end();
}

stock blast(inflictor, Float:origin[3], Float:damage, Float:range)
{
    new Float:position[3];
    new Float:distance;
    new Float:pain;

    message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
    write_byte(TE_EXPLOSION);
    write_coord(floatround(origin[0]));
    write_coord(floatround(origin[1]));
    write_coord(floatround(origin[2]));
    write_short(g_explosion_sprite);
    write_byte(80);
    write_byte(15);
    write_byte(0);
    message_end();

    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (!is_user_alive(i))
        {
            continue;
        }

        pev(i, pev_origin, position);
        distance = vector_distance(origin, position);

        if (distance > range)
        {
            continue;
        }

        pain = damage - ((damage / range) * distance);
        ExecuteHamB(Ham_TakeDamage, i, any:inflictor,
            any:inflictor, any:pain, any:DMG_BLAST);
    }
}

public terrorist_defeat()
{
    make_team_defeat(TEAM_T);

    return PLUGIN_CONTINUE;
}

public restore_terrorist_weapons()
{
    restore_team_weapons(TEAM_T);

    return PLUGIN_CONTINUE;
}

stock make_team_defeat(team)
{
    save_team_weapons(team);

    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (!is_user_alive(i) || get_user_team(i) != team)
        {
            continue;
        }

        // This should force round to end ...
        strip_user_weapons(i);
        user_silentkill(i);
        cs_set_user_deaths(i, get_user_deaths(i) - 1);
    }
}

stock save_team_weapons(team)
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (get_user_team(i) != team)
        {
            continue;
        }

        save_weapons(i);
    }
}

stock restore_team_weapons(team)
{
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (get_user_team(i) != team)
        {
            continue;
        }

        restore_weapons(i);
    }
}

stock save_weapons(id)
{
    new i = id - 1;

    arrayset(g_weapon[i], 0, CSW_END);
    if (!is_user_alive(id))
    {
        g_weapon_store[i] = false;
        return;
    }

    g_weapon_store[i] = true;
    g_armor[i] = cs_get_user_armor(id, g_armor_type[i]);
    for (new j = CSW_BEGIN; j != CSW_END; j++)
    {
        if (WEAPON_NAMES[j][0] == '\0')
        {
            // Do not save these weapons!
            continue;
        }

        if (!user_has_weapon(id, j))
        {
            continue;
        }

        new ent = find_ent_by_owner(-1, WEAPON_NAMES[j], id);
        g_weapon[i][j]          = true;
        g_weapon_ammo_wpn[i][j] = cs_get_weapon_ammo(ent);
        g_weapon_ammo_bp[i][j]  = cs_get_user_bpammo(id, j);
    }
}

stock restore_weapons(id)
{
    new i = id - 1;

    if (!g_weapon_store[i])
    {
        return;
    }

    g_weapon_store[i] = false;
    if (!is_user_alive(id))
    {
        return;
    }

    cs_set_user_armor(id, g_armor[i], g_armor_type[i]);
    for (new j = CSW_BEGIN; j != CSW_END; j++)
    {
        if (WEAPON_NAMES[j][0] == '\0')
        {
            // Do not restore these weapons!
            continue;
        }

        fm_strip_user_gun(id, j);
        if (!g_weapon[i][j])
        {
            continue;
        }

        new ent = give_item(id, WEAPON_NAMES[j]);
        cs_set_weapon_ammo(ent, g_weapon_ammo_wpn[i][j]);
        cs_set_user_bpammo(id, j, g_weapon_ammo_bp[i][j]);
    }
}

stock player_count_with_memo(team)
{
    // Use memoized value if available
    if (g_count >= 0 && g_counted_team == team)
    {
        return g_count;
    }

    g_counted_team = team;
    g_count = 0;
    for (new i = 1; i <= MAX_PLAYERS; i++)
    {
        if (is_user_alive(i) && get_user_team(i) == team)
        {
            g_count++;
        }
    }

    // Reset memo value after 1 sec.
    set_task(1.0, "reset_player_count_memo");

    return g_count;
}

public reset_player_count_memo()
{
    g_count = -1;
}

