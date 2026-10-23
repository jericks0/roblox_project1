local DataConfig = require(script.Parent.Parent.Config.DataConfig)

local ValidationService = {}

local UUID_PATTERN = "^[%x][%x][%x][%x][%x][%x][%x][%x]%-[%x][%x][%x][%x]%-[%x][%x][%x][%x]%-[%x][%x][%x][%x]%-[%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x][%x]$"

local function isFiniteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isInteger(value)
	return isFiniteNumber(value) and value % 1 == 0
end

local function isUserId(value)
	-- Roblox UserIds are positive integral numeric identifiers.
	return isInteger(value) and value > 0 and value <= 9007199254740991
end

local function isNonEmptyString(value)
	return type(value) == "string" and #value > 0
end

local function isNonWhitespaceString(value)
	return isNonEmptyString(value) and string.match(value, "%S") ~= nil
end

local function isUuid(value)
	return type(value) == "string" and #value == 36 and string.match(value, UUID_PATTERN) ~= nil
end

local function newResult()
	return { IsValid = true, Errors = {} }
end

local function addError(result, path, code, message)
	result.IsValid = false
	table.insert(result.Errors, {
		Path = path,
		Code = code,
		Message = message,
	})
end

local function requireTable(result, value, path)
	if type(value) ~= "table" then
		addError(result, path, "REQUIRED_OBJECT", "Expected a table.")
		return false
	end
	return true
end

local function requireInteger(result, value, path, minimum)
	if not isInteger(value) or value < minimum then
		addError(result, path, "INVALID_INTEGER", "Expected an integer greater than or equal to " .. tostring(minimum) .. ".")
		return false
	end
	return true
end

local function requireTimestamp(result, value, path)
	if not isFiniteNumber(value) or value < 0 then
		addError(result, path, "INVALID_TIMESTAMP", "Expected a finite, non-negative timestamp.")
		return false
	end
	return true
end

local function validateArrayShape(result, value, path)
	if type(value) ~= "table" then
		addError(result, path, "REQUIRED_ARRAY", "Expected an array.")
		return false
	end
	local count = 0
	local maximumIndex = 0
	for key in pairs(value) do
		if not isInteger(key) or key < 1 then
			addError(result, path, "INVALID_ARRAY_SHAPE", "Array contains a non-positive-integer key.")
			return false
		end
		count += 1
		if key > maximumIndex then maximumIndex = key end
	end
	if count ~= maximumIndex then
		addError(result, path, "INVALID_ARRAY_SHAPE", "Array must not contain missing indices.")
		return false
	end
	return true
end

local function validateCommon(result, record, path, expectedVersion)
	requireInteger(result, record.SchemaVersion, path .. ".SchemaVersion", 1)
	if isInteger(record.SchemaVersion) and record.SchemaVersion > expectedVersion then
		addError(result, path .. ".SchemaVersion", "UNKNOWN_FUTURE_SCHEMA", "Record schema version is newer than this validator supports.")
	elseif isInteger(record.SchemaVersion) and record.SchemaVersion < expectedVersion then
		addError(result, path .. ".SchemaVersion", "UNSUPPORTED_SCHEMA", "Record schema version is not supported by this validator.")
	end
	requireInteger(result, record.Revision, path .. ".Revision", 0)
	requireTimestamp(result, record.CreatedAt, path .. ".CreatedAt")
	requireTimestamp(result, record.UpdatedAt, path .. ".UpdatedAt")
	if isFiniteNumber(record.CreatedAt) and isFiniteNumber(record.UpdatedAt) and record.UpdatedAt < record.CreatedAt then
		addError(result, path .. ".UpdatedAt", "TIMESTAMP_ORDER", "UpdatedAt must not be earlier than CreatedAt.")
	end
end

local function validateLock(result, lock, path)
	if not requireTable(result, lock, path) then
		return
	end
	if type(lock.SessionToken) ~= "string" then
		addError(result, path .. ".SessionToken", "INVALID_LOCK_TOKEN", "SessionToken must be a string.")
	end
	requireInteger(result, lock.LockGeneration, path .. ".LockGeneration", 0)
	requireTimestamp(result, lock.LeaseExpiresAt, path .. ".LeaseExpiresAt")
end

