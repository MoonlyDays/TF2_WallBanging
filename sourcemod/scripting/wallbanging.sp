#pragma semicolon 1

#define DEBUG

#define PLUGIN_AUTHOR "Moonly Days"
#define PLUGIN_VERSION "1.00"

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <tf2>
#include <tf2_stocks>
#include <dhooks>

Handle gHook_CTFWeaponBaseGun_FireBullet;
Handle gHook_CBaseEntity_FireBullets;

Handle gCall_CTFWeaponBaseGun_GetProjectileWeapon;
Handle gCall_CTFWeaponBaseGun_GetWeaponSpread;
Handle gCall_CTFWeaponBase_GetCustomDamageType;
Handle gCall_CTFWeaponBase_GetWeaponID;

int g_iPredictionSeed[MAXPLAYERS + 1];
bool g_bCurrentAttackIsCrit[MAXPLAYERS + 1];
float g_flAccumDisplayDamage[MAXPLAYERS + 1];

float g_vecFixedWpnSpreadPellets[][] = 
{
	{ 0.0, 0.0 },
	{ 1.0, 0.0 },
	{ -1.0, 0.0 },
	{ 0.0, -1.0 },
	{ 0.0, 1.0 },
	{ 0.85, -0.85 },
	{ 0.85, 0.85 },
	{ -0.85, -0.85 },
	{ -0.85, 0.85 },
	{ 0.0, 0.0 }
};

char g_szWallBangableWeapons[][] = {
	"tf_weapon_scattergun",
	"tf_weapon_handgun_scout_primary",
	"tf_weapon_soda_popper",
	"tf_weapon_pep_brawler_blaster",
	
	"tf_weapon_pistol",
	"tf_weapon_pistol_primary",
	"tf_weapon_pistol_scout",
	
	"tf_weapon_shotgun",
	"tf_weapon_shotgun_soldier",
	"tf_weapon_shotgun_pyro",
	"tf_weapon_shotgun_hwg",
	"tf_weapon_shotgun_primary",
	"tf_weapon_sentry_revenge",
	
	"tf_weapon_minigun",
	
	"tf_weapon_sniperrifle",
	"tf_weapon_sniperrifle_classic",
	
	"tf_weapon_smg",
	"tf_weapon_charged_smg",
	
	"tf_weapon_revolver"
};

char g_szHittableEntities[][] = {
	"player",
	
	"obj_sentrygun",
	"obj_dispenser",
	"obj_teleporter",
};

ConVar sm_penetration_falloff;
ConVar sm_penetration_projectiles;
ConVar sm_penetration_max_distance;
ConVar sm_penetration_step;

public Plugin myinfo = 
{
	name = "Wallbanging",
	author = PLUGIN_AUTHOR,
	description = "I don't even know...",
	version = PLUGIN_VERSION,
	url = "https://github.com/MoonlyDays"
};

public void OnPluginStart()
{
	Handle hGameData = LoadGameConfigFile("tf2.wallbanging");
	if(hGameData == INVALID_HANDLE)
	{
		SetFailState("Gamedata not found");
	}
	
	//
	// DHooks
	//
	
	int offset = GameConfGetOffset(hGameData, "CTFWeaponBaseGun::FireBullet");
	gHook_CTFWeaponBaseGun_FireBullet = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, CTFWeaponBaseGun_FireBullet);
	DHookAddParam(gHook_CTFWeaponBaseGun_FireBullet, HookParamType_CBaseEntity);
	
	offset = GameConfGetOffset(hGameData, "CBaseEntity::FireBullets");
	gHook_CBaseEntity_FireBullets = DHookCreate(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity, CBaseEntity_FireBullets);
	DHookAddParam(gHook_CBaseEntity_FireBullets, HookParamType_ObjectPtr);
	
	//
	// SDK Calls
	//
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTFWeaponBaseGun::GetProjectileDamage");
	PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
	gCall_CTFWeaponBaseGun_GetProjectileWeapon = EndPrepSDKCall();
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTFWeaponBaseGun::GetWeaponSpread");
	PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
	gCall_CTFWeaponBaseGun_GetWeaponSpread = EndPrepSDKCall();
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTFWeaponBase::GetCustomDamageType");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	gCall_CTFWeaponBase_GetCustomDamageType = EndPrepSDKCall();
	
	StartPrepSDKCall(SDKCall_Entity);
	PrepSDKCall_SetFromConf(hGameData, SDKConf_Virtual, "CTFWeaponBase::GetWeaponID");
	PrepSDKCall_SetReturnInfo(SDKType_PlainOldData, SDKPass_Plain);
	gCall_CTFWeaponBase_GetWeaponID = EndPrepSDKCall();
	
	HookAllPlayers();
	
	sm_penetration_falloff = CreateConVar("sm_penetration_falloff", "16", "Units per one damage unit falloff");
	sm_penetration_projectiles = CreateConVar("sm_penetration_projectiles", "0");
	sm_penetration_max_distance = CreateConVar("sm_penetration_max_distance", "90");
	sm_penetration_step = CreateConVar("sm_penetration_step", "4");
}

