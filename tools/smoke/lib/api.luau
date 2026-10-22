--!nocheck
-- Class/member index built from tools/smoke/api_members.json (a compact copy
-- of the public Roblox API dump, regenerated with tools/smoke/gen_api.py).
-- Used to answer: is `X` a property, event or method of this class (with
-- inheritance), what type does the property take, and is it writable from a
-- LocalScript.

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local Api = {}

local raw: { [string]: any } = {}
Api.version = nil

function Api.load(path: string)
	local decoded = serde.decode("json", fs.readFile(path))
	raw = decoded.classes
	Api.version = decoded.version
end

export type Member = { kind: string, name: string, type: string?, cat: string?, flags: number, owner: string }

local resolved: { [string]: { [string]: Member } } = {}
local chains: { [string]: { string } } = {}

function Api.exists(className: string): boolean
	return raw[className] ~= nil
end

function Api.chain(className: string): { string }
	local c = chains[className]
	if c then
		return c
	end
	c = {}
	local name = className
	while name and raw[name] do
		table.insert(c, name)
		local sup = raw[name].s
		if sup == "<<<ROOT>>>" or sup == nil or sup == "" then
			break
		end
		name = sup
	end
	chains[className] = c
	return c
end

local isACache: { [string]: { [string]: boolean } } = {}
function Api.isA(className: string, ancestor: string): boolean
	if className == ancestor then
		return true
	end
	local c = isACache[className]
	if not c then
		c = {}
		isACache[className] = c
	end
	local v = c[ancestor]
	if v == nil then
		v = false
		for _, n in Api.chain(className) do
			if n == ancestor then
				v = true
				break
			end
		end
		c[ancestor] = v
	end
	return v
end

function Api.members(className: string): { [string]: Member }
	local m = resolved[className]
	if m then
		return m
	end
	m = {}
	local chain = Api.chain(className)
	-- walk root -> leaf so subclasses override
	for i = #chain, 1, -1 do
		local cname = chain[i]
		local c = raw[cname]
		if c.p then
			for pname, info in c.p do
				m[pname] = { kind = "p", name = pname, type = info[1], cat = info[2], flags = info[3], owner = cname }
			end
		end
		if c.e then
			for _, ename in c.e do
				m[ename] = { kind = "e", name = ename, flags = 0, owner = cname }
			end
		end
		if c.m then
			for _, fname in c.m do
				m[fname] = { kind = "m", name = fname, flags = 0, owner = cname }
			end
		end
		if c.c then
			for _, cbname in c.c do
				m[cbname] = { kind = "c", name = cbname, flags = 0, owner = cname }
			end
		end
	end
	resolved[className] = m
	return m
end

function Api.member(className: string, name: string): Member?
	return Api.members(className)[name]
end

function Api.creatable(className: string): boolean
	local c = raw[className]
	return c ~= nil and bit32.band(c.f or 0, 3) == 0
end

function Api.isService(className: string): boolean
	local c = raw[className]
	return c ~= nil and bit32.band(c.f or 0, 2) ~= 0
end

return Api
