-- Studio-only test helper (installed into the open test place as
-- ReplicatedStorage.QAClient by the dev workflow; never part of the build).
-- Drives real ProximityPrompts the way a player would: walk up, face, hold.
local QA = {}
local plr = game.Players.LocalPlayer
function QA.trigger(prompt)
	prompt:InputHoldBegin()
	task.wait(prompt.HoldDuration + 0.15)
	prompt:InputHoldEnd()
	task.wait(0.5)
end
-- teleport next to a target and face it (prompts only show when on screen)
function QA.face(from, target)
	plr.Character:PivotTo(CFrame.lookAt(from, Vector3.new(target.X, from.Y, target.Z)))
	workspace.CurrentCamera.CFrame = CFrame.lookAt(from + (from - target).Unit * 4 + Vector3.new(0, 2, 0), target)
	task.wait(0.7)
end
function QA.goto(pos) plr.Character:PivotTo(CFrame.new(pos)); task.wait(0.6) end
function QA.inter(name) return workspace.Map.Interactive[name] end
function QA.prompt(part) return part:FindFirstChildOfClass("ProximityPrompt") end
function QA.use(part, from)
	QA.face(from, part.Position)
	QA.trigger(QA.prompt(part))
end
function QA.fetchAndSit(desk)
	local pc = QA.inter("SourcePC_" .. desk)
	local from = pc.Position + Vector3.new(0, 0, (desk <= 3) and -3 or 3)
	QA.use(pc, from)
	QA.use(pc, from)
	QA.use(QA.inter("DriveDock"), Vector3.new(18.5, 3, -7.4))
	QA.use(QA.inter("SeatPrompt"), Vector3.new(15.5, 3, -6.5))
	task.wait(1)
	return plr.PlayerGui.Desktop.Enabled
end
return QA
