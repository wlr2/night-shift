--!strict
-- Who owns the mouse pointer. Walking is first person: the cursor stays
-- locked to the centre and hidden. Any UI that needs the pointer (the seated
-- desktop, an ending card with buttons) asks for it with a reason and
-- releases the same reason when done. WorkstationCamera applies the result.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local Cursor = {}

local reasons: { [string]: boolean } = {}

-- fires with the new free/locked state whenever it flips
Cursor.Changed = Signal.new() :: Signal.Signal<boolean>

function Cursor.isFree(): boolean
	return next(reasons) ~= nil
end

function Cursor.request(reason: string, free: boolean)
	local before = Cursor.isFree()
	if free then
		reasons[reason] = true
	else
		reasons[reason] = nil
	end
	local after = Cursor.isFree()
	if after ~= before then
		Cursor.Changed:Fire(after)
	end
end

function Cursor.clear()
	local before = Cursor.isFree()
	table.clear(reasons)
	if before then
		Cursor.Changed:Fire(false)
	end
end

return Cursor