public void OnClientPutInServer(int client)
{
	HookPlayer(client);
}

public bool IsWallBangableClassname(const char[] weapon)
{
	for (int i = 0; i < sizeof(g_szWallBangableWeapons); i++)
	{
		if(StrEqual(weapon, g_szWallBangableWeapons[i]))
			return true;
	}
	
	return false;
}

public bool IsHittableClassname(const char[] entity)
{
	for (int i = 0; i < sizeof(g_szHittableEntities); i++)
	{
		if(StrEqual(entity, g_szHittableEntities[i]))
			return true;
	}
	
	return false;
}

public void HandleWeaponWallBanging(int client, int weapon)
{
	if (!IsValidEntity(client))
		return;
		
	if (!IsValidEntity(weapon))
		return;
		
	float vecPos[3], angAng[3];
	GetClientShootPosition(client, vecPos);
	GetClientShootAngle(client, angAng);
	g_flAccumDisplayDamage[client] = 0.0;
	
	float vecForward[3];
	float vecRight[3];
	float vecUp[3];
	GetAngleVectors(angAng, vecForward, vecRight, vecUp);
	
	//
	// TODO:
	// START LAG COMPENSATION
	//
	
	int nBulletsPerShot = GetBulletCount(weapon);
	float baseDamage = GetBaseWeaponDamage(weapon);
	float baseSpread = GetWeaponSpread(weapon);
	bool useFixedSpread = WeaponUsesFixedSpreadPattern(weapon);
	SetRandomSeed(g_iPredictionSeed[client] & 255);
	
	for (int i = 0; i < nBulletsPerShot; i++)
	{
		float x = 0.0;
		float y = 0.0;
		float vecDir[3];
		
		
		// Get circular gaussian spread. Under some cases we fire a bullet right down the crosshair:
		//	- The first bullet of a spread weapon (except for rapid fire spread weapons like the minigun)
		//	- The first bullet of a non-spread weapon if it's been >1.25 second since firing
		bool bFirePerfect = false;
		if (i == 0)
		{
			float curTime = GetGameTime();
			float lastFireTime = GetEntPropFloat(weapon, Prop_Send, "m_flLastFireTime");
			float timeSinceLastShot = curTime - lastFireTime;
			
			if ( nBulletsPerShot > 1 && timeSinceLastShot > 0.25 )
			{
				bFirePerfect = true;
			}
			else if ( nBulletsPerShot == 1 && timeSinceLastShot > 1.25 )
			{
				bFirePerfect = true;
			}
		}
		
		if (useFixedSpread)
		{
			int spread = i;
			while (spread >= sizeof(g_vecFixedWpnSpreadPellets))
			{
				spread -= sizeof(g_vecFixedWpnSpreadPellets);
			}
			
			float scalar = 0.5;
			x = g_vecFixedWpnSpreadPellets[spread][0] * scalar;
			y = g_vecFixedWpnSpreadPellets[spread][1] * scalar;
		} 
		else if(bFirePerfect)
		{
			x = y = 0.0;
		}
		else 
		{
			x = GetRandomFloat(-0.5, 0.5) + GetRandomFloat(-0.5, 0.5);
			y = GetRandomFloat(-0.5, 0.5) + GetRandomFloat(-0.5, 0.5);
		}
		
		for (int j = 0; j < 3; j++)
		{
			vecDir[j] = vecForward[j] + (x * baseSpread * vecRight[j]) + (y * baseSpread * vecUp[j]);
		}
		
		NormalizeVector(vecDir, vecDir);
		FireBullet(client, weapon, baseDamage, vecPos, vecDir);
	}
	
	//
	// TODO:
	// END LAG COMPENSATION
	//
}

