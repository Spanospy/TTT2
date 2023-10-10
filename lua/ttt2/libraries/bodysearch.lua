---
-- Handling body search data and data processing. Is shared between the server and client
-- @author Mineotopia

if SERVER then
	AddCSLuaFile()
end

CORPSE_KILL_NONE = 0

CORPSE_KILL_POINT_BLANK = 1
CORPSE_KILL_CLOSE = 2
CORPSE_KILL_FAR = 3

CORPSE_KILL_FRONT = 1
CORPSE_KILL_BACK = 2
CORPSE_KILL_SIDE = 3

---
-- @realm shared
-- mode 0: normal behavior, everyone can search/confirm bodies
-- mode 1: only public policing roles can confirm bodies, but everyone can still see all data in the menu
-- mode 2: only public policing roles can confirm and search bodies
local cvInspectConfirmMode = CreateConVar("ttt2_inspect_confirm_mode", "0", {FCVAR_NOTIFY, FCVAR_ARCHIVE, FCVAR_REPLICATED})

bodysearch = bodysearch or {}

function bodysearch.GetInspectConfirmMode()
	return cvInspectConfirmMode:GetInt()
end

if SERVER then
	local mathMax = math.max
	local mathRound = math.Round
	local mathFloor = math.floor

	util.AddNetworkString("ttt2_client_reports_corpse")
	util.AddNetworkString("ttt2_client_confirm_corpse")
	util.AddNetworkString("ttt2_credits_were_taken")

	net.Receive("ttt2_client_confirm_corpse", function(_, ply)
		if not IsValid(ply) then return end

		local rag = net.ReadEntity()
		local searchUID = net.ReadUInt(16)
		local isLongRange = net.ReadBool()
		local creditsOnly = net.ReadBool()

		if ply.searchID ~= searchUID then
			ply.searchID = nil

			return
		end

		ply.searchID = nil

		if creditsOnly then
			bodysearch.GiveFoundCredits(ply, rag, false, searchUID)

			return
		end

		if IsValid(rag) and (rag:GetPos():Distance(ply:GetPos()) < 128 or isLongRange) and not CORPSE.GetFound(rag, false) then
			CORPSE.IdentifyBody(ply, rag, searchUID)

			bodysearch.GiveFoundCredits(ply, rag, false, searchUID)
		end
	end)

	net.Receive("ttt2_client_reports_corpse", function(_, ply)
		if not IsValid(ply) then return end

		if not ply:IsActive() then return end

		local rag = net.ReadEntity()

		if not IsValid(rag) or rag:GetPos():Distance(ply:GetPos()) > 128 then return end

		-- in mode 0 the body has to be confirmed to call a detective
		if cvInspectConfirmMode:GetInt() ~= 0 or CORPSE.GetFound(rag, false) then
			local plyTable = util.GetFilteredPlayers(function(p)
				local roleData = p:GetSubRoleData()

				return roleData.isPolicingRole and p.isPublicRole and p:IsTerror()
			end)

			---
			-- @realm server
			hook.Run("TTT2ModifyCorpseCallRadarRecipients", plyTable, rag, ply)

			-- show indicator in radar to detectives
			net.Start("TTT_CorpseCall")
			net.WriteVector(rag:GetPos())
			net.Send(plyTable)

			LANG.MsgAll("body_call", {player = ply:Nick(), victim = CORPSE.GetPlayerNick(rag, "someone")}, MSG_MSTACK_PLAIN)

			---
			-- @realm server
			hook.Run("TTT2CalledPolicingRole", plyTable, ply, rag, CORPSE.GetPlayer(rag))
		else
			LANG.Msg(ply, "body_call_error", nil, MSG_MSTACK_WARN)
		end
	end)

	function bodysearch.GiveFoundCredits(ply, rag, isLongRange, searchUID)
		local corpseNick = CORPSE.GetPlayerNick(rag)
		local credits = CORPSE.GetCredits(rag, 0)

		if not ply:IsActiveShopper() or ply:GetSubRoleData().preventFindCredits
			or credits == 0 or isLongRange
		then return end

		LANG.Msg(ply, "body_credits", {num = credits})

		ply:AddCredits(credits)

		CORPSE.SetCredits(rag, 0)

		ServerLog(ply:Nick() .. " took " .. credits .. " credits from the body of " .. corpseNick .. "\n")

		events.Trigger(EVENT_CREDITFOUND, ply, rag, credits)

		-- update clients so their UIs can be updated
		net.Start("ttt2_credits_were_taken")
		net.WriteUInt(searchUID or 0, 16)
		net.Broadcast()
	end

	function bodysearch.AssimilateSceneData(inspector, rag, isCovert, isLongRange)
		local sData = {}
		local inspectorRoleData = inspector:GetSubRoleData()
		local isPublicPolicingSearch = inspectorRoleData.isPolicingRole and inspectorRoleData.isPublicRole

		-- hot-reloads can break the data, therefore we have to sanitize it
		rag.scene = rag.scene or {}

		-- data that is available to everyone
		sData.base = {}
		sData.base.inspector = inspector
		sData.base.isPublicPolicingSearch = isPublicPolicingSearch and inspector:IsActive() and not isCovert

		sData.playerModel = rag.scene.plyModel or ""
		sData.ragOwner = player.GetBySteamID64(rag.sid64)
		sData.credits = CORPSE.GetCredits(rag, 0)
		sData.searchUID = mathFloor(rag:EntIndex() + (rag.time or 0))

		-- if a non-public or non-policing role tries to search a body in mode 2, nothing happens
		if cvInspectConfirmMode:GetInt() == 2 and not isPublicPolicingSearch and not inspector:IsSpec() then
			return sData
		end

		sData.nick = CORPSE.GetPlayerNick(rag)
		sData.subrole = rag.was_role
		sData.roleColor = rag.role_color
		sData.team = rag.was_team

		if not sData.nick or not sData.subrole or not sData.team then
			return
		end

		sData.rag = rag
		sData.eq = rag.equipment or {}
		sData.c4CutWire = rag.bomb_wire or - 1
		sData.dmgType = rag.dmgtype or DMG_GENERIC
		sData.wep = rag.dmgwep or ""
		sData.lastWords = rag.last_words
		sData.wasHeadshot = rag.was_headshot or false
		sData.deathTime = rag.time or 0
		sData.sid64 = rag.scene.plySID64 or ""
		sData.lastDamage = mathRound(mathMax(0, rag.scene.lastDamage or 0))
		sData.killFloorSurface = rag.scene.floorSurface or 0
		sData.killWaterLevel = rag.scene.waterLevel or 0
		sData.lastSeenEnt = rag.lastid and rag.lastid.ent or nil

		sData.killDistance = CORPSE_KILL_NONE
		if rag.scene.hit_trace then
			local rawKillDistance = rag.scene.hit_trace.StartPos:Distance(rag.scene.hit_trace.HitPos)
			if rawKillDistance < 200 then
				sData.killDistance = CORPSE_KILL_POINT_BLANK
			elseif rawKillDistance >= 700 then
				sData.killDistance = CORPSE_KILL_FAR
			elseif rawKillDistance >= 200 then
				sData.killDistance = CORPSE_KILL_CLOSE
			end
		end

		sData.killHitGroup = HITGROUP_GENERIC
		if rag.scene.hit_group and rag.scene.hit_group > 0 then
			sData.killHitGroup = rag.scene.hit_group
		end

		sData.killOrientation = CORPSE_KILL_NONE
		if rag.scene.hit_trace and rag.scene.dmginfo:IsBulletDamage() then
			local rawKillAngle = math.abs(math.AngleDifference(rag.scene.hit_trace.StartAng.yaw, rag.scene.victim.aim_yaw))

			if rawKillAngle < 45 then
				sData.killOrientation = CORPSE_KILL_BACK
			elseif rawKillAngle < 135 then
				sData.killOrientation = CORPSE_KILL_SIDE
			else
				sData.killOrientation = CORPSE_KILL_FRONT
			end
		end

		sData.sampleDecayTime = 0
		if rag.killer_sample then
			sData.sampleDecayTime = rag.killer_sample.t
		end

		-- build list of people this player killed, but only if convar is enabled
		sData.kill_entids = {}
		if GetConVar("ttt2_confirm_killlist"):GetBool() then
			local ragKills = rag.kills or {}

			for i = 1, #ragKills do
				local vicsid = ragKills[i]

				-- also send disconnected players as a marker
				local vic = player.GetBySteamID64(vicsid)

				sData.kill_entids[#sData.kill_entids + 1] = IsValid(vic) and vic:EntIndex() or -1
			end
		end

		return sData
	end

	function bodysearch.StreamSceneData(sData, client)
		net.SendStream("TTT2_BodySearchData", sData, client)
	end
end

if CLIENT then
	-- cache functions
	local utilSimpleTime = util.SimpleTime
	local CurTime = CurTime
	local utilBitSet = util.BitSet
	local mathMax = math.max
	local table = table
	local IsValid = IsValid
	local pairs = pairs

	net.ReceiveStream("TTT2_BodySearchData", function(searchStreamData)
		local eq = {} -- placeholder for the hook, not used right now
		---
		-- @realm shared
		hook.Run("TTTBodySearchEquipment", searchStreamData, eq)

		searchStreamData.show = LocalPlayer() == searchStreamData.base.inspector

		-- cache search result in rag.bodySearchResult, e.g. useful for scoreboard
		bodysearch.StoreSearchResult(searchStreamData)

		if searchStreamData.show then
			-- if there is more elaborate data already available
			-- confirming this body, then this should be used instead
			if bodysearch.PlayerHasDetailedSearchResult(searchStreamData.ragOwner) then
				SEARCHSCRN:Show(bodysearch.GetSearchResult(searchStreamData.ragOwner))
			else
				SEARCHSCRN:Show(searchStreamData)
			end
		end

		-- add this hack here to keep compatibility to the old scoreboard
		searchStreamData.show_sb = searchStreamData.show or searchStreamData.base.isPublicPolicingSearch
	end)

	local damageToText = {
		["crush"] = DMG_CRUSH,
		["bullet"] = DMG_BULLET,
		["fall"] = DMG_FALL,
		["boom"] = DMG_BLAST,
		["club"] = DMG_CLUB,
		["drown"] = DMG_DROWN,
		["stab"] = DMG_SLASH,
		["burn"] = DMG_BURN,
		["tele"] = DMG_SONIC,
		["car"] = DMG_VEHICLE
	}

	local damageFromType = {
		["bullet"] = DMG_BULLET,
		["rock"] = DMG_CRUSH,
		["splode"] = DMG_BLAST,
		["fall"] = DMG_FALL,
		["fire"] = DMG_BURN,
		["drown"] = DMG_DROWN
	}

	local distanceToText = {
		[CORPSE_KILL_POINT_BLANK] = "search_kill_distance_point_blank",
		[CORPSE_KILL_CLOSE] = "search_kill_distance_close",
		[CORPSE_KILL_FAR] = "search_kill_distance_far"
	}

	local orientationToText = {
		[CORPSE_KILL_FRONT] = "search_kill_from_front",
		[CORPSE_KILL_BACK] = "search_kill_from_back",
		[CORPSE_KILL_SIDE] = "search_kill_from_side"
	}

	local floorIDToText = {
		[MAT_ANTLION] = "search_floor_antillions",
		[MAT_BLOODYFLESH] = "search_floor_bloodyflesh",
		[MAT_CONCRETE] = "search_floor_concrete",
		[MAT_DIRT] = "search_floor_dirt",
		[MAT_EGGSHELL] = "search_floor_eggshell",
		[MAT_FLESH] = "search_floor_flesh",
		[MAT_GRATE] = "search_floor_grate",
		[MAT_ALIENFLESH] = "search_floor_alienflesh",
		[MAT_SNOW] = "search_floor_snow",
		[MAT_PLASTIC] = "search_floor_plastic",
		[MAT_METAL] = "search_floor_metal",
		[MAT_SAND] = "search_floor_sand",
		[MAT_FOLIAGE] = "search_floor_foliage",
		[MAT_COMPUTER] = "search_floor_computer",
		[MAT_SLOSH] = "search_floor_slosh",
		[MAT_TILE] = "search_floor_tile",
		[MAT_GRASS] = "search_floor_grass",
		[MAT_VENT] = "search_floor_vent",
		[MAT_WOOD] = "search_floor_wood",
		[MAT_DEFAULT] = "search_floor_default",
		[MAT_GLASS] = "search_floor_glass",
		[MAT_WARPSHIELD] = "search_floor_warpshield"
	}

	local hitgroup_to_text = {
		[HITGROUP_HEAD] = "search_hitgroup_head",
		[HITGROUP_CHEST] = "search_hitgroup_chest",
		[HITGROUP_STOMACH] = "search_hitgroup_stomach",
		[HITGROUP_RIGHTARM] = "search_hitgroup_rightarm",
		[HITGROUP_LEFTARM] = "search_hitgroup_leftarm",
		[HITGROUP_RIGHTLEG] = "search_hitgroup_rightleg",
		[HITGROUP_LEFTLEG] = "search_hitgroup_leftleg",
		[HITGROUP_GEAR] = "search_hitgroup_gear"
	}

	local function DamageToText(dmg)
		for key, value in pairs(damageToText) do
			if utilBitSet(dmg, value) then
				return key
			end
		end

		if utilBitSet(dmg, DMG_DIRECT) then
			return "burn"
		end

		return "other"
	end

	local DataToText = {
		last_words = function(data)
			if not data.lastWords or data.lastWords == "" then return end

			-- only append "--" if there's no ending interpunction
			local final = string.match(data.lastWords, "[\\.\\!\\?]$") ~= nil

			return {
				title = {
					body = "search_title_words",
					params = nil
				},
				text = {{
					body = "search_words",
					params = {lastwords = data.lastWords .. (final and "" or "--.")}
				}}
			}
		end,
		c4_disarm = function(data)
			if not data.c4CutWire or data.c4CutWire <= 0 then return end

			return {
				title = {
					body = "search_title_c4",
					params = nil
				},
				text = {{
					body = "search_c4",
					params = {num = data.c4CutWire}
				}}
			}
		end,
		dmg = function(data)
			if not data.dmgType then return end

			local rawText = {
				title = {
					body = "search_title_dmg_" .. DamageToText(data.dmgType),
					params = {amount = data.lastDamage}
				},
				text = {{
					body = "search_dmg_" .. DamageToText(data.dmgType),
					params = nil
				}}
			}

			if data.killOrientation ~= CORPSE_KILL_NONE then
				rawText.text[#rawText.text + 1] = {
					body = orientationToText[data.killOrientation],
					params = nil
				}
			end

			if data.wasHeadshot then
				rawText.text[#rawText.text + 1] = {
					body = "search_head",
					params = nil
				}
			end

			return rawText
		end,
		wep = function(data)
			if not data.wep then return end

			local wep = util.WeaponForClass(data.wep)

			local wname = wep and wep.PrintName

			if not wname then return end

			local rawText = {
				title = {
					body = wname,
					params = nil
				},
				text = {{
					body = "search_weapon",
					params = {weapon = wname}
				}}
			}

			if data.dist ~= CORPSE_KILL_NONE then
				rawText.text[#rawText.text + 1] = {
					body = distanceToText[data.killDistance],
					params = nil
				}
			end

			if data.killHitGroup > 0 then
				rawText.text[#rawText.text + 1] = {
					body = hitgroup_to_text[data.killHitGroup],
					params = nil
				}
			end

			return rawText
		end,
		death_time = function(data)
			if not data.deathTime then return end

			return {
				title = {
					body = "search_title_time",
					params = nil
				},
				text = {{
					body = "search_time",
					params = nil
				}}
			}
		end,
		dna_time = function(data)
			if not data.sampleDecayTime or data.sampleDecayTime - CurTime() <= 0 then return end

			return {
				title = {
					body = "search_title_dna",
					params = nil
				},
				text = {{
					body = "search_dna",
					params = nil
				}}
			}
		end,
		kill_list = function(data)
			if not data.kills then return end

			local num = table.Count(data.kills)

			if num == 1 then
				local vic = Entity(data.kills[1])
				local dc = data.kills[1] == -1 -- disconnected

				if dc or IsValid(vic) and vic:IsPlayer() then
					return {
						title = {
							body = "search_title_kills",
							params = nil
						},
						text = {{
							body = "search_kills1",
							params = {player = dc and "<Disconnected>" or vic:Nick()}
						}}
					}
				end
			elseif num > 1 then
				local nicks = {}

				for k, idx in pairs(data.kills) do
					local vic = Entity(idx)
					local dc = idx == -1

					if dc or IsValid(vic) and vic:IsPlayer() then
						nicks[#nicks + 1] = dc and "<Disconnected>" or vic:Nick()
					end
				end

				return {
					title = {
						body = "search_title_kills",
						params = nil
					},
					text = {{
						body = "search_kills2",
						params = {player = table.concat(nicks, "\n", 1, last)}
					}}
				}
			end
		end,
		last_id = function(data)
			if not IsValid(data.lastSeenEnt) or not data.lastSeenEnt:IsPlayer() then return end

			return {
				title = {
					body = "search_title_eyes",
					params = nil
				},
				text = {{
					body = "search_eyes",
					params = {player = data.lastSeenEnt:Nick()}
				}}
			}
		end,
		floor_surface = function(data)
			if not data.killFloorSurface or data.killFloorSurface == 0 or not floorIDToText[data.killFloorSurface] then return end

			return {
				title = {
					body = "search_title_floor",
					params = nil
				},
				text = {{
					body = floorIDToText[data.killFloorSurface],
					params = nil
				}}
			}
		end,
		credits = function(data)
			if not data.credits or data.credits == 0 then return end

			-- special case: mode 2, only shopping roles can see credits
			local client = LocalPlayer()
			if bodysearch.GetInspectConfirmMode() == 2
				and (not client:IsActiveShopper() or client:GetSubRoleData().preventFindCredits)
			then return end

			return {
				title = {
					body = "search_title_credits",
					params = {credits = data.credits}
				},
				text = {{
					body = "search_credits",
					params = {credits = data.credits}
				}}
			}
		end,
		water_level = function(data)
			if not data.killWaterLevel or data.killWaterLevel == 0 then return end

			return {
				title = {
					body = "search_title_water",
					params = {level = data.killWaterLevel}
				},
				text = {{
					body = "search_water_" .. data.killWaterLevel,
					params = nil
				}}
			}
		end
	}

	local materialDamage = {
		["bullet"] = Material("vgui/ttt/icon_bullet"),
		["rock"] = Material("vgui/ttt/icon_rock"),
		["splode"] = Material("vgui/ttt/icon_splode"),
		["fall"] = Material("vgui/ttt/icon_fall"),
		["fire"] = Material("vgui/ttt/icon_fire"),
		["drown"] = Material("vgui/ttt/icon_drown"),
		["generic"] = Material("vgui/ttt/icon_skull")
	}

	local materialWaterLevel = {
		[1] = Material("vgui/ttt/icon_water_1"),
		[2] = Material("vgui/ttt/icon_water_2"),
		[3] = Material("vgui/ttt/icon_water_3")
	}

	local materialHeadShot = Material("vgui/ttt/icon_head")
	local materialDeathTime = Material("vgui/ttt/icon_time")
	local materialCredits = Material("vgui/ttt/icon_credits")
	local materialDNA = Material("vgui/ttt/icon_wtester")
	local materialFloor = Material("vgui/ttt/icon_floor")
	local materialC4Disarm = Material("vgui/ttt/icon_code")
	local materialLastID = Material("vgui/ttt/icon_lastid")
	local materialKillList = Material("vgui/ttt/icon_list")
	local materialLastWords = Material("vgui/ttt/icon_halp")

	local function DamageToIconMaterial(data)
		-- handle headshots first
		if data.wasHeadshot then
			return materialHeadShot
		end

		-- the damage type
		local dmg = data.dmgType

		-- handle most generic damage types
		for key, value in pairs(damageFromType) do
			if utilBitSet(dmg, value) then
				return materialDamage[key]
			end
		end

		-- special case handling with a fallback for generic damage
		if utilBitSet(dmg, DMG_DIRECT) then
			return materialDamage["fire"]
		else
			return materialDamage["generic"]
		end
	end

	local function TypeToMaterial(type, data)
		if type == "wep" then
			return util.WeaponForClass(data.wep).iconMaterial
		elseif type == "dmg" then
			return DamageToIconMaterial(data)
		elseif type == "death_time" then
			return materialDeathTime
		elseif type == "credits" then
			return materialCredits
		elseif type == "dna_time" then
			return materialDNA
		elseif type == "floor_surface" then
			return materialFloor
		elseif type == "water_level" then
			return materialWaterLevel[data.water_level]
		elseif type == "c4_disarm" then
			return materialC4Disarm
		elseif type == "last_id" then
			return materialLastID
		elseif type == "kill_list" then
			return materialKillList
		elseif type == "last_words" then
			return materialLastWords
		end
	end

	local function TypeToIconText(type, data)
		if type == "death_time" then
			return function()
				return utilSimpleTime(CurTime() - data.deathTime, "%02i:%02i")
			end
		elseif type == "dna_time" then
			return function()
				return utilSimpleTime(mathMax(0, data.sampleDecayTime - CurTime()), "%02i:%02i")
			end
		end
	end

	local function TypeToColor(type, data)
		if type == "dna_time" then
			return roles.DETECTIVE.color
		elseif type == "credits" then
			return COLOR_GOLD
		end
	end

	bodysearch.searchResultOrder = {
		"wep",
		"dmg",
		"death_time",
		"credits",
		"dna_time",
		"floor_surface",
		"water_level",
		"c4_disarm",
		"last_id",
		"kill_list",
		"last_words"
	}

	function bodysearch.GetContentFromData(type, data)
		-- make sure type is valid
		if not isfunction(DataToText[type]) then return end

		local text = DataToText[type](data)

		-- DataToText checks if criteria for display is met, no box should be
		-- shown if criteria is not met.
		if not text then return end

		return {
			iconMaterial = TypeToMaterial(type, data),
			iconText = TypeToIconText(type, data),
			colorBox = TypeToColor(type, data),
			text = text
		}
	end

	---
	-- Creates a table with icons, text,... out of search_raw table
	-- @param table raw
	-- @return table a converted search data table
	-- @note This function is old and should be redone on a scoreboard rework
	-- @realm client
	function bodysearch.PreprocSearch(raw)
		local search = {}

		for i = 1, #bodysearch.searchResultOrder do
			local type = bodysearch.searchResultOrder[i]
			local searchData = bodysearch.GetContentFromData(type, raw)

			if not searchData then continue end

			-- a workaround to build the rext for the scoreboard
			local text = searchData.text.text
			local transText = ""

			-- only use the first text entry here
			local par = text[1].params
			if par then
				-- process params (translation)
				for k, v in pairs(par) do
					par[k] = LANG.TryTranslation(v)
				end

				transText = transText .. LANG.GetParamTranslation(text[1].body, par) .. " "
			else
				transText = transText .. LANG.TryTranslation(text[1].body) .. " "
			end

			search[type] = {
				img = searchData.iconMaterial:GetName(),
				text = transText,
				p = i -- sorting number
			}

			-- special cases with icon text
			local iconTextFn = TypeToIconText(type, raw)
			if isfunction(iconTextFn) then
				search[type].text_icon = iconTextFn()
			end
		end

		---
		-- @realm client
		hook.Run("TTTBodySearchPopulate", search, raw)

		return search
	end

	function bodysearch.StoreSearchResult(sData)
		if not sData.ragOwner then return end

		-- if existing result was not ours, it was detective's, and should not
		-- be overwritten
		local ply = sData.ragOwner
		local rag = sData.rag

		-- do not store if searching player (client) is spectator
		if LocalPlayer():IsSpec() then return end

		-- if the currently stored search result is by a public policing role, it should be kept
		-- it can be overwritten by another public policing role though
		-- data can still be updated, but the original base is kept
		local oldBase
		if ply.bodySearchResult and ply.bodySearchResult.base and ply.bodySearchResult.base.isPublicPolicingSearch
			and not sData.base.isPublicPolicingSearch
		then
			oldBase = sData.base
		end

		-- merge new data into old data
		-- this is useful if a player had good data on a body from another source
		-- and now gets updated info on it as it now only replaces the newly added
		-- entries
		local newData = ply.bodySearchResult or {}
		table.Merge(newData, sData)

		-- keep the original finder info if previously searched by public policing role
		newData.base = oldBase or newData.base

		ply.bodySearchResult = newData

		-- also store data in the ragdoll for targetID
		if not IsValid(rag) then return end

		rag.bodySearchResult = newData
	end

	function bodysearch.PlayerHasDetailedSearchResult(ply)
		-- note: the nick is only transmitted if there is full search data available
		return IsValid(ply) and ply.bodySearchResult and ply.bodySearchResult.nick ~= nil
	end

	function bodysearch.GetSearchResult(ply)
		return ply.bodySearchResult or {}
	end

	function bodysearch.ResetSearchResult(ply)
		if not IsValid(ply) then return end

		ply.bodySearchResult = nil
	end

	function bodysearch.ClientConfirmsCorpse(rag, searchUID, isLongRange, creditsOnly)
		net.Start("ttt2_client_confirm_corpse")
		net.WriteEntity(rag)
		net.WriteUInt(searchUID, 16)
		net.WriteBool(isLongRange)
		net.WriteBool(creditsOnly or false)
		net.SendToServer()
	end

	function bodysearch.ClientReportsCorpse(rag)
		net.Start("ttt2_client_reports_corpse")
		net.WriteEntity(rag)
		net.SendToServer()
	end

	function bodysearch.IsConfirmed(ragOwner)
		return IsValid(ragOwner) and ragOwner:TTT2NETGetBool("body_found", false)
	end

	function bodysearch.CanConfirmBody(ragOwner)
		local client = LocalPlayer()

		if client:IsSpec() then
			return false
		end

		-- in mode 0 everyone can confirm corpses
		if cvInspectConfirmMode:GetInt() == 0 then
			return true
		end

		local roleData = client:GetSubRoleData()

		-- in mode 1 and 2 only public policing roles can confirm corpses
		if roleData.isPolicingRole and roleData.isPublicRole then
			return true
		end

		return false
	end

	function bodysearch.CanReportBody(ragOwner)
		local client = LocalPlayer()

		if client:IsSpec() then
			return false
		end

		-- in mode 0 the ragdoll has to be found to report body
		if cvInspectConfirmMode:GetInt() == 0
			and IsValid(ragOwner) and not ragOwner:TTT2NETGetBool("body_found", false)
		then
			return false
		end

		return true
	end

	-- HOOKS --

	---
	-- This hook can be used to populate the body search panel.
	-- @param table search The search data table
	-- @param table raw The raw search data
	-- @hook
	-- @realm client
	function GM:TTTBodySearchPopulate(search, raw)

	end

	---
	-- This hook can be used to modify the equipment info of a corpse.
	-- @param table search The search data table
	-- @param table equip The raw equipment table
	-- @hook
	-- @realm client
	function GM:TTTBodySearchEquipment(search, equip)

	end

	---
	-- This hook is called right before the killer found @{MSTACK} notification
	-- is added.
	-- @param string finder The nickname of the finder
	-- @param string victim The nickname of the victim
	-- @hook
	-- @realm client
	function GM:TTT2ConfirmedBody(finder, victim)

	end
end
