---@class Deque<T>
---@field first integer
---@field last integer
---@field [integer] T
local Deque = {}
Deque.__index = Deque

---@generic T
---@return Deque<T>
function Deque.new()
	return setmetatable({ first = 0, last = -1 }, Deque)
end

---@generic T
---@param value T
function Deque:push_right(value)
	local last = self.last + 1
	self.last = last
	self[last] = value
end

---@generic T
---@return T
function Deque:pop_left()
	local first = self.first
	if first > self.last then
		return nil
	end
	local value = self[first]
	self[first] = nil
	self.first = first + 1
	return value
end

---@generic T
---@return T
function Deque:peek_right()
	local last = self.last
	if self.first > last then
		return nil
	end
	return self[last]
end

---@generic T
---@return T
function Deque:peek_left()
	local first = self.first
	if first > self.last then
		return nil
	end
	return self[first]
end

return Deque
