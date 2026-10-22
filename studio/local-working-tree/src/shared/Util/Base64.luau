--!strict
-- Minimal Base64 -> buffer decoder used to unpack generated art data.

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local LUT: { number } = table.create(256, 0)
for i = 1, 64 do
	LUT[string.byte(ALPHABET, i) + 1] = i - 1
end

local Base64 = {}

function Base64.decode(s: string): buffer
	local len = #s
	local pad = 0
	if len > 0 and string.byte(s, len) == 61 then
		pad += 1
	end
	if len > 1 and string.byte(s, len - 1) == 61 then
		pad += 1
	end
	local outLen = (len // 4) * 3 - pad
	local out = buffer.create(math.max(outLen, 0))
	local o = 0
	for i = 1, len, 4 do
		local a, b, c, d = string.byte(s, i, i + 3)
		local n = LUT[a + 1] * 262144 + LUT[b + 1] * 4096 + LUT[(c or 61) + 1] * 64 + LUT[(d or 61) + 1]
		if o < outLen then
			buffer.writeu8(out, o, n // 65536)
		end
		if o + 1 < outLen then
			buffer.writeu8(out, o + 1, (n // 256) % 256)
		end
		if o + 2 < outLen then
			buffer.writeu8(out, o + 2, n % 256)
		end
		o += 3
	end
	return out
end

return Base64