public Action TF2_CalcIsAttackCritical(int client, int weapon, char[] weaponname, bool &result)
{
	g_bCurrentAttackIsCrit[client] = result;
	return Plugin_Continue;
}

public void FireBullet(int client, int weapon, float damage, float vecPos[3], float vecDir[3])
{
	const float flRange = 4096.0;
	bool hitEntities[2049];
	
	float vecEnd[3];
	for (int i = 0; i < 3; i++)
	{
		vecEnd[i] = vecPos[i] + vecDir[i] * flRange;
	}
	
	int penetrationCount = 0;
	
	float vecTraceStart[3];
	vecTraceStart = vecPos;
	
	int attempts = 0;
	
	float currentDamage = damage;
	while (currentDamage > 0)
	{
		attempts++;
		if (attempts > 50)
			break;
		
		Handle trace = TR_TraceRayFilterEx(vecTraceStart, vecEnd, MASK_SOLID | CONTENTS_HITBOX, RayType_EndPoint, TraceFilter_Bullet, client);
		
		// Trace never hit anything.
		if (!TR_DidHit(trace))
		{
			CloseHandle(trace);
			continue;
		}
			
		int hitEntity = TR_GetEntityIndex(trace);
		if (hitEntity > 0 && !hitEntities[hitEntity])
		{
			float vecForce[3];
			hitEntities[hitEntity] = true;
			
			char classname[32];
			GetEntityClassname(hitEntity, classname, sizeof(classname));
			
			if (penetrationCount > 0 && IsHittableClassname(classname))
			{
				HitEntity(client, weapon, hitEntity, currentDamage, penetrationCount, TR_GetHitBoxIndex(trace), vecForce, vecPos);
			}
		}
			
		float vecHit[3];
		TR_GetEndPosition(vecHit, trace);
		
		float penetrationDistance = 0.0;
		
		// Couldn't exit.
		if (!TraceToExit(vecHit, vecDir, vecTraceStart, penetrationDistance, sm_penetration_step.FloatValue, sm_penetration_max_distance.FloatValue))
		{
			CloseHandle(trace);
			break;
		}
		
		// PrintToChatAll("Penetration %d: %.2f", penetrationCount, penetrationDistance);
		
		currentDamage -= penetrationDistance / sm_penetration_falloff.FloatValue;
		penetrationCount++;
	}
}

public bool IsClient(int entity)
{
	if(entity <= 0)
		return false;
		
	if (entity > MaxClients)
		return false;
		
	if (!IsClientInGame(entity))
		return false;
		
	return true;
}

public bool TraceToExit(const float start[3], const float dir[3], float end[3], float &penetrateDistance, float stepsize, float maxDistance)
{
	int nStartContents = 0;
	
	// Step until we reach max distance amount.
	while (penetrateDistance < maxDistance)
	{
		// Increase our penetrated distance by step. 
		penetrateDistance += stepsize;
		
		float vecTrEnd[3];
		for (int i = 0; i < 3; i++)
		{
			end[i] = start[i] + dir[i] * penetrateDistance;
			vecTrEnd[i] = end[i] - (stepsize * dir[i]);
		}
			
		if ( nStartContents == 0 )
			nStartContents = TR_GetPointContents(end);
		
		int nCurrentContents = TR_GetPointContents(end);
		if ((nCurrentContents & MASK_SOLID) == 0 || ((nCurrentContents & CONTENTS_HITBOX) && nStartContents != nCurrentContents))
		{
			return true;
		}
	}
	
	return false;
}

