-- Studio-runnable, dependency-free unit tests.
-- Run from the Studio Command Bar with:
-- require(game:GetService("TestService").Tests.SchemaValidationTests)()

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Data = Shared:WaitForChild("Data")
local Config = Shared:WaitForChild("Config")

local DataConfig = require(Config.DataConfig)
local AccountRosterSchema = require(Data.AccountRosterSchema)
local CharacterProfileSchema = require(Data.CharacterProfileSchema)
local ValidationService = require(Data.ValidationService)

local function deepCopy(value)
	if type(value) ~= "table" then return value end
	local copy = {}
	for key, child in pairs(value) do copy[key] = deepCopy(child) end
	return copy
end

local function deepEqual(left, right)
	if type(left) ~= type(right) then return false end
	if type(left) ~= "table" then return left == right end
	for key, value in pairs(left) do
		if not deepEqual(value, right[key]) then return false end
	end
	for key in pairs(right) do
		if left[key] == nil then return false end
	end
	return true
end

local function expectValid(record, validator, label)
	local result = validator(record)
	assert(result.IsValid, label .. " expected valid, got: " .. (result.Errors[1] and result.Errors[1].Code or "unknown error"))
end

local function expectInvalid(record, validator, label, expectedCode)
	local result = validator(record)
	assert(not result.IsValid, label .. " expected invalid")
	if expectedCode then
		for _, issue in ipairs(result.Errors) do
			if issue.Code == expectedCode then return end
		end
		assert(false, label .. " did not return expected code " .. expectedCode)
	end
end

local function makeEntry(index, name)
	return {
		CharacterId = string.format("00000000-0000-4000-8000-%012x", index),
		Name = name or ("Hero" .. tostring(index)),
		Race = "Human",
		Class = "Warrior",
		Status = DataConfig.CharacterStatuses.Active,
	}
end

local function makeProfile()
	return CharacterProfileSchema.CreateTemplate({
		CharacterId = "123e4567-e89b-42d3-a456-426614174000",
		OwnerUserId = 12345,
		Name = "Aster",
		Race = "Human",
		Class = "Mage",
	}, {
		RegionId = "TestRegion",
		Position = { X = 0, Y = 0, Z = 0 },
	}, 100)
end

local function makeCreateOperation(operationId, characterId, status)
	return {
		OperationId = operationId,
		Type = DataConfig.LifecycleOperationTypes.Create,
		Status = status or DataConfig.LifecycleOperationStatuses.Pending,
		CharacterId = characterId,
		CreationIdentity = { Name = "Aster", Race = "Human", Class = "Mage" },
		InitialLocation = {
			RegionId = "TestRegion",
			Position = { X = 10, Y = 20, Z = 30 },
		},
		CreatedAt = 100,
		UpdatedAt = 100,
	}
end

local function expectCallError(callback, label)
	local ok = pcall(callback)
	assert(not ok, label .. " should have been rejected")
end

