local DataConfig = require(script.Parent.Parent.Config.DataConfig)
local ValidationService = require(script.Parent.ValidationService)

local AccountRosterSchema = {}

-- now is supplied by the caller so this template remains deterministic and
-- independent from clocks, Roblox services, and persistence APIs.
function AccountRosterSchema.CreateTemplate(userId, now)
	assert(ValidationService.IsUserId(userId), "userId must be a positive safe integer")
	assert(type(now) == "number" and now == now and now ~= math.huge and now ~= -math.huge and now >= 0, "now must be a finite, non-negative timestamp")

	return {
		UserId = userId,
		SchemaVersion = DataConfig.AccountRosterSchemaVersion,
		Revision = 0,
		CreatedAt = now,
		UpdatedAt = now,
		Characters = {},
		DeletedCharacters = {},
		Operations = {},
		Lock = {
			-- Empty token and zero lease represent an unlocked template.
			SessionToken = "",
			LockGeneration = 0,
			LeaseExpiresAt = 0,
		},
	}
end

function AccountRosterSchema.GetKey(userId)
	assert(ValidationService.IsUserId(userId), "userId must be a positive safe integer")
	return "User_" .. tostring(userId)
end

return AccountRosterSchema
