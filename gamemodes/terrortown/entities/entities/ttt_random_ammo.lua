---- Dummy ent that just spawns a random TTT ammo item and kills itself

local math = math
local ents = ents
local IsValid = IsValid

ENT.Type = "point"
ENT.Base = "base_point"

function ENT:Initialize()
	local ammos = ents.TTT.GetSpawnableAmmo()

	if ammos then
		local cls = ammos[math.random(1, #ammos)]
		local ent = ents.Create(cls)

		if IsValid(ent) then
			ent:SetPos(self:GetPos())
			ent:SetAngles(self:GetAngles())
			ent:Spawn()
			ent:PhysWake()
		end

		self:Remove()
	end
end