public void HitEntity(int client, int weapon, int hitEntity, float damage, int penetrationCount, int hitboxIndex, float vecPosition[3], float vecForce[3])
{
	if (!HasEntProp(hitEntity, Prop_Send, "m_iTeamNum"))
		return;
		
	int iOurTeam = GetEntProp(client, Prop_Send, "m_iTeamNum");
	int iTheirTeam = GetEntProp(hitEntity, Prop_Send, "m_iTeamNum");
	
	if (iOurTeam == iTheirTeam)
		return;
	
	int flags = DMG_BULLET;
	
	if (g_bCurrentAttackIsCrit[client])
		flags |= DMG_CRIT;
		
	
	int customDamage = GetCustomDamageType(weapon);
	
	// 
	// Falloff
	//
	
	if (IsClient(hitEntity))
	{
		float vecAttackerPos[3];
		float vecEntityPos[3];
		GetClientAbsOrigin(hitEntity, vecEntityPos);
		GetClientAbsOrigin(client, vecAttackerPos);
		
		float dist = GetVectorDistance(vecAttackerPos, vecEntityPos);
		if (dist > 512)
		{
			if (dist > 1024)
				dist = 1024.0;
				
			float fraction = dist / 1024;
			damage *= 0.5 + (1 - fraction);
		}
		
		if (customDamage == TF_CUSTOM_PENETRATE_MY_TEAM)
		{
			if (hitboxIndex == 0)
				flags |= DMG_CRIT;
		}
		
	}
	
	SDKHooks_TakeDamage(hitEntity, weapon, client, damage, flags, weapon, vecForce, vecPosition);
	
	float displayDamage = damage;
	
	if ((flags & DMG_CRIT) > 0)
		displayDamage *= 3;
	
	g_flAccumDisplayDamage[client] += displayDamage;
	PrintCenterText(client, "-%d HP", RoundToNearest(g_flAccumDisplayDamage[client]));
}

public bool TraceFilter_Bullet(int entity, int mask, any data)
{
	return entity != data;
} 

public void RF_WeaponCreated(int weapon)
{
	if (!IsValidEdict(weapon))
		return;

	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	
	if (!IsWallBangableClassname(classname))
		return;
	
	if (!HasEntProp(weapon, Prop_Send, "m_hOwnerEntity"))
		return;
	
	int owner = GetEntPropEnt(weapon, Prop_Send, "m_hOwnerEntity");
	if (!IsValidEdict(owner))
		return;
		
	if (IsFakeClient(owner))
		return;
	
	HookWeapon(weapon);
}

public void RF_SentryGunCreated(int sentrygun)
{
	if (!IsValidEdict(sentrygun))
		return;
		
	if (!HasEntProp(sentrygun, Prop_Send, "m_bPlayerControlled"))
		return;
		
	HookSentry(sentrygun);
	// PrintToChatAll("Hooked Sentry: %d", sentrygun);
}

public void HookWeapon(int weapon) 
{
	DHookEntity(gHook_CTFWeaponBaseGun_FireBullet, true, weapon);
}

public void HookSentry(int sentry) 
{
	DHookEntity(gHook_CBaseEntity_FireBullets, true, sentry);
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrContains(classname, "tf_weapon_") != -1)
	{
		RequestFrame(RF_WeaponCreated, entity);
	}
	
	if (StrContains(classname, "obj_sentrygun") != -1)
	{
		RequestFrame(RF_SentryGunCreated, entity);
	}
}

public void GetClientShootPosition(int client, float pos[3])
{
	GetClientEyePosition(client, pos);
}

public void GetClientShootAngle(int client, float angle[3])
{
	float angEyes[3], angPunch[3];
	GetClientEyeAngles(client, angEyes);
	GetEntPropVector(client, Prop_Send, "m_vecPunchAngle", angPunch);
	
	for (int i = 0; i < 3; i++)
	{
		angle[i] = angEyes[i];
		angle[i] += angPunch[i];
	}
}

public void Debug_SpawnParticle(float vecPos[3])
{
    int particle = CreateEntityByName("info_particle_system");

    if (IsValidEdict(particle))
    {
		TeleportEntity(particle, vecPos, NULL_VECTOR, NULL_VECTOR);
		DispatchKeyValue(particle, "effect_name", "halloween_rockettrail");
		DispatchSpawn(particle);
		ActivateEntity(particle);
		AcceptEntityInput(particle, "start");
		
		char addoutput[64];
		Format(addoutput, sizeof(addoutput), "OnUser1 !self:kill::%i:1", 2);
		SetVariantString(addoutput);
		        
		AcceptEntityInput(particle, "AddOutput");
		AcceptEntityInput(particle, "FireUser1"); 
    }
}

public float GetBaseWeaponDamage(int weapon)
{
	return SDKCall(gCall_CTFWeaponBaseGun_GetProjectileWeapon, weapon);
}

public float GetWeaponSpread(int weapon)
{
	return SDKCall(gCall_CTFWeaponBaseGun_GetWeaponSpread, weapon);
}

public int GetCustomDamageType(int weapon)
{
	return SDKCall(gCall_CTFWeaponBase_GetCustomDamageType, weapon);
}

