--!nocheck
-- a. Boot: run src/client/init.client.luau (controllers init then start in
-- its own order), spawn the character, finish the map, and check that every
-- controller loaded, the loading card cleared and nothing is stuck waiting.

return function(H)
	local Report, World, Rt, Loader = H.Report, H.World, H.Rt, H.Loader
	Report.begin("a", "boot all controllers")

	local client = H.clientRoot
	if not Report.check(client ~= nil, "client LocalScript mounted from default.project.json") then
		return
	end
	Loader.runScript(client)
	H.step(5)
	World.spawnCharacter()
	H.step(10)

	local started = false
	for _, p in Report.current.prints do
		if string.find(p.text, "client started", 1, true) then
			started = true
		end
	end
	Report.check(started, "init.client.luau reached the end (prints 'client started')")

	local controllers = client:FindFirstChild("Controllers")
	local missing = {}
	local count = 0
	if controllers then
		for _, m in controllers:GetChildren() do
			if m:IsA("ModuleScript") then
				count += 1
				local c = Loader.loaded[m]
				if not c then
					table.insert(missing, m.Name .. (if Loader.failed[m] then " (error: " .. Loader.failed[m] .. ")" else " (never required)"))
				end
			end
		end
	end
	Report.check(#missing == 0, string.format("all %d controller modules required", count), if #missing > 0 then table.concat(missing, "\n") else nil)

	-- server finishes the map; clients bake art and drop the loading card
	World.workspace:SetAttribute("MapReady", true)
	H.Server.pushState()
	H.run(4)
	local artReady = World.workspace:GetAttribute("ClientArtReady") == true
	Report.check(artReady, "ArtController flags workspace.ClientArtReady after MapReady", if World.opts.editables then nil else "(running with --no-editables)")
	local st = World.editableStats
	Report.info(string.format("art: %d EditableImages, %d EditableMeshes (%d verts, %d tris), %d MeshParts", st.images, st.meshes, st.vertices, st.triangles, st.meshParts))

	H.run(3)
	-- loading card: no full-screen opaque frame should still cover the HUD
	local covering = nil
	for _, sg in H.screenGuis() do
		Rt.eachDescendant(sg, function(d)
			local L = d.layout
			if covering == nil and L and L.visible and d.class == "Frame" and (d.proxy.BackgroundTransparency or 1) < 0.05 and L.w >= H.Layout.viewport.w - 1 and L.h >= H.Layout.viewport.h - 60 then
				covering = d
			end
		end)
	end
	Report.check(covering == nil, "no opaque full-screen frame left after the loading card (7 s after MapReady)", if covering then Rt.fullName(covering) else nil)

	local yields = {}
	for _, y in Rt.yieldReports do
		table.insert(yields, y.what .. " at " .. y.site)
	end
	Report.check(#yields == 0, "no thread stuck in WaitForChild", if #yields > 0 then table.concat(yields, "\n") else nil)

	local guis = {}
	for _, sg in H.screenGuis() do
		table.insert(guis, string.format("%s(%s, order %s)", sg.name, if sg.proxy.Enabled then "on" else "off", tostring(sg.proxy.DisplayOrder)))
	end
	Report.info("PlayerGui: " .. table.concat(guis, ", "))
	Report.info("after boot: " .. H.fmtCam(H.camState()))
end
