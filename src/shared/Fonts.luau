--!strict
-- Font families shared by server SurfaceGuis (dock, breakers, monitors) and
-- the client UI kit. See docs/ART_DIRECTION.md for where each one belongs.
--   PIXEL   Silkscreen    short retro labels, titles, status, keycaps
--   BODY    Ubuntu        sentences: dialogue, instructions, buttons
--   MONO    Inconsolata   listings, checksums, tables
--   LETTER  Merriweather  recovered memos and story fragments only

local Fonts = {}

-- Roblox's own FontFamily asset (type 73) with Regular 400 and Bold 700 faces.
Fonts.SILKSCREEN = "rbxassetid://12187371840"
-- built-in families, resolved through Enum.Font so the paths are always valid
Fonts.UBUNTU = Font.fromEnum(Enum.Font.Ubuntu).Family
Fonts.INCONSOLATA = Font.fromEnum(Enum.Font.Code).Family
Fonts.MERRIWEATHER = Font.fromEnum(Enum.Font.Merriweather).Family

Fonts.PIXEL = Font.new(Fonts.SILKSCREEN, Enum.FontWeight.Regular)
Fonts.PIXEL_BOLD = Font.new(Fonts.SILKSCREEN, Enum.FontWeight.Bold)
Fonts.BODY = Font.new(Fonts.UBUNTU, Enum.FontWeight.Regular)
Fonts.BODY_BOLD = Font.new(Fonts.UBUNTU, Enum.FontWeight.Bold)
Fonts.MONO = Font.new(Fonts.INCONSOLATA, Enum.FontWeight.Regular)
Fonts.LETTER = Font.new(Fonts.MERRIWEATHER, Enum.FontWeight.Regular)

return Fonts