return function()
	local passed = 0
	local function test(label, callback)
		callback()
		passed += 1
		print("[SchemaValidationTests] PASS " .. label)
	end

	test("valid empty roster template", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		assert(AccountRosterSchema.GetKey(12345) == "User_12345")
		expectValid(roster, ValidationService.ValidateAccountRoster, "empty roster")
	end)

	for count = 1, 3 do
		test("valid roster with " .. tostring(count) .. " character(s)", function()
			local roster = AccountRosterSchema.CreateTemplate(12345, 100)
			for index = 1, count do roster.Characters[index] = makeEntry(index) end
			expectValid(roster, ValidationService.ValidateAccountRoster, "roster count " .. tostring(count))
		end)
	end

	test("reject more than three characters", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		for index = 1, 4 do roster.Characters[index] = makeEntry(index) end
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "four characters", "TOO_MANY_CHARACTERS")
	end)

	test("pending creation reserves a character slot", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Characters = { makeEntry(1), makeEntry(2), makeEntry(3) }
		roster.Operations = { makeCreateOperation("op-1", "00000000-0000-4000-8000-000000000004") }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "reserved fourth slot", "TOO_MANY_CHARACTER_SLOTS")
	end)

	test("pending creation already committed does not count twice", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Characters = { makeEntry(1), makeEntry(2), makeEntry(3) }
		roster.Operations = { makeCreateOperation("op-1", roster.Characters[1].CharacterId) }
		expectValid(roster, ValidationService.ValidateAccountRoster, "uncertain roster commit")
	end)

	test("deleted characters do not occupy active slots", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Characters = { makeEntry(1), makeEntry(2), makeEntry(3) }
		roster.DeletedCharacters = {
			{
				CharacterId = "00000000-0000-4000-8000-000000000010",
				Name = "Retained", Race = "Human", Class = "Warrior", Status = "Deleted",
				DeletedAt = 100, PurgeAfter = 200,
			},
		}
		expectValid(roster, ValidationService.ValidateAccountRoster, "deleted character outside slots")
	end)

	test("reject duplicate names within roster", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Characters = { makeEntry(1, "Same"), makeEntry(2, "Same") }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "duplicate names", "DUPLICATE_CHARACTER_NAME")
	end)

	test("allow same name in separate account rosters", function()
		for _, userId in ipairs({ 111, 222 }) do
			local roster = AccountRosterSchema.CreateTemplate(userId, 100)
			roster.Characters = { makeEntry(userId, "SharedName") }
			expectValid(roster, ValidationService.ValidateAccountRoster, "separate roster")
		end
	end)

	test("valid profile template and key", function()
		local profile = makeProfile()
		assert(CharacterProfileSchema.GetKey(profile.CharacterId) == "Character_123e4567-e89b-42d3-a456-426614174000")
		expectValid(profile, ValidationService.ValidateCharacterProfile, "profile")
	end)

	test("profile template requires an explicit location", function()
		local ok = pcall(function()
			CharacterProfileSchema.CreateTemplate({ CharacterId = "123e4567-e89b-42d3-a456-426614174000" }, nil, 100)
		end)
		assert(not ok, "missing location should not silently choose a starting region")
	end)

	test("reject missing required fields", function()
		local profile = makeProfile()
		profile.Identity = nil
		profile.Lock = nil
		expectInvalid(profile, ValidationService.ValidateCharacterProfile, "missing fields", "REQUIRED_OBJECT")
	end)

	test("reject invalid field types and ranges", function()
		local profile = makeProfile()
		profile.Revision = -1
		profile.Progression.Level = 0
		profile.Location.Position.X = math.huge
		expectInvalid(profile, ValidationService.ValidateCharacterProfile, "bad types/ranges", "INVALID_INTEGER")
		local badRoster = AccountRosterSchema.CreateTemplate(12345, 100)
		badRoster.Lock.LockGeneration = "new"
		expectInvalid(badRoster, ValidationService.ValidateAccountRoster, "bad roster lock type", "INVALID_INTEGER")
	end)

	test("lock validation does not assume token and lease encoding", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Lock.SessionToken = ""
		roster.Lock.LeaseExpiresAt = 500
		expectValid(roster, ValidationService.ValidateAccountRoster, "opaque lock representation one")
		roster.Lock.SessionToken = "session-token"
		roster.Lock.LeaseExpiresAt = 0
		expectValid(roster, ValidationService.ValidateAccountRoster, "opaque lock representation two")
	end)

	test("reject invalid UserId, CharacterId and UUID", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.UserId = 0
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "invalid UserId", "INVALID_USER_ID")
		local profile = makeProfile()
		profile.CharacterId = "not-a-uuid"
		expectInvalid(profile, ValidationService.ValidateCharacterProfile, "invalid CharacterId", "INVALID_CHARACTER_ID")
	end)

	test("key helpers reject invalid identifiers", function()
		expectCallError(function() AccountRosterSchema.GetKey(nil) end, "nil UserId key")
		for _, invalid in ipairs({ "123", 0, -1, 1.5, math.huge, -math.huge, 0 / 0 }) do
			expectCallError(function() AccountRosterSchema.GetKey(invalid) end, "invalid UserId key")
		end
		for _, invalid in ipairs({ "not-a-uuid", "123e4567-e89b-42d3-a456-42661417400Z", 123 }) do
			expectCallError(function() CharacterProfileSchema.GetKey(invalid) end, "invalid UUID key")
		end
	end)

	test("reject duplicate CharacterId across active and deleted entries", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		roster.Characters = { entry }
		roster.DeletedCharacters = {
			{ CharacterId = entry.CharacterId, Name = "Retained", Race = "Human", Class = "Warrior", Status = "Deleted", DeletedAt = 100, PurgeAfter = 200 },
		}
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "active/deleted collision", "DUPLICATE_CHARACTER_ID")
	end)

	test("reject duplicate operation IDs and pending reservations", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Operations = {
			makeCreateOperation("same-op", "00000000-0000-4000-8000-000000000011"),
			makeCreateOperation("same-op", "00000000-0000-4000-8000-000000000011"),
		}
		local result = ValidationService.ValidateAccountRoster(roster)
		assert(not result.IsValid)
		local codes = {}
		for _, issue in ipairs(result.Errors) do codes[issue.Code] = true end
		assert(codes.DUPLICATE_OPERATION_ID)
		assert(codes.DUPLICATE_PENDING_CHARACTER_ID)
	end)

	test("pending Create cannot reuse a deleted CharacterId", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local characterId = "00000000-0000-4000-8000-000000000013"
		roster.DeletedCharacters = {
			{ CharacterId = characterId, Name = "Retained", Race = "Human", Class = "Mage", Status = "Deleted", DeletedAt = 100, PurgeAfter = 200 },
		}
		roster.Operations = { makeCreateOperation("create-again", characterId) }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "pending create reuses deleted ID", "CHARACTER_ID_COLLISION")
	end)

	test("different pending operation types cannot target one CharacterId", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local create = makeCreateOperation("create-op", "00000000-0000-4000-8000-000000000014")
		local deletion = makeCreateOperation("delete-op", create.CharacterId)
		deletion.Type = DataConfig.LifecycleOperationTypes.Delete
		deletion.CreationIdentity = nil
		deletion.InitialLocation = nil
		roster.Operations = { create, deletion }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "pending operations share CharacterId", "DUPLICATE_PENDING_CHARACTER_ID")
	end)

	test("reject whitespace-only character names", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Characters = { makeEntry(1, "   \t") }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "whitespace-only name", "INVALID_NAME")
	end)

	test("persisted creation intent reconstructs a complete profile", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local characterId = "00000000-0000-4000-8000-000000000012"
		local operation = makeCreateOperation("create-op", characterId)
		roster.Operations = { operation }
		expectValid(roster, ValidationService.ValidateAccountRoster, "creation intent")
		local reconstructed = CharacterProfileSchema.CreateTemplate({
			CharacterId = operation.CharacterId,
			OwnerUserId = roster.UserId,
			Name = operation.CreationIdentity.Name,
			Race = operation.CreationIdentity.Race,
			Class = operation.CreationIdentity.Class,
		}, operation.InitialLocation, operation.CreatedAt)
		expectValid(reconstructed, ValidationService.ValidateCharacterProfile, "reconstructed profile")
		assert(operation.OperationId == "create-op")
		assert(reconstructed.CharacterId == characterId)
		assert(reconstructed.OwnerUserId == roster.UserId)
		assert(reconstructed.Identity.Name == "Aster")
		assert(reconstructed.Identity.Race == "Human")
		assert(reconstructed.Identity.Class == "Mage")
		assert(reconstructed.Location.RegionId == operation.InitialLocation.RegionId)
		assert(reconstructed.Location.Position.X == operation.InitialLocation.Position.X)
		assert(reconstructed.Location.Position.Y == operation.InitialLocation.Position.Y)
		assert(reconstructed.Location.Position.Z == operation.InitialLocation.Position.Z)
	end)

	test("creation intent rejects invalid initial location", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local operation = makeCreateOperation("create-op", "00000000-0000-4000-8000-000000000015")
		operation.InitialLocation.Position.X = math.huge
		roster.Operations = { operation }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "invalid initial location", "INVALID_POSITION")
	end)

	test("cross-record ownership validation", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		roster.Characters = { entry }
		local profile = makeProfile()
		profile.CharacterId = entry.CharacterId
		assert(ValidationService.ValidateRosterProfileOwnership(roster, profile).IsValid)
		profile.OwnerUserId = 67890
		expectInvalid({ Roster = roster, Profile = profile }, function(value)
			return ValidationService.ValidateRosterProfileOwnership(value.Roster, value.Profile)
		end, "owner mismatch", "OWNER_MISMATCH")
	end)

	test("cross-record CharacterId mismatch is rejected", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		roster.Characters = { entry }
		local profile = makeProfile()
		expectInvalid({ Roster = roster, Profile = profile }, function(value)
			return ValidationService.ValidateRosterProfileOwnership(value.Roster, value.Profile, entry.CharacterId)
		end, "character mismatch", "CHARACTER_ID_MISMATCH")
	end)

	test("deleted characters cannot enter gameplay", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		roster.DeletedCharacters = {
			{ CharacterId = entry.CharacterId, Name = entry.Name, Race = entry.Race, Class = entry.Class, Status = "Deleted", DeletedAt = 100, PurgeAfter = 200 },
		}
		local profile = makeProfile()
		profile.CharacterId = entry.CharacterId
		profile.LifecycleStatus = DataConfig.ProfileStatuses.Deleted
		expectInvalid({ Roster = roster, Profile = profile }, function(value)
			return ValidationService.ValidateRosterProfileOwnership(value.Roster, value.Profile)
		end, "deleted admission", "DELETED_CHARACTER_NOT_ADMISSIBLE")
	end)

	test("Deleting roster entry cannot enter gameplay", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		entry.Status = DataConfig.CharacterStatuses.Deleting
		roster.Characters = { entry }
		local profile = makeProfile()
		profile.CharacterId = entry.CharacterId
		expectInvalid({ Roster = roster, Profile = profile }, function(value)
			return ValidationService.ValidateRosterProfileOwnership(value.Roster, value.Profile)
		end, "deleting roster entry", "CHARACTER_NOT_ACTIVE")
	end)

	test("Deleting profile cannot enter gameplay", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		roster.Characters = { entry }
		local profile = makeProfile()
		profile.CharacterId = entry.CharacterId
		profile.LifecycleStatus = DataConfig.ProfileStatuses.Deleting
		expectInvalid({ Roster = roster, Profile = profile }, function(value)
			return ValidationService.ValidateRosterProfileOwnership(value.Roster, value.Profile)
		end, "deleting profile", "CHARACTER_NOT_ACTIVE")
	end)

	test("reject future schema versions", function()
		local profile = makeProfile()
		profile.SchemaVersion = DataConfig.CharacterProfileSchemaVersion + 1
		expectInvalid(profile, ValidationService.ValidateCharacterProfile, "future profile schema", "UNKNOWN_FUTURE_SCHEMA")
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.SchemaVersion = DataConfig.AccountRosterSchemaVersion + 1
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "future roster schema", "UNKNOWN_FUTURE_SCHEMA")
	end)

	test("reject unsupported lifecycle statuses", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		entry.Status = "Purged"
		roster.Characters = { entry }
		expectInvalid(roster, ValidationService.ValidateAccountRoster, "bad character status", "UNSUPPORTED_LIFECYCLE_STATUS")
		local profile = makeProfile()
		profile.LifecycleStatus = "Restored"
		expectInvalid(profile, ValidationService.ValidateCharacterProfile, "bad profile status", "UNSUPPORTED_LIFECYCLE_STATUS")
	end)

	test("validation does not mutate records", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		roster.Characters = { makeEntry(1), makeEntry(2) }
		local before = deepCopy(roster)
		ValidationService.ValidateAccountRoster(roster)
		assert(deepEqual(roster, before), "roster validation changed its input")
		local profile = makeProfile()
		local profileBefore = deepCopy(profile)
		ValidationService.ValidateCharacterProfile(profile)
		assert(deepEqual(profile, profileBefore), "profile validation changed its input")
		local invalidRoster = AccountRosterSchema.CreateTemplate(12345, 100)
		invalidRoster.Characters = { makeEntry(1, "  ") }
		local invalidBefore = deepCopy(invalidRoster)
		ValidationService.ValidateAccountRoster(invalidRoster)
		assert(deepEqual(invalidRoster, invalidBefore), "failed roster validation changed its input")
		local futureProfile = makeProfile()
		futureProfile.SchemaVersion = DataConfig.CharacterProfileSchemaVersion + 1
		local futureBefore = deepCopy(futureProfile)
		ValidationService.ValidateCharacterProfile(futureProfile)
		assert(deepEqual(futureProfile, futureBefore), "future-version validation changed its input")
		local futureRoster = AccountRosterSchema.CreateTemplate(12345, 100)
		futureRoster.SchemaVersion = DataConfig.AccountRosterSchemaVersion + 1
		local futureRosterBefore = deepCopy(futureRoster)
		ValidationService.ValidateAccountRoster(futureRoster)
		assert(deepEqual(futureRoster, futureRosterBefore), "future roster validation changed its input")
		local crossRoster = AccountRosterSchema.CreateTemplate(12345, 100)
		local crossProfile = makeProfile()
		local crossRosterBefore = deepCopy(crossRoster)
		local crossProfileBefore = deepCopy(crossProfile)
		ValidationService.ValidateRosterProfileOwnership(crossRoster, crossProfile)
		assert(deepEqual(crossRoster, crossRosterBefore), "cross-record validation changed roster input")
		assert(deepEqual(crossProfile, crossProfileBefore), "cross-record validation changed profile input")
	end)

	test("successful cross-record validation does not mutate either input", function()
		local roster = AccountRosterSchema.CreateTemplate(12345, 100)
		local entry = makeEntry(1)
		roster.Characters = { entry }
		local profile = makeProfile()
		profile.CharacterId = entry.CharacterId
		local rosterBefore = deepCopy(roster)
		local profileBefore = deepCopy(profile)
		expectValid({ Roster = roster, Profile = profile }, function(value)
			return ValidationService.ValidateRosterProfileOwnership(value.Roster, value.Profile)
		end, "cross-record ownership")
		assert(deepEqual(roster, rosterBefore), "successful cross-validation changed roster input")
		assert(deepEqual(profile, profileBefore), "successful cross-validation changed profile input")
	end)

	print("[SchemaValidationTests] " .. tostring(passed) .. " tests passed")
	return passed
end
