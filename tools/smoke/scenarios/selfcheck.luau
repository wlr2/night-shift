--!nocheck
-- 0. Harness self-check: loads a tiny deliberately broken snippet through the
-- same loader/environment the game uses and confirms each error class is
-- caught with a src/ file:line. If this fails, the other results are not
-- trustworthy. The snippet's own errors are kept out of the other scenarios.

local luau = require("@lune/luau")

local SNIPPET = [[
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local gui = Instance.new("ScreenGui")
gui.Name = "SmokeSelfCheck"
gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
local r = {}
r.badProp = select(2, pcall(function() local l = Instance.new("TextLabel"); l.TextSzie = 14 end))
r.badType = select(2, pcall(function() local l = Instance.new("TextLabel"); l.TextSize = "large" end))
r.readOnly = select(2, pcall(function() local l = Instance.new("TextLabel"); l.AbsoluteSize = Vector2.new(1, 1) end))
r.badEnum = select(2, pcall(function() local l = Instance.new("TextLabel"); l.TextXAlignment = Enum.TextYAlignment.Top end))
r.badRead = select(2, pcall(function() local f = Instance.new("Frame"); return f.Text end))
r.badTween = select(2, pcall(function() TweenService:Create(Instance.new("Frame"), TweenInfo.new(1), { TextTransparency = 1 }) end))
r.badClass = select(2, pcall(function() return Instance.new("Fram") end))
r.badParent = select(2, pcall(function() local f = Instance.new("Frame"); f.Parent = "PlayerGui" end))
r.coerced = pcall(function() local l = Instance.new("TextLabel"); l.TextXAlignment = "Left"; l.Text = 5; l.TextSize = "18" end)
local b = Instance.new("TextButton")
b.Name = "Boom"
b.Size = UDim2.fromOffset(100, 30)
b.Parent = gui
b.Activated:Connect(function()
	local missing = nil
	missing.Field = 1
end)
task.spawn(function()
	gui:WaitForChild("NeverCreated")
end)
return { results = r, gui = gui, button = b }
]]

return function(H)
	local Report, Rt, Loader, World = H.Report, H.Rt, H.Loader, H.World
	Report.begin("0", "harness self-check")
	local outer = Report.current
	local scratch = { checks = {}, errors = {}, warns = {}, prints = {}, info = {} }
	Report.current = scratch

	local fake = Rt.newInstance("ModuleScript", { name = "SelfCheck" })
	local fn = luau.load(SNIPPET, { debugName = "=src/__smoke_selfcheck__.luau", environment = Loader.envFor(fake), injectGlobals = false })
	local out = nil
	H.Sched.spawn(function()
		out = fn()
	end)
	H.step(2)
	if out then
		local btn = Rt.rec(out.button)
		H.click(btn)
	end
	H.run(6)
	Report.current = outer

	local r = out and out.results or {}
	local function has(v, needle)
		return type(v) == "string" and string.find(v, needle, 1, true) ~= nil
	end
	local function siteOk(v)
		return type(v) == "string" and string.find(v, "src/__smoke_selfcheck__.luau:", 1, true) ~= nil
	end
	Report.check(out ~= nil, "snippet ran through the game loader")
	Report.check(has(r.badProp, "TextSzie is not a valid member") and siteOk(r.badProp), "unknown property write throws with file:line", tostring(r.badProp))
	Report.check(has(r.badType, "Unable to assign property TextSize") and siteOk(r.badType), "wrong value type throws", tostring(r.badType))
	Report.check(has(r.readOnly, "read only") and siteOk(r.readOnly), "read-only property write throws", tostring(r.readOnly))
	Report.check(has(r.badEnum, "TextXAlignment"), "wrong enum type throws", tostring(r.badEnum))
	Report.check(has(r.badRead, "Text is not a valid member of Frame"), "unknown property read throws", tostring(r.badRead))
	Report.check(has(r.badTween, "TweenService:Create"), "tween of a missing property throws", tostring(r.badTween))
	Report.check(has(r.badClass, "Unable to create an Instance"), "Instance.new of an unknown class throws", tostring(r.badClass))
	Report.check(has(r.badParent, "Parent"), "Parent = non-Instance throws", tostring(r.badParent))
	Report.check(r.coerced == true, "Roblox-legal coercions are accepted (enum by name, number -> Text, numeric string -> TextSize)")
	local handlerErr = nil
	for _, e in scratch.errors do
		if string.find(e.msg, "attempt to index nil", 1, true) and e.site and string.find(e.site, "__smoke_selfcheck__", 1, true) then
			handlerErr = e
		end
	end
	Report.check(handlerErr ~= nil, "error inside a GuiButton.Activated handler is captured with file:line", if handlerErr then handlerErr.site else "not captured")
	local yield = nil
	for i = #Rt.yieldReports, 1, -1 do
		local y = Rt.yieldReports[i]
		if string.find(y.what, "NeverCreated", 1, true) then
			yield = y
			table.remove(Rt.yieldReports, i)
		end
	end
	Report.check(yield ~= nil and string.find(yield.site, "__smoke_selfcheck__", 1, true) ~= nil, "WaitForChild on a missing child is reported as an infinite yield with file:line", if yield then yield.site else "not reported")
	if out and out.gui then
		Rt.destroy(Rt.rec(out.gui))
	end
	H.step(2)
	local _ = World
end
