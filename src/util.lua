local M = {}
---@param value MetadataValue|nil
---@return string|nil
M.first_tag = function(value)
	if value == nil or value:first() == "" then
		return nil
	end
	return value:first()
end

return M