public int GetWeaponID(int weapon)
{
	return SDKCall(gCall_CTFWeaponBase_GetWeaponID, weapon);
}

public bool WeaponUsesFixedSpreadPattern(int weapon)
{
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	
	if (StrContains(classname, "tf_weapon_shotgun") != -1)
		return true;
		
	if (StrContains(classname, "tf_weapon_scattergun") != -1)
		return true;
		
	return false;
}

public int GetBulletCount(int weapon)
{
	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	
	if (StrContains(classname, "tf_weapon_shotgun") != -1)
		return 10;
		
	if (StrContains(classname, "tf_weapon_scattergun") != -1)
		return 10;
		
	if (StrContains(classname, "tf_weapon_minigun") != -1)
		return 4;
		
	return 1;
}

// void CTFWeaponBaseGun::FireBullet( CTFPlayer *pPlayer );
public MRESReturn CTFWeaponBaseGun_FireBullet( int weapon, Handle hParams ) 
{
	int player = DHookGetParam(hParams, 1);
	HandleWeaponWallBanging(player, weapon);
	return MRES_Ignored;
}

// void CBaseEntity::FireBullets( const FireBulletsInfo_t &info )
public MRESReturn CBaseEntity_FireBullets( int entity, Handle hParams ) 
{
	bool m_bPlayerControlled = GetEntProp(entity, Prop_Send, "m_bPlayerControlled") == 1;
	if(!m_bPlayerControlled)
		return MRES_Ignored;
	
	Address pFireBulletsInfo_t = DHookGetParamAddress(hParams, 1);
	if (pFireBulletsInfo_t == Address_Null)
		return MRES_Ignored;
	
	HandleSentryGunWallBanging(entity, pFireBulletsInfo_t);
	return MRES_Ignored;
}

public void HandleSentryGunWallBanging(int sentry, Address pFireBulletsInfo_t)
{
	int owner = GetEntPropEnt(sentry, Prop_Send, "m_hBuilder");
	if (owner == INVALID_ENT_REFERENCE)
		return;
		
	g_flAccumDisplayDamage[owner] = 0.0;
	int wrangler = GetPlayerWeaponSlot(owner, 1);
	
	char classname[32];
	GetEntityClassname(wrangler, classname, sizeof(classname));
	// PrintToChatAll(classname);
	
	// Reading shit from pFireBulletsInfo_t
	
	float m_vecSrc[3];
	float m_vecDirShooting[3];
	float m_vecSpread[3];
	
	m_vecSrc[0] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(4), NumberType_Int32);
	m_vecSrc[1] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(8), NumberType_Int32);
	m_vecSrc[2] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(12), NumberType_Int32);
	
	m_vecDirShooting[0] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(16), NumberType_Int32);
	m_vecDirShooting[1] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(20), NumberType_Int32);
	m_vecDirShooting[2] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(24), NumberType_Int32);
	
	m_vecSpread[0] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(28), NumberType_Int32);
	m_vecSpread[1] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(32), NumberType_Int32);
	m_vecSpread[2] = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(36), NumberType_Int32);
	
	float m_flDamage = LoadFromAddress(pFireBulletsInfo_t + view_as<Address>(52), NumberType_Int32);
	
	//
	// Actual Calculation
	//
	
	float vecAng[3];
	GetVectorAngles(m_vecDirShooting, vecAng);
	
	float vecForward[3];
	float vecRight[3];
	float vecUp[3];
	GetAngleVectors(vecAng, vecForward, vecRight, vecUp);
	
	float x = GetRandomFloat(-0.5, 0.5) + GetRandomFloat(-0.5, 0.5);
	float y = GetRandomFloat(-0.5, 0.5) + GetRandomFloat(-0.5, 0.5);
	
	x *= 0.5;
	y *= 0.5;
	
	float vecDir[3];
	for (int j = 0; j < 3; j++)
	{
		vecDir[j] = vecForward[j] + (x * m_vecSpread[0] * vecRight[j]) + (y * m_vecSpread[1] * vecUp[j]);
	}
	
	FireBullet(owner, wrangler, m_flDamage, m_vecSrc, vecDir);
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	g_iPredictionSeed[client] = seed;
	return Plugin_Continue;
}	

public void HookAllPlayers()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			HookPlayer(i);
	}
}

public void HookPlayer(int client)
{
}