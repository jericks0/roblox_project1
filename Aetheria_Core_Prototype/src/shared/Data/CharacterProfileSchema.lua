local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local ValidationService = require(script.Parent.ValidationService)

local CharacterProfileSchema = {}

-- Identity and owner are inputs, not generated defaults. Callers must provide
-- the already-reserved character UUID and account owner.
function CharacterProfileSchema.CreateTemplate(identity, location, now)
	assert(type(identity) == "table", "identity table is required")
	assert(type(location) == "table", "location input is required")
	assert(ValidationService.IsUuid(identity.CharacterId), "identity.CharacterId must be a canonical UUID")
	assert(ValidationService.IsUserId(identity.OwnerUserId), "identity.OwnerUserId must be a positive safe integer")
	for _, field in ipairs({ "Name", "Race", "Class" }) do
		assert(type(identity[field]) == "string" and string.match(identity[field], "%S") ~= nil, "identity." .. field .. " must be a non-whitespace string")
	end
	assert(type(location.RegionId) == "string" and string.match(location.RegionId, "%S") ~= nil, "location.RegionId must be supplied explicitly")
	assert(type(location.Position) == "table", "location.Position is required")
	for _, axis in ipairs({ "X", "Y", "Z" }) do
		local coordinate = location.Position[axis]
		assert(type(coordinate) == "number" and coordinate == coordinate and coordinate ~= math.huge and coordinate ~= -math.huge, "location.Position." .. axis .. " must be finite")
	end
	assert(type(now) == "number" and now == now and now ~= math.huge and now ~= -math.huge and now >= 0, "now must be a finite, non-negative timestamp")

	return {
		CharacterId = identity.CharacterId or "",
		OwnerUserId = identity.OwnerUserId,
		SchemaVersion = DataConfig.CharacterProfileSchemaVersion,
		Revision = 0,
		CreatedAt = now,
		UpdatedAt = now,
		LifecycleStatus = DataConfig.ProfileStatuses.Active,
		Identity = {
			Name = identity.Name or "",
			Race = identity.Race or "",
			Class = identity.Class or "",
		},
		Progression = {
			Level = 1,
			Experience = 0,
		},
		Location = {
			RegionId = location.RegionId,
			Position = {
				X = location.Position and location.Position.X,
				Y = location.Position and location.Position.Y,
				Z = location.Position and location.Position.Z,
			},
		},
		Lock = {
			SessionToken = "",
			LockGeneration = 0,
			LeaseExpiresAt = 0,
		},
	}
end

function CharacterProfileSchema.GetKey(characterId)
	assert(ValidationService.IsUuid(characterId), "characterId must be a canonical UUID")
	return "Character_" .. characterId
end

return CharacterProfileSchema
