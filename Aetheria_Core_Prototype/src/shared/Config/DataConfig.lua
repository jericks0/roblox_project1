-- Schema constants shared by data templates and validation.
-- Increment a record version only when its serialized contract changes.
local DataConfig = {
	AccountRosterSchemaVersion = 1,
	CharacterProfileSchemaVersion = 1,
	MaxCharacterSlots = 3,

	CharacterStatuses = {
		Active = "Active",
		Deleting = "Deleting",
	},

	DeletedCharacterStatuses = {
		Deleted = "Deleted",
	},

	ProfileStatuses = {
		Active = "Active",
		Deleting = "Deleting",
		Deleted = "Deleted",
	},

	LifecycleOperationTypes = {
		Create = "Create",
		Delete = "Delete",
		Restore = "Restore",
		Purge = "Purge",
	},

	LifecycleOperationStatuses = {
		Pending = "Pending",
		Complete = "Complete",
	},
}

return DataConfig
