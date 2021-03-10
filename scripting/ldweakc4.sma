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
// This plugin reduces a blast radius of C4 explosion.
//

#pragma semicolon 1
#pragma ctrlchar '\'

//////////////////////////////////////////////////////////////////////////////
// Includes
#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>

//////////////////////////////////////////////////////////////////////////////
// Macros
#define DEFAULT_BLAST_RADIUS    1700.0
#define NEW_BLAST_RADIUS        750.0
#define C4_NAME                 "weapon_c4"
#define GET_ENTITY(%1)          engfunc(EngFunc_FindEntityByString, -1, \
                                "classname", %1)

//////////////////////////////////////////////////////////////////////////////
// Global State
new g_planted_c4_ent;
new Float:g_planted_c4_origin[3];

//////////////////////////////////////////////////////////////////////////////
// Plugin Commons
public plugin_init()
{
    register_plugin("Lambda Decay Weak C4", "1.0.1", "MrL0ck");

    // Event hooks
    register_logevent("ev_bomb_planted", 3 ,"2=Planted_The_Bomb");
    register_event("HLTV", "ev_round_start", "a", "1=0", "2=0");
    RegisterHam(Ham_TakeDamage, "player", "ev_take_damage");
}

//////////////////////////////////////////////////////////////////////////////
// Events
public ev_bomb_planted()
{
    g_planted_c4_ent = GET_ENTITY(C4_NAME);
    pev(g_planted_c4_ent, pev_origin, g_planted_c4_origin);

    return PLUGIN_CONTINUE;
}

public ev_round_start()
{
    g_planted_c4_ent = 0;

    return PLUGIN_CONTINUE;
}

public ev_take_damage(victim, inflictor, attacker, damage, flags)
{
    new c4_ent;
    new inflictor_class[32];
    new Float:victim_origin[3];

    if (!inflictor)
    {
        // No cause of damage.
        return HAM_IGNORED;
    }

    if (!(flags & DMG_BLAST))
    {
        // C4 always causes blast damage.
        return HAM_IGNORED;
    }

    if (!g_planted_c4_ent)
    {
        // C4 was not planted in this round.
        return HAM_IGNORED;
    }

    c4_ent = GET_ENTITY(C4_NAME);
    if (c4_ent)
    {
        // C4 still exists in the world.
        return HAM_IGNORED;
    }

    pev(inflictor, pev_classname, inflictor_class, charsmax(inflictor_class));
    if (!equal(inflictor_class, "env_explosion") &&
        !equal(inflictor_class, "grenade"))
    {
        // C4 causes only explosion or grenade-class damage.
        return HAM_IGNORED;
    }

    pev(victim, pev_origin, victim_origin);
    new Float:distance = get_distance_f(victim_origin, g_planted_c4_origin);
    if (distance > DEFAULT_BLAST_RADIUS)
    {
        // Victim is outside the default C4 damage radius.
        return HAM_IGNORED;
    }

    if (distance < NEW_BLAST_RADIUS)
    {
        // Victim is inside the new C4 damage radius, thus do not reduce damage.
        return HAM_IGNORED;
    }

    // All conditions apply. We are in the circle given by the default radius but
    // not inside the new one. Therefore, we ignore any damage!
    return HAM_SUPERCEDE;
}