local function validateLocation(result, location, path)
	if not requireTable(result, location, path) then
		return
	end
	if not isNonEmptyString(location.RegionId) then
		addError(result, path .. ".RegionId", "INVALID_REGION_ID", "RegionId must be a non-empty string.")
	end
	if requireTable(result, location.Position, path .. ".Position") then
		for _, axis in ipairs({ "X", "Y", "Z" }) do
			if not isFiniteNumber(location.Position[axis]) then
				addError(result, path .. ".Position." .. axis, "INVALID_POSITION", "Position coordinates must be finite numbers.")
			end
		end
	end
end

local function validateOperation(result, operation, index)
	local path = "Operations[" .. tostring(index) .. "]"
	if not requireTable(result, operation, path) then
		return
	end
	if not isNonEmptyString(operation.OperationId) then
		addError(result, path .. ".OperationId", "INVALID_OPERATION_ID", "OperationId must be a non-empty string.")
	end
	local validType = false
	for _, value in pairs(DataConfig.LifecycleOperationTypes) do
		if operation.Type == value then validType = true end
	end
	if not validType then
		addError(result, path .. ".Type", "UNSUPPORTED_OPERATION_TYPE", "Lifecycle operation type is not supported.")
	end
	local validStatus = false
	for _, value in pairs(DataConfig.LifecycleOperationStatuses) do
		if operation.Status == value then validStatus = true end
	end
	if not validStatus then
		addError(result, path .. ".Status", "UNSUPPORTED_LIFECYCLE_STATUS", "Lifecycle operation status is not supported.")
	end
	if not isUuid(operation.CharacterId) then
		addError(result, path .. ".CharacterId", "INVALID_CHARACTER_ID", "CharacterId must be a canonical UUID.")
	end
	if operation.Type == DataConfig.LifecycleOperationTypes.Create then
		if requireTable(result, operation.CreationIdentity, path .. ".CreationIdentity") then
			for _, field in ipairs({ "Name", "Race", "Class" }) do
				if not isNonWhitespaceString(operation.CreationIdentity[field]) then
					addError(result, path .. ".CreationIdentity." .. field, "INVALID_CREATION_IDENTITY", field .. " must be a non-whitespace string.")
				end
			end
		end
		validateLocation(result, operation.InitialLocation, path .. ".InitialLocation")
	end
	requireTimestamp(result, operation.CreatedAt, path .. ".CreatedAt")
	requireTimestamp(result, operation.UpdatedAt, path .. ".UpdatedAt")
end

local function validateCharacterEntry(result, entry, index, deleted)
	local path = (deleted and "DeletedCharacters[" or "Characters[") .. tostring(index) .. "]"
	if not requireTable(result, entry, path) then
		return
	end
	if not isUuid(entry.CharacterId) then
		addError(result, path .. ".CharacterId", "INVALID_CHARACTER_ID", "CharacterId must be a canonical UUID.")
	end
	if not isNonWhitespaceString(entry.Name) then
		addError(result, path .. ".Name", "INVALID_NAME", "Name must contain a non-whitespace character.")
	end
	if not isNonEmptyString(entry.Race) then
		addError(result, path .. ".Race", "INVALID_RACE", "Race must be a non-empty string.")
	end
	if not isNonEmptyString(entry.Class) then
		addError(result, path .. ".Class", "INVALID_CLASS", "Class must be a non-empty string.")
	end
	local allowed = deleted and DataConfig.DeletedCharacterStatuses or DataConfig.CharacterStatuses
	local validStatus = false
	for _, value in pairs(allowed) do
		if entry.Status == value then validStatus = true end
	end
	if not validStatus then
		addError(result, path .. ".Status", "UNSUPPORTED_LIFECYCLE_STATUS", "Character lifecycle status is not supported in this collection.")
	end
	if deleted then
		requireTimestamp(result, entry.DeletedAt, path .. ".DeletedAt")
		requireTimestamp(result, entry.PurgeAfter, path .. ".PurgeAfter")
	end
end

function ValidationService.ValidateAccountRoster(record)
	local result = newResult()
	if not requireTable(result, record, "AccountRoster") then
		return result
	end

	if not isUserId(record.UserId) then
		addError(result, "UserId", "INVALID_USER_ID", "UserId must be a positive safe integer.")
	end
	validateCommon(result, record, "AccountRoster", DataConfig.AccountRosterSchemaVersion)
	validateLock(result, record.Lock, "Lock")

	local characterArrayValid = validateArrayShape(result, record.Characters, "Characters")
	local seenIds = {}
	local committedActiveIds = {}
	if characterArrayValid then
		if #record.Characters > DataConfig.MaxCharacterSlots then
			addError(result, "Characters", "TOO_MANY_CHARACTERS", "Roster cannot contain more than " .. tostring(DataConfig.MaxCharacterSlots) .. " active character slots.")
		end
		local seenNames = {}
		for index, entry in ipairs(record.Characters) do
			validateCharacterEntry(result, entry, index, false)
			if type(entry) == "table" then
				-- Exact string comparison is used; name normalization is not specified by CORE-02.
				if isNonEmptyString(entry.Name) then
					if seenNames[entry.Name] then
						addError(result, "Characters[" .. tostring(index) .. "].Name", "DUPLICATE_CHARACTER_NAME", "Character names must be unique within an account roster.")
					else
						seenNames[entry.Name] = true
					end
				end
				if isUuid(entry.CharacterId) then
					if seenIds[entry.CharacterId] then
						addError(result, "Characters[" .. tostring(index) .. "].CharacterId", "DUPLICATE_CHARACTER_ID", "CharacterId cannot appear more than once in a roster.")
					else
						seenIds[entry.CharacterId] = "Active"
						committedActiveIds[entry.CharacterId] = true
					end
				end
			end
		end
	end

	if validateArrayShape(result, record.DeletedCharacters, "DeletedCharacters") then
		for index, entry in ipairs(record.DeletedCharacters) do
			validateCharacterEntry(result, entry, index, true)
			if type(entry) == "table" and isUuid(entry.CharacterId) then
				if seenIds[entry.CharacterId] then
					addError(result, "DeletedCharacters[" .. tostring(index) .. "].CharacterId", "DUPLICATE_CHARACTER_ID", "CharacterId cannot identify both an active and deleted roster entry.")
				else
					seenIds[entry.CharacterId] = "Deleted"
				end
			end
		end
	end

	local operationArrayValid = validateArrayShape(result, record.Operations, "Operations")
	local seenOperationIds = {}
	local pendingCreateIds = {}
	local pendingOperationCharacterIds = {}
	if operationArrayValid then
		for index, operation in ipairs(record.Operations) do
			validateOperation(result, operation, index)
			if type(operation) == "table" then
				if isNonEmptyString(operation.OperationId) then
					if seenOperationIds[operation.OperationId] then
						addError(result, "Operations[" .. tostring(index) .. "].OperationId", "DUPLICATE_OPERATION_ID", "OperationId must be unique within the roster.")
					else
						seenOperationIds[operation.OperationId] = true
					end
				end
				if operation.Type == DataConfig.LifecycleOperationTypes.Create and operation.Status == DataConfig.LifecycleOperationStatuses.Pending and isUuid(operation.CharacterId) then
					if pendingCreateIds[operation.CharacterId] then
						addError(result, "Operations[" .. tostring(index) .. "].CharacterId", "DUPLICATE_PENDING_CHARACTER_ID", "Only one pending creation may reserve a CharacterId.")
					else
						pendingCreateIds[operation.CharacterId] = true
					end
					if seenIds[operation.CharacterId] == "Deleted" then
						addError(result, "Operations[" .. tostring(index) .. "].CharacterId", "CHARACTER_ID_COLLISION", "A pending creation cannot reuse a deleted CharacterId.")
					elseif seenIds[operation.CharacterId] == nil then
						seenIds[operation.CharacterId] = "PendingCreate"
					end
				end
				if operation.Status == DataConfig.LifecycleOperationStatuses.Pending and isUuid(operation.CharacterId) then
					if pendingOperationCharacterIds[operation.CharacterId] then
						addError(result, "Operations[" .. tostring(index) .. "].CharacterId", "DUPLICATE_PENDING_CHARACTER_ID", "Only one pending lifecycle operation may target a CharacterId.")
					else
						pendingOperationCharacterIds[operation.CharacterId] = true
					end
				end
			end
		end
	end
	if characterArrayValid and operationArrayValid then
		local reservedSlots = #record.Characters
		local countedReservations = {}
		for _, operation in ipairs(record.Operations) do
			if type(operation) == "table" and operation.Type == DataConfig.LifecycleOperationTypes.Create and operation.Status == DataConfig.LifecycleOperationStatuses.Pending and not committedActiveIds[operation.CharacterId] then
				if not countedReservations[operation.CharacterId] then
					reservedSlots += 1
					countedReservations[operation.CharacterId] = true
				end
			end
		end
		if reservedSlots > DataConfig.MaxCharacterSlots then
			addError(result, "Operations", "TOO_MANY_CHARACTER_SLOTS", "Active characters and pending creation reservations cannot exceed " .. tostring(DataConfig.MaxCharacterSlots) .. ".")
		end
	end
	return result
end

-- Cross-record checks remain separate from individual schema validation.
function ValidationService.ValidateRosterProfileOwnership(roster, profile, characterId)
	local result = newResult()
	local rosterResult = ValidationService.ValidateAccountRoster(roster)
	local profileResult = ValidationService.ValidateCharacterProfile(profile)
	for _, issue in ipairs(rosterResult.Errors) do
		addError(result, "Roster." .. issue.Path, issue.Code, issue.Message)
	end
	for _, issue in ipairs(profileResult.Errors) do
		addError(result, "Profile." .. issue.Path, issue.Code, issue.Message)
	end
	if not rosterResult.IsValid or not profileResult.IsValid then
		return result
	end
	local selectedId = characterId or profile.CharacterId
	if roster.UserId ~= profile.OwnerUserId then
		addError(result, "Profile.OwnerUserId", "OWNER_MISMATCH", "Roster and profile owners do not match.")
	end
	if selectedId ~= profile.CharacterId then
		addError(result, "Profile.CharacterId", "CHARACTER_ID_MISMATCH", "Selected CharacterId does not match the profile.")
	end
	local activeEntry = nil
	for _, entry in ipairs(roster.Characters) do
		if entry.CharacterId == selectedId then activeEntry = entry break end
	end
	local deletedEntry = nil
	for _, entry in ipairs(roster.DeletedCharacters) do
		if entry.CharacterId == selectedId then deletedEntry = entry break end
	end
	if deletedEntry then
		addError(result, "Roster.DeletedCharacters", "DELETED_CHARACTER_NOT_ADMISSIBLE", "Deleted characters cannot enter normal gameplay.")
	elseif not activeEntry then
		addError(result, "Roster.Characters", "CHARACTER_NOT_IN_ROSTER", "Profile character is not an active roster member.")
	elseif activeEntry.Status ~= DataConfig.CharacterStatuses.Active then
		addError(result, "Roster.Characters", "CHARACTER_NOT_ACTIVE", "Only active roster characters may enter normal gameplay.")
	end
	if profile.LifecycleStatus ~= DataConfig.ProfileStatuses.Active then
		addError(result, "Profile.LifecycleStatus", "CHARACTER_NOT_ACTIVE", "Only active profiles may enter normal gameplay.")
	end
	return result
end

function ValidationService.ValidateCharacterProfile(record)
	local result = newResult()
	if not requireTable(result, record, "CharacterProfile") then
		return result
	end

	if not isUuid(record.CharacterId) then
		addError(result, "CharacterId", "INVALID_CHARACTER_ID", "CharacterId must be a canonical UUID.")
	end
	if not isUserId(record.OwnerUserId) then
		addError(result, "OwnerUserId", "INVALID_USER_ID", "OwnerUserId must be a positive safe integer.")
	end
	validateCommon(result, record, "CharacterProfile", DataConfig.CharacterProfileSchemaVersion)
	local profileStatusValid = false
	for _, value in pairs(DataConfig.ProfileStatuses) do
		if record.LifecycleStatus == value then profileStatusValid = true end
	end
	if not profileStatusValid then
		addError(result, "LifecycleStatus", "UNSUPPORTED_LIFECYCLE_STATUS", "Character profile lifecycle status is not supported.")
	end

	if not requireTable(result, record.Identity, "Identity") then
		-- Remaining sections are checked independently to report all errors.
	else
		for _, field in ipairs({ "Name", "Race", "Class" }) do
			if not isNonWhitespaceString(record.Identity[field]) then
				addError(result, "Identity." .. field, "INVALID_IDENTITY_FIELD", field .. " must contain a non-whitespace character.")
			end
		end
	end

	if requireTable(result, record.Progression, "Progression") then
		requireInteger(result, record.Progression.Level, "Progression.Level", 1)
		requireInteger(result, record.Progression.Experience, "Progression.Experience", 0)
	end

	if requireTable(result, record.Location, "Location") then
		validateLocation(result, record.Location, "Location")
	end
	validateLock(result, record.Lock, "Lock")
	return result
end

function ValidationService.IsUuid(value)
	return isUuid(value)
end

function ValidationService.IsUserId(value)
	return isUserId(value)
end

return ValidationService
