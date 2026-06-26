-- =============================================================================
-- AsepriteDmi — Folhas BYOND/DMI + metadados DMI em um único script
-- =============================================================================
--
-- Este arquivo unifica duas ferramentas que antes eram scripts separados:
--
--   1) Geração/leitura de folhas (spritesheets) no formato BYOND, organizando
--      frames por direção em layers (Sul, Norte, Leste, Oeste).
--      [origem: Aseprite2DmiSheet.lua]
--
--   2) Importação/exportação de arquivos .dmi preservando os metadados do BYOND
--      (o chunk zTXt "Description" do PNG), além de utilitários de espelhamento
--      e limpeza de frames.
--      [origem: dmi-editor1.6.lua]
--
-- -----------------------------------------------------------------------------
-- COMO O BYOND ORGANIZA OS TILES DE UMA FOLHA (ex.: 4 frames, 4 direções):
--
--   Índice: 0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
--   Frame:  F1  F1  F1  F1  F2  F2  F2  F2  F3  F3  F3  F3  F4  F4  F4  F4
--   Dir:    S   N   L   O   S   N   L   O   S   N   L   O   S   N   L   O
--
-- Para cada frame, as 4 direções aparecem consecutivas (S, N, L, O).
-- O "jump" entre o mesmo frame em direções diferentes é o número de direções.
--
-- Para animações com 1 direção e 4 frames:
--
--   Índice: 0   1   2   3
--   Frame:  F1  F2  F3  F4
--   Dir:    S   S   S   S
--
-- -----------------------------------------------------------------------------
-- FORMATO DOS METADADOS DMI (chunk zTXt "Description", texto após inflate):
--
--   # BEGIN DMI
--   version = 4.0
--       width = 32
--       height = 32
--   state = ""
--       dirs = 4
--       frames = 4
--       delay = 2,2,2,2
--       movement = 1
--   state = "running"
--       dirs = 4
--       frames = 1
--   ...
--   # END DMI
--
-- Cada `state = "..."` é um "icon state". A ordem dos states na folha é a mesma
-- ordem em que aparecem aqui; cada state ocupa (dirs * frames) tiles.
-- IMPORTANTE: o texto vem comprimido (zlib/DEFLATE). O Lua do Aseprite não tem
-- zlib embutido, então hoje preservamos apenas o chunk bruto (para round-trip de
-- export). Ler os NOMES dos states exige um inflate em Lua puro (ver SKILLS.md).
-- =============================================================================

-- =============================================================================
-- ARMAZENAMENTO GLOBAL
-- =============================================================================
local rawZtxtChunk = nil -- chunk zTXt bruto (length+type+data+CRC) do último DMI
local parsedStates = nil -- lista de icon states já parseada (quando disponível)
local debugMode = false

-- =============================================================================
-- DEBUG / ARQUIVOS
-- =============================================================================

--- Exibe uma mensagem apenas quando o modo debug está ligado.
local function dbgMsg(msg)
	if debugMode then
		app.alert("DEBUG: " .. msg)
	end
end

--- Converte bytes em string hexadecimal (para inspeção de metadados).
local function bytesToHex(bytes, maxLen)
	local result = ""
	maxLen = maxLen or #bytes
	for i = 1, math.min(maxLen, #bytes) do
		result = result .. string.format("%02X ", string.byte(bytes, i))
		if i % 16 == 0 then
			result = result .. "\n"
		end
	end
	return result
end

--- Lê metadados de um arquivo binário, retornando nil se vazio/inexistente.
local function loadMetadataFromFile(filename)
	local file = io.open(filename, "rb")
	if not file then
		return nil
	end
	local data = file:read("*all")
	file:close()
	if #data > 0 then
		dbgMsg("Carregado " .. #data .. " bytes de " .. filename)
		return data
	end
	return nil
end

--- Grava metadados em um arquivo binário.
local function saveMetadataToFile(data, filename)
	local file = io.open(filename, "wb")
	if not file then
		return false
	end
	file:write(data)
	file:close()
	dbgMsg("Gravado " .. #data .. " bytes em " .. filename)
	return true
end

--- Alternativa segura ao os.remove: trunca o arquivo em vez de removê-lo.
local function safeRemoveFile(filename)
	local file = io.open(filename, "w")
	if file then
		file:close()
		dbgMsg("Arquivo esvaziado: " .. filename)
		return true
	end
	return false
end

-- =============================================================================
-- INFLATE (DEFLATE / zlib em Lua puro — RFC 1950/1951)
-- =============================================================================
-- O Lua do Aseprite não tem zlib. O metadado DMI (chunk zTXt) é comprimido em
-- zlib, então precisamos descomprimir na mão para ler os nomes dos icon states.
-- Requer operadores bit a bit (Lua 5.3+, presentes no Aseprite).
-- Implementação validada byte a byte contra o zlib do Python (ver SKILLS.md).

local _byte, _char, _concat = string.byte, string.char, table.concat

local BitReader = {}
BitReader.__index = BitReader

local function newBitReader(data, startPos)
	return setmetatable({ data = data, pos = startPos or 1, bitBuf = 0, bitCnt = 0 }, BitReader)
end

function BitReader:bits(n)
	local buf, cnt = self.bitBuf, self.bitCnt
	while cnt < n do
		local b = _byte(self.data, self.pos) or 0
		self.pos = self.pos + 1
		buf = buf | (b << cnt)
		cnt = cnt + 8
	end
	local val = buf & ((1 << n) - 1)
	self.bitBuf = buf >> n
	self.bitCnt = cnt - n
	return val
end

function BitReader:alignByte()
	self.bitBuf = 0
	self.bitCnt = 0
end

local function buildHuffman(lengths, n)
	local counts = {}
	for i = 0, 15 do
		counts[i] = 0
	end
	for i = 1, n do
		counts[lengths[i]] = counts[lengths[i]] + 1
	end
	counts[0] = 0

	local offsets = { [1] = 0 }
	for i = 1, 15 do
		offsets[i + 1] = offsets[i] + counts[i]
	end

	local symbols = {}
	for i = 1, n do
		local len = lengths[i]
		if len ~= 0 then
			symbols[offsets[len]] = i - 1
			offsets[len] = offsets[len] + 1
		end
	end
	return { counts = counts, symbols = symbols }
end

local function decodeSymbol(br, tree)
	local counts, symbols = tree.counts, tree.symbols
	local code, first, index = 0, 0, 0
	for len = 1, 15 do
		code = code | br:bits(1)
		local count = counts[len]
		if code - first < count then
			return symbols[index + (code - first)]
		end
		index = index + count
		first = (first + count) << 1
		code = code << 1
	end
	error("inflate: código Huffman inválido")
end

local INF_LENGTH_BASE = {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}
local INF_LENGTH_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local INF_DIST_BASE = {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}
local INF_DIST_EXTRA =
	{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local INF_CODELEN_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

local fixedLitTree, fixedDistTree
local function getFixedTrees()
	if not fixedLitTree then
		local litLen = {}
		for i = 1, 144 do
			litLen[i] = 8
		end
		for i = 145, 256 do
			litLen[i] = 9
		end
		for i = 257, 280 do
			litLen[i] = 7
		end
		for i = 281, 288 do
			litLen[i] = 8
		end
		fixedLitTree = buildHuffman(litLen, 288)
		local distLen = {}
		for i = 1, 30 do
			distLen[i] = 5
		end
		fixedDistTree = buildHuffman(distLen, 30)
	end
	return fixedLitTree, fixedDistTree
end

local function inflateRaw(data, startPos)
	local br = newBitReader(data, startPos)
	local outBytes, outLen = {}, 0

	repeat
		local bfinal = br:bits(1)
		local btype = br:bits(2)

		if btype == 0 then
			br:alignByte()
			local len = _byte(data, br.pos) + (_byte(data, br.pos + 1) << 8)
			br.pos = br.pos + 4
			for _ = 1, len do
				outLen = outLen + 1
				outBytes[outLen] = _byte(data, br.pos)
				br.pos = br.pos + 1
			end
		elseif btype == 1 or btype == 2 then
			local litTree, distTree
			if btype == 1 then
				litTree, distTree = getFixedTrees()
			else
				local hlit = br:bits(5) + 257
				local hdist = br:bits(5) + 1
				local hclen = br:bits(4) + 4

				local clLengths = {}
				for i = 1, 19 do
					clLengths[i] = 0
				end
				for i = 1, hclen do
					clLengths[INF_CODELEN_ORDER[i] + 1] = br:bits(3)
				end
				local clTree = buildHuffman(clLengths, 19)

				local allLengths, total, n = {}, hlit + hdist, 0
				while n < total do
					local sym = decodeSymbol(br, clTree)
					if sym < 16 then
						n = n + 1
						allLengths[n] = sym
					elseif sym == 16 then
						local rep, prev = br:bits(2) + 3, allLengths[n]
						for _ = 1, rep do
							n = n + 1
							allLengths[n] = prev
						end
					elseif sym == 17 then
						local rep = br:bits(3) + 3
						for _ = 1, rep do
							n = n + 1
							allLengths[n] = 0
						end
					elseif sym == 18 then
						local rep = br:bits(7) + 11
						for _ = 1, rep do
							n = n + 1
							allLengths[n] = 0
						end
					end
				end

				local litLen = {}
				for i = 1, hlit do
					litLen[i] = allLengths[i]
				end
				local distLen = {}
				for i = 1, hdist do
					distLen[i] = allLengths[hlit + i]
				end
				litTree = buildHuffman(litLen, hlit)
				distTree = buildHuffman(distLen, hdist)
			end

			while true do
				local sym = decodeSymbol(br, litTree)
				if sym == 256 then
					break
				elseif sym < 256 then
					outLen = outLen + 1
					outBytes[outLen] = sym
				else
					sym = sym - 256
					local length = INF_LENGTH_BASE[sym] + br:bits(INF_LENGTH_EXTRA[sym])
					local dsym = decodeSymbol(br, distTree) + 1
					local dist = INF_DIST_BASE[dsym] + br:bits(INF_DIST_EXTRA[dsym])
					local from = outLen - dist
					for _ = 1, length do
						from = from + 1
						outLen = outLen + 1
						outBytes[outLen] = outBytes[from]
					end
				end
			end
		else
			error("inflate: BTYPE reservado (3) inválido")
		end
	until bfinal == 1

	local parts, CHUNK = {}, 4096
	for i = 1, outLen, CHUNK do
		local j = math.min(i + CHUNK - 1, outLen)
		parts[#parts + 1] = _char(table.unpack(outBytes, i, j))
	end
	return _concat(parts)
end

--- Descomprime um fluxo zlib (RFC 1950): header de 2 bytes + DEFLATE + Adler-32.
local function inflateZlib(data)
	local cmf, flg = _byte(data, 1), _byte(data, 2)
	if not cmf or not flg then
		error("inflateZlib: dados muito curtos")
	end
	if (cmf & 0x0F) ~= 8 then
		error("inflateZlib: método de compressão não é DEFLATE")
	end
	local startPos = 3
	if (flg & 0x20) ~= 0 then
		startPos = startPos + 4 -- pula DICTID (FDICT)
	end
	return inflateRaw(data, startPos)
end

-- =============================================================================
-- PARSE DE METADADOS DMI
-- =============================================================================

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Faz o parse do texto (já descomprimido) do bloco "Description" de um DMI.
--- Retorna uma lista ordenada de icon states:
---   { { name=string, dirs=number, frames=number, movement=bool, index=number }, ... }
--- A ordem reflete a ordem dos tiles na folha. Cada state ocupa dirs*frames tiles.
--- @param text string  Texto do metadado DMI já inflado.
--- @return table       Lista de states (pode ser vazia se nada casar).
local function parseDmiMetadataText(text)
	local states = {}
	local current = nil
	for rawLine in (text .. "\n"):gmatch("(.-)\n") do
		local line = trim(rawLine)
		local stateName = line:match('^state%s*=%s*"(.*)"%s*$')
		if stateName ~= nil then
			current = { name = stateName, dirs = 1, frames = 1, movement = false, index = #states + 1 }
			table.insert(states, current)
		elseif current then
			local key, value = line:match("^(%w+)%s*=%s*(.+)$")
			if key == "dirs" then
				current.dirs = tonumber(value) or current.dirs
			elseif key == "frames" then
				current.frames = tonumber(value) or current.frames
			elseif key == "movement" then
				current.movement = tonumber(value) == 1
			end
		end
	end
	return states
end

--- Resumo legível de uma lista de states (para diálogos de status).
local function summarizeStates(states)
	local lines = {}
	for _, s in ipairs(states) do
		local label = (s.name == "" and '"" (sem nome)') or ('"' .. s.name .. '"')
		local mv = s.movement and " (movement)" or ""
		table.insert(lines, string.format("%d) %s — %d dir × %d frames%s", s.index, label, s.dirs, s.frames, mv))
	end
	return table.concat(lines, "\n")
end

--- Reconstrói os icon states a partir de um chunk zTXt bruto (length+type+data+CRC).
--- Usado ao recarregar o metadado salvo em disco. Retorna lista (pode ser vazia).
local function parseStatesFromRawChunk(rawChunk)
	-- Layout: [4 bytes length][4 bytes "zTXt"][data: keyword \0 method comp][4 bytes CRC]
	if not rawChunk or #rawChunk < 12 then
		return {}
	end
	local b1, b2, b3, b4 = string.byte(rawChunk, 1, 4)
	local chunkLength = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
	local chunkData = rawChunk:sub(9, 8 + chunkLength)
	local nul = chunkData:find("\0", 1, true)
	if not nul then
		return {}
	end
	local ok, text = pcall(inflateZlib, chunkData:sub(nul + 2))
	if not ok then
		return {}
	end
	return parseDmiMetadataText(text)
end

-- =============================================================================
-- UTILITÁRIOS GERAIS DE FOLHA
-- =============================================================================

--- Encontra a primeira cel com imagem no sprite (percorre todas as layers).
local function findFirstCel(sprite)
	for _, layer in ipairs(sprite.layers) do
		local cel = layer:cel(1)
		if cel then
			return cel
		end
	end
	return nil
end

--- Extrai um recorte retangular de uma imagem maior para um buffer próprio.
local function extractTile(sourceImage, x, y, fw, fh, colorMode)
	local img = Image(fw, fh, colorMode)
	img:drawImage(sourceImage, Point(-x, -y))
	return img
end

--- Compõe todas as cels visíveis de uma lista de layers num único buffer.
local function composeLayers(layerList, frameIndex, w, h, colorMode)
	local buffer = Image(w, h, colorMode)
	buffer:clear()
	for _, layer in ipairs(layerList) do
		local cel = layer:cel(frameIndex)
		if cel then
			buffer:drawImage(cel.image, cel.position)
		end
	end
	return buffer
end

local DIR_NAMES = { "Sul", "Norte", "Leste", "Oeste" }
local DIR_OFFSETS = { Sul = 0, Norte = 1, Leste = 2, Oeste = 3 }

local DIR_ALIASES = {
	s = "Sul",
	sul = "Sul",
	south = "Sul",
	baixo = "Sul",
	n = "Norte",
	norte = "Norte",
	north = "Norte",
	cima = "Norte",
	l = "Leste",
	le = "Leste",
	leste = "Leste",
	e = "Leste",
	east = "Leste",
	direita = "Leste",
	o = "Oeste",
	oe = "Oeste",
	oeste = "Oeste",
	w = "Oeste",
	west = "Oeste",
	esquerda = "Oeste",
}

local function normalizeDirName(text)
	return DIR_ALIASES[trim(text):lower()]
end

local function frameNumber(frame)
	if type(frame) == "number" then
		return frame
	end
	return frame.frameNumber
end

local function sortedTags(sprite)
	local tags = {}
	for _, tag in ipairs(sprite.tags) do
		table.insert(tags, tag)
	end
	table.sort(tags, function(a, b)
		return frameNumber(a.fromFrame) < frameNumber(b.fromFrame)
	end)
	return tags
end

--- Lê convenções no nome da tag para decidir o layout de exportação.
---   "andar"                  -> 4 direções
---   "meditar [1]"            -> 1 direção, sempre layer Sul
---   "chute dirs=1"           -> 1 direção, sempre layer Sul
---   "chute [1:Sul,Leste,...]"-> 1 direção, escolhendo a layer por frame
local function parseTagExportConfig(tagName)
	local lower = tagName:lower()
	local config = { dirCount = 4, sourceDirs = nil, invalidDirs = {} }

	local orderSpec = tagName:match("%[1%s*:%s*([^%]]+)%]")
		or tagName:match("%[1dir%s*:%s*([^%]]+)%]")
		or tagName:match("%[dirs%s*=%s*1%s*:%s*([^%]]+)%]")

	if
		orderSpec
		or lower:find("%[1%]")
		or lower:find("%[1dir%]")
		or lower:find("dirs%s*=%s*1")
		or lower:find("dir%s*=%s*1")
		or lower:find("1%s*dir")
	then
		config.dirCount = 1
	end

	if orderSpec then
		config.sourceDirs = {}
		for token in orderSpec:gmatch("[^,%s]+") do
			local dir = normalizeDirName(token)
			if dir then
				table.insert(config.sourceDirs, dir)
			else
				table.insert(config.invalidDirs, token)
			end
		end
	end

	return config
end

-- =============================================================================
-- UTILITÁRIOS DE LAYERS
-- =============================================================================

--- Percorre recursivamente as layers, construindo rótulos (com hierarquia de
--- grupos) e um mapa rótulo -> Layer.
local function collectLayerOptions(parent, prefix, layerOptions, layerRefs)
	for _, layer in ipairs(parent.layers) do
		local label = prefix .. layer.name
		table.insert(layerOptions, label)
		layerRefs[label] = layer
		if layer.isGroup then
			collectLayerOptions(layer, label .. "/", layerOptions, layerRefs)
		end
	end
end

--- Expande um nó (grupo ou folha) para a lista plana de layers de imagem.
local function expandToImageLayers(node)
	local result = {}
	local function recurse(n)
		if n.isGroup then
			for _, child in ipairs(n.layers) do
				recurse(child)
			end
		else
			table.insert(result, n)
		end
	end
	if node then
		recurse(node)
	end
	return result
end

-- =============================================================================
-- EXPORTAR FOLHA BYOND
-- =============================================================================

--- Abre o diálogo de exportação e gera a spritesheet BYOND como um novo sprite.
local function showExportDialog()
	local spr = app.activeSprite
	if not spr then
		return app.alert("Nenhum sprite aberto!")
	end

	local layerOptions = {}
	local layerRefs = {}
	collectLayerOptions(spr, "", layerOptions, layerRefs)

	if #layerOptions == 0 then
		return app.alert("Não há layers/grupos para listar.")
	end

	local dlg = Dialog("Exportar SpriteSheet")
	dlg:combobox({ id = "layerSul", label = "Layer Sul:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerNorte", label = "Layer Norte:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerLeste", label = "Layer Leste:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerOeste", label = "Layer Oeste:", option = layerOptions[1], options = layerOptions })
	dlg:number({ id = "columns", label = "Colunas:", text = "17" })
	dlg:check({
		id = "useTags",
		label = "Exportar por tags:",
		text = "Usar tags para misturar 4 dirs e 1 dir",
		selected = #spr.tags > 0,
	})
	dlg:button({ id = "ok", text = "Exportar", focus = true })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	local data = dlg.data
	if not data.ok then
		return
	end

	local dirOffsets = DIR_OFFSETS
	local selectedLayers = {
		Sul = expandToImageLayers(layerRefs[data.layerSul]),
		Norte = expandToImageLayers(layerRefs[data.layerNorte]),
		Leste = expandToImageLayers(layerRefs[data.layerLeste]),
		Oeste = expandToImageLayers(layerRefs[data.layerOeste]),
	}

	local totalCols = math.max(1, tonumber(data.columns) or 17)
	local frameCount = #spr.frames
	if frameCount == 0 then
		return app.alert("Sprite não possui frames.")
	end

	local w, h = spr.width, spr.height
	local jump = 4
	local useTags = data.useTags == true
	local exportTiles = {}

	if useTags then
		local tags = sortedTags(spr)
		if #tags == 0 then
			return app.alert("Exportação por tags ativada, mas o sprite não possui tags.")
		end

		for _, tag in ipairs(tags) do
			local config = parseTagExportConfig(tag.name)
			local fromFrame = frameNumber(tag.fromFrame)
			local toFrame = frameNumber(tag.toFrame)

			if #config.invalidDirs > 0 then
				return app.alert(
					"Tag com direção inválida: " .. tag.name .. "\nUse S, N, L, O ou Sul, Norte, Leste, Oeste."
				)
			end

			if fromFrame > toFrame then
				fromFrame, toFrame = toFrame, fromFrame
			end

			if config.dirCount == 1 then
				for f = fromFrame, toFrame do
					local dir = "Sul"
					if config.sourceDirs and #config.sourceDirs > 0 then
						local index = ((f - fromFrame) % #config.sourceDirs) + 1
						dir = config.sourceDirs[index]
					end
					table.insert(exportTiles, { dir = dir, frame = f })
				end
			else
				for f = fromFrame, toFrame do
					for _, dir in ipairs(DIR_NAMES) do
						table.insert(exportTiles, { dir = dir, frame = f })
					end
				end
			end
		end
	else
		for f = 1, frameCount do
			for _, dir in ipairs(DIR_NAMES) do
				table.insert(exportTiles, { dir = dir, frame = f })
			end
		end
	end

	if #exportTiles == 0 then
		return app.alert("Nenhum tile foi gerado para exportação.")
	end

	local totalRows = math.floor((#exportTiles - 1) / totalCols) + 1
	local sheet = Image(w * totalCols, h * totalRows, spr.colorMode)
	sheet:clear()

	for i, tile in ipairs(exportTiles) do
		local posIndex
		if useTags then
			posIndex = i - 1
		else
			posIndex = dirOffsets[tile.dir] + (tile.frame - 1) * jump
		end

		local col = posIndex % totalCols
		local row = math.floor(posIndex / totalCols)
		local dx = col * w
		local dy = row * h

		local tileImg = composeLayers(selectedLayers[tile.dir], tile.frame, w, h, spr.colorMode)
		sheet:drawImage(tileImg, Point(dx, dy))
	end

	local newSpr = Sprite(sheet.width, sheet.height, spr.colorMode)
	newSpr:newCel(newSpr.layers[1], 1, sheet, Point(0, 0))
	app.activeSprite = newSpr
end

-- =============================================================================
-- IMPORTAR FOLHA BYOND (divide em layers por direção)
-- =============================================================================

--- Lê a folha do sprite ativo e a distribui em layers por direção.
local function importByondSheet()
	local spr = app.activeSprite
	if not spr then
		return app.alert("Nenhum sprite aberto.")
	end

	local sheetCel = findFirstCel(spr)
	if not sheetCel then
		return app.alert("Nenhuma imagem encontrada no sprite.")
	end
	local sheet = sheetCel.image

	local dlg = Dialog("Importar SpriteSheet BYOND")
	dlg:number({ id = "fw", label = "Largura do Frame (px):", text = "32" })
	dlg:number({ id = "fh", label = "Altura do Frame (px):", text = "32" })
	dlg:combobox({
		id = "dirMode",
		label = "Direções:",
		option = "4 (S, N, L, O)",
		options = { "1 (só Sul)", "4 (S, N, L, O)" },
	})
	dlg:button({ id = "ok", text = "Importar", focus = true })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	if not dlg.data.ok then
		return
	end

	local fw = tonumber(dlg.data.fw)
	local fh = tonumber(dlg.data.fh)
	if not fw or not fh or fw <= 0 or fh <= 0 then
		return app.alert("Dimensões de frame inválidas.")
	end

	local cols = sheet.width / fw
	local rows = sheet.height / fh
	if cols % 1 ~= 0 or rows % 1 ~= 0 then
		return app.alert(
			"O tamanho do frame ("
				.. fw
				.. "x"
				.. fh
				.. ") não divide\n"
				.. "a folha ("
				.. sheet.width
				.. "x"
				.. sheet.height
				.. ") exatamente."
		)
	end

	cols = math.floor(cols)
	rows = math.floor(rows)
	local totalCells = cols * rows

	local dirCount = (dlg.data.dirMode == "1 (só Sul)") and 1 or 4
	if totalCells % dirCount ~= 0 then
		return app.alert(
			"Total de tiles ("
				.. totalCells
				.. ") não é divisível por "
				.. dirCount
				.. " direção(ões).\nVerifique o modo selecionado."
		)
	end

	local framesCount = totalCells / dirCount
	if framesCount == 0 then
		return app.alert("A folha não contém frames válidos.")
	end

	local dirNames = (dirCount == 1) and { "Sul" } or { "Sul", "Norte", "Leste", "Oeste" }

	local newSpr = Sprite(fw, fh, spr.colorMode)
	while #newSpr.frames < framesCount do
		newSpr:newFrame()
	end

	local dirLayers = {}
	for _, name in ipairs(dirNames) do
		local layer = newSpr:newLayer()
		layer.name = name
		table.insert(dirLayers, layer)
	end

	for _, layer in ipairs(newSpr.layers) do
		if layer.name == "Layer 1" or layer.name == "" then
			local hasCel = false
			for f = 1, #newSpr.frames do
				if layer:cel(f) then
					hasCel = true
					break
				end
			end
			if not hasCel then
				newSpr:deleteLayer(layer)
				break
			end
		end
	end

	for i = 0, framesCount - 1 do
		for d = 0, dirCount - 1 do
			local posIndex = d + i * dirCount
			local col = posIndex % cols
			local row = math.floor(posIndex / cols)
			local x = col * fw
			local y = row * fh
			local tileImg = extractTile(sheet, x, y, fw, fh, spr.colorMode)
			newSpr:newCel(dirLayers[d + 1], i + 1, tileImg, Point(0, 0))
		end
	end

	app.activeSprite = newSpr
	app.refresh()
	app.alert("Importação concluída!\n" .. framesCount .. " frame(s) × " .. dirCount .. " direção(ões).")
end

-- =============================================================================
-- IMPORTAR/EXPORTAR .DMI (preserva metadados do BYOND)
-- =============================================================================

--- Localiza o chunk zTXt num arquivo DMI/PNG e:
---   * guarda o chunk bruto em rawZtxtChunk (para round-trip no export);
---   * descomprime e parseia os icon states em parsedStates (etapa 2).
--- Retorna true se encontrou metadados.
local function extractZtxtChunk(fileData)
	local ztxtPos = fileData:find("zTXt", 1, true)
	if not ztxtPos or ztxtPos < 5 then
		return false
	end

	local lengthStart = ztxtPos - 4
	local b1 = string.byte(fileData, lengthStart)
	local b2 = string.byte(fileData, lengthStart + 1)
	local b3 = string.byte(fileData, lengthStart + 2)
	local b4 = string.byte(fileData, lengthStart + 3)
	local chunkLength = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4

	dbgMsg("zTXt em " .. ztxtPos .. " com tamanho " .. chunkLength)
	rawZtxtChunk = fileData:sub(lengthStart, ztxtPos + 3 + chunkLength + 4)
	saveMetadataToFile(rawZtxtChunk, "dmi_metadata.bin")
	dbgMsg("Extraído " .. #rawZtxtChunk .. " bytes de chunk bruto")

	-- Campo de dados do chunk: keyword \0 method(1 byte) dados-comprimidos
	local chunkData = fileData:sub(ztxtPos + 4, ztxtPos + 3 + chunkLength)
	local nul = chunkData:find("\0", 1, true)
	if nul then
		local compressed = chunkData:sub(nul + 2) -- pula \0 e o byte de método
		local ok, text = pcall(inflateZlib, compressed)
		if ok then
			parsedStates = parseDmiMetadataText(text)
			dbgMsg("Parseados " .. #parsedStates .. " icon states")
		else
			parsedStates = nil
			dbgMsg("Falha ao descomprimir metadado: " .. tostring(text))
		end
	end

	return true
end

--- Importa um arquivo DMI: guarda o metadado bruto e abre a folha no Aseprite.
local function importDMI()
	local dlg = Dialog("Importar arquivo DMI")
	dlg:file({ id = "file", label = "Selecione o DMI:", filetypes = { "dmi", "png" }, open = true })
	dlg:button({ id = "ok", text = "OK" })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	if not (dlg.data.ok and dlg.data.file ~= "") then
		return
	end

	local filename = dlg.data.file
	dbgMsg("Abrindo: " .. filename)

	local file = io.open(filename, "rb")
	if not file then
		return app.alert("Não foi possível abrir: " .. filename)
	end
	local fileData = file:read("*all")
	file:close()
	dbgMsg("Tamanho: " .. #fileData .. " bytes")

	if not extractZtxtChunk(fileData) then
		app.alert("Nenhum chunk zTXt encontrado no arquivo.")
	elseif parsedStates and #parsedStates > 0 then
		app.alert("DMI importado.\n")
	end

	app.command.OpenFile({ filename = filename })
end

--- Exporta o sprite atual como DMI, reinserindo o chunk zTXt preservado.
local function exportDMI()
	if not app.activeSprite then
		return app.alert("Nenhum sprite aberto para exportar.")
	end
	if not rawZtxtChunk then
		return app.alert("Nenhum metadado DMI carregado. Importe um DMI primeiro.")
	end

	local dlg = Dialog("Exportar arquivo DMI")
	dlg:number({ id = "width", label = "Largura:", text = "32", decimals = 0 })
	dlg:number({ id = "height", label = "Altura:", text = "32", decimals = 0 })
	dlg:number({ id = "directions", label = "Direções:", text = "4", decimals = 0 })
	dlg:file({ id = "file", label = "Salvar DMI como:", filetypes = { "dmi" }, save = true })
	dlg:button({ id = "ok", text = "OK" })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	if not (dlg.data.ok and dlg.data.file ~= "") then
		return
	end

	local outputPath = dlg.data.file
	dbgMsg("Exportando para: " .. outputPath)

	local tempPngFile = "temp_dmi.png"
	app.command.SaveFile({ filename = tempPngFile, filename_format = tempPngFile })

	local file = io.open(tempPngFile, "rb")
	if not file then
		return app.alert("Não foi possível criar o PNG temporário em: " .. tempPngFile)
	end
	local pngData = file:read("*all")
	file:close()
	dbgMsg("PNG temp: " .. #pngData .. " bytes")

	local idatPos = pngData:find("IDAT", 1, true)
	if not idatPos then
		return app.alert("Não foi possível encontrar o chunk IDAT no PNG.")
	end
	idatPos = idatPos - 4

	local outputData = pngData:sub(1, idatPos - 1) .. rawZtxtChunk .. pngData:sub(idatPos)

	local outFile = io.open(outputPath, "wb")
	if not outFile then
		return app.alert("Não foi possível criar o arquivo: " .. outputPath)
	end
	outFile:write(outputData)
	outFile:close()

	safeRemoveFile(tempPngFile)
	app.alert("DMI exportado com sucesso para: " .. outputPath)
end

-- =============================================================================
-- OPERAÇÕES DE SPRITE (espelhar / limpar direções)
-- =============================================================================

--- Espelha os tiles Leste para gerar os tiles Oeste (padrão S,N,L,O).
local function mirrorEastToWest()
	if not app.activeSprite then
		return app.alert("Nenhum sprite aberto para processar")
	end

	local sprite = app.activeSprite
	local width = sprite.width
	local height = sprite.height

	local dlg = Dialog("Tamanho do Frame")
	dlg:number({ id = "cellWidth", label = "Largura do Frame:", text = "32", decimals = 0 })
	dlg:number({ id = "cellHeight", label = "Altura do Frame:", text = "32", decimals = 0 })
	dlg:button({ id = "ok", text = "OK" })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()
	if not dlg.data.ok then
		return
	end

	local cellWidth = dlg.data.cellWidth
	local cellHeight = dlg.data.cellHeight
	if width % cellWidth ~= 0 or height % cellHeight ~= 0 then
		return app.alert("As dimensões do sprite devem ser múltiplas do tamanho do frame")
	end

	local columns = width / cellWidth
	local rows = height / cellHeight
	local totalCells = columns * rows
	local totalProcessed = 0

	app.transaction(function()
		local frameNum = app.activeFrame.frameNumber
		local eastIndex = 2
		local westIndex = 3

		local fullImage = Image(sprite.width, sprite.height, sprite.colorMode)
		fullImage:clear(app.pixelColor.rgba(0, 0, 0, 0))
		fullImage:drawSprite(sprite, frameNum)
		local modified = false

		for row = 0, rows - 1 do
			for col = 0, columns - 1 do
				local cellIndex = row * columns + col
				local direction = cellIndex % 4
				if direction == eastIndex then
					local eastX = col * cellWidth
					local eastY = row * cellHeight
					local nextCellIndex = cellIndex + 1
					if nextCellIndex < totalCells and nextCellIndex % 4 == westIndex then
						local nextCol = nextCellIndex % columns
						local nextRow = math.floor(nextCellIndex / columns)
						local westX = nextCol * cellWidth
						local westY = nextRow * cellHeight

						local eastImage = Image(cellWidth, cellHeight, sprite.colorMode)
						eastImage:clear(app.pixelColor.rgba(0, 0, 0, 0))
						for py = 0, cellHeight - 1 do
							for px = 0, cellWidth - 1 do
								eastImage:putPixel(px, py, fullImage:getPixel(eastX + px, eastY + py))
							end
						end
						for py = 0, cellHeight - 1 do
							for px = 0, cellWidth - 1 do
								fullImage:putPixel(westX + px, westY + py, app.pixelColor.rgba(0, 0, 0, 0))
							end
						end
						for py = 0, cellHeight - 1 do
							for px = 0, cellWidth - 1 do
								fullImage:putPixel(westX + (cellWidth - 1 - px), westY + py, eastImage:getPixel(px, py))
							end
						end
						totalProcessed = totalProcessed + 1
						modified = true
					end
				end
			end
		end

		if modified then
			for _, layer in ipairs(sprite.layers) do
				if layer.isVisible then
					local wasEditable = layer.isEditable
					if not wasEditable then
						layer.isEditable = true
					end
					sprite:newCel(layer, frameNum, fullImage:clone(), Point(0, 0))
					if not wasEditable then
						layer.isEditable = false
					end
					break
				end
			end
			app.refresh()
		end
	end)

	if totalProcessed > 0 then
		app.alert("Espelhados " .. totalProcessed .. " sprites Leste para Oeste")
	else
		app.alert("Nenhum sprite Leste encontrado para processar")
	end
end

--- Remove (limpa) todos os tiles Oeste de um frame (padrão S,N,L,O).
local function deleteWestFrames()
	if not app.activeSprite then
		return app.alert("Nenhum sprite aberto para processar")
	end

	local sprite = app.activeSprite
	local width = sprite.width
	local height = sprite.height

	local dlg = Dialog("Tamanho do Frame")
	dlg:number({ id = "cellWidth", label = "Largura do Frame:", text = "32", decimals = 0 })
	dlg:number({ id = "cellHeight", label = "Altura do Frame:", text = "32", decimals = 0 })
	dlg:button({ id = "ok", text = "OK" })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()
	if not dlg.data.ok then
		return
	end

	local cellWidth = dlg.data.cellWidth
	local cellHeight = dlg.data.cellHeight
	if width % cellWidth ~= 0 or height % cellHeight ~= 0 then
		return app.alert("As dimensões do sprite devem ser múltiplas do tamanho do frame")
	end

	local columns = width / cellWidth
	local rows = height / cellHeight
	local totalDeleted = 0

	app.transaction(function()
		local frameNum = app.activeFrame.frameNumber
		local westIndex = 3
		local fullImage = Image(sprite.width, sprite.height, sprite.colorMode)
		fullImage:clear(app.pixelColor.rgba(0, 0, 0, 0))
		fullImage:drawSprite(sprite, frameNum)
		local modified = false

		for row = 0, rows - 1 do
			for col = 0, columns - 1 do
				local cellIndex = row * columns + col
				if cellIndex % 4 == westIndex then
					local westX = col * cellWidth
					local westY = row * cellHeight
					for py = 0, cellHeight - 1 do
						for px = 0, cellWidth - 1 do
							fullImage:putPixel(westX + px, westY + py, app.pixelColor.rgba(0, 0, 0, 0))
						end
					end
					totalDeleted = totalDeleted + 1
					modified = true
				end
			end
		end

		if modified then
			for _, layer in ipairs(sprite.layers) do
				if layer.isVisible then
					local wasEditable = layer.isEditable
					if not wasEditable then
						layer.isEditable = true
					end
					sprite:newCel(layer, frameNum, fullImage:clone(), Point(0, 0))
					if not wasEditable then
						layer.isEditable = false
					end
					break
				end
			end
			app.refresh()
		end
	end)

	if totalDeleted > 0 then
		app.alert("Removidos " .. totalDeleted .. " frames Oeste")
	else
		app.alert("Nenhum frame Oeste encontrado para remover")
	end
end

-- =============================================================================
-- MAPEAMENTO CANÔNICO state -> tag + IMPORT NAS TAGS (etapa 2)
-- =============================================================================
-- Casar icon state com tag por NOME não funciona (Attack->KICK, crashingleg->
-- "C leg"). Mas a base completa do personagem tem os states na MESMA ordem das
-- tags, com nº de frames batendo posição a posição. Então derivamos uma tabela
-- canônica chave(nome,frames,movement) -> nome da tag, alinhando a base completa
-- com o .aseprite mestre. Depois, qualquer DMI (completo ou reduzido) é mapeado
-- consultando essa tabela.

local DIR_TO_GROUP = { Sul = "South", Norte = "North", Leste = "East", Oeste = "West" }
local MAPPING_FILE = "dmi_mapping.lua"

-- canonicalMapping: { [chave] = nome da tag }
local canonicalMapping = nil

--- Chave de identidade única de um icon state (nome + frames + movement).
local function stateKey(name, frames, movement)
	return name .. "\31" .. tostring(frames) .. "\31" .. (movement and "1" or "0")
end

--- Serializa e grava a tabela de mapeamento como um arquivo Lua.
local function saveCanonicalMapping(map)
	local parts = { "return {\n" }
	for k, v in pairs(map) do
		parts[#parts + 1] = string.format("\t[%q] = %q,\n", k, v)
	end
	parts[#parts + 1] = "}\n"
	return saveMetadataToFile(table.concat(parts), MAPPING_FILE)
end

--- Carrega a tabela de mapeamento salva (ou nil).
local function loadCanonicalMapping()
	local data = loadMetadataFromFile(MAPPING_FILE)
	if not data then
		return nil
	end
	local chunk = load(data, "dmi_mapping", "t", {})
	if not chunk then
		return nil
	end
	local ok, tbl = pcall(chunk)
	if ok and type(tbl) == "table" then
		return tbl
	end
	return nil
end

--- Deriva a tabela canônica alinhando os states (base completa) com as tags do
--- sprite mestre, por POSIÇÃO. Valida que o nº de frames bate em cada índice.
--- @return table|nil mapping, string|nil erro
local function deriveCanonicalMapping(states, sprite)
	local tags = sortedTags(sprite)
	if #states ~= #tags then
		return nil,
			string.format(
				"A base tem %d icon states, mas o sprite tem %d tags.\n"
					.. "A derivação exige a base COMPLETA alinhada com o .aseprite mestre\n"
					.. "(mesmo número e mesma ordem).",
				#states,
				#tags
			)
	end

	local map = {}
	local mismatches = {}
	for i = 1, #states do
		local s = states[i]
		local t = tags[i]
		local tagFrames = math.abs(frameNumber(t.toFrame) - frameNumber(t.fromFrame)) + 1
		if tagFrames ~= s.frames then
			mismatches[#mismatches + 1] = string.format(
				'  pos %d: state "%s" (%d frames) ≠ tag "%s" (%d frames)',
				i,
				s.name,
				s.frames,
				t.name,
				tagFrames
			)
		end
		map[stateKey(s.name, s.frames, s.movement)] = t.name
	end

	if #mismatches > 0 then
		return nil, "O alinhamento posição-a-posição não bate:\n" .. table.concat(mismatches, "\n")
	end
	return map
end

--- Encontra uma layer/grupo filho direto por nome.
local function findChildByName(parent, name)
	for _, l in ipairs(parent.layers) do
		if l.name == name then
			return l
		end
	end
	return nil
end

--- Garante a layer destino <Grupo da direção>/Edit/<nome da direção>, criando-a
--- se necessário. Retorna layer ou (nil, erro).
local function ensureTargetLayer(sprite, dir)
	local groupName = DIR_TO_GROUP[dir]
	local group = findChildByName(sprite, groupName)
	if not group or not group.isGroup then
		return nil, "Grupo de direção não encontrado: " .. tostring(groupName)
	end
	local edit = findChildByName(group, "Edit")
	if not edit or not edit.isGroup then
		return nil, "Subgrupo 'Edit' não encontrado em: " .. groupName
	end
	local layer = findChildByName(edit, dir)
	if not layer then
		layer = sprite:newLayer()
		layer.name = dir
		layer.parent = edit -- move para dentro do subgrupo Edit
	end
	return layer
end

local function findTagByName(sprite, name)
	for _, t in ipairs(sprite.tags) do
		if t.name == name then
			return t
		end
	end
	return nil
end

--- Lê apenas a imagem (folha achatada) de um arquivo DMI/PNG, sem deixar o
--- sprite aberto. Preserva o sprite mestre como ativo.
local function loadSheetImage(dmiPath)
	local master = app.activeSprite
	app.command.OpenFile({ filename = dmiPath })
	local dmiSprite = app.activeSprite
	if dmiSprite == master then
		return nil, "Não foi possível abrir a folha do DMI."
	end
	local cel = findFirstCel(dmiSprite)
	local img = cel and cel.image:clone() or nil
	local sw, sh = dmiSprite.width, dmiSprite.height
	dmiSprite:close()
	app.activeSprite = master
	if not img then
		return nil, "A folha do DMI está vazia."
	end
	return img, sw, sh
end

--- Importa um DMI no sprite mestre aberto, posicionando os frames de cada icon
--- state no intervalo da tag correspondente (via tabela canônica).
local function importDmiIntoTags()
	local master = app.activeSprite
	if not master then
		return app.alert("Abra o .aseprite mestre antes de importar.")
	end
	if #master.tags == 0 then
		return app.alert("O sprite mestre não possui tags.")
	end
	if not canonicalMapping then
		canonicalMapping = loadCanonicalMapping()
	end
	if not canonicalMapping then
		return app.alert("Sem mapeamento canônico. Use 'Aprender mapeamento' com a base completa primeiro.")
	end

	local dlg = Dialog("Importar DMI nas tags")
	dlg:file({ id = "file", label = "Arquivo DMI:", filetypes = { "dmi", "png" }, open = true })
	dlg:number({ id = "fw", label = "Largura do Frame:", text = "32", decimals = 0 })
	dlg:number({ id = "fh", label = "Altura do Frame:", text = "32", decimals = 0 })
	dlg:button({ id = "ok", text = "Importar", focus = true })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()
	if not (dlg.data.ok and dlg.data.file ~= "") then
		return
	end

	local fw = tonumber(dlg.data.fw)
	local fh = tonumber(dlg.data.fh)
	if not fw or not fh or fw <= 0 or fh <= 0 then
		return app.alert("Dimensões de frame inválidas.")
	end

	-- Lê metadados (states) do arquivo escolhido.
	local f = io.open(dlg.data.file, "rb")
	if not f then
		return app.alert("Não foi possível abrir: " .. dlg.data.file)
	end
	local fileData = f:read("*all")
	f:close()
	if not extractZtxtChunk(fileData) or not parsedStates or #parsedStates == 0 then
		return app.alert("Não foi possível ler os icon states do DMI.")
	end
	local states = parsedStates

	-- Carrega a folha (imagem achatada) e calcula colunas.
	local img, sw = loadSheetImage(dlg.data.file)
	if not img then
		return app.alert(sw) -- sw carrega a mensagem de erro
	end
	if sw % fw ~= 0 then
		return app.alert("A largura da folha (" .. sw .. ") não é múltipla de " .. fw .. ".")
	end
	local cols = math.floor(sw / fw)

	-- Posiciona os tiles.
	local placed, skipped, problems = 0, {}, {}
	app.transaction(function()
		local stateStart = 0
		for _, s in ipairs(states) do
			local tagName = canonicalMapping[stateKey(s.name, s.frames, s.movement)]
			local tag = tagName and findTagByName(master, tagName)
			if not tag then
				skipped[#skipped + 1] = (s.name == "" and "(sem nome)" or s.name)
			else
				local fromFrame = math.min(frameNumber(tag.fromFrame), frameNumber(tag.toFrame))
				local config = parseTagExportConfig(tag.name)
				for fi = 0, s.frames - 1 do
					if s.dirs >= 4 then
						for d = 0, 3 do
							local gi = stateStart + fi * s.dirs + d
							local col = gi % cols
							local row = math.floor(gi / cols)
							local tileImg = extractTile(img, col * fw, row * fh, fw, fh, master.colorMode)
							local dir = DIR_NAMES[d + 1]
							local layer, err = ensureTargetLayer(master, dir)
							if layer then
								master:newCel(layer, fromFrame + fi, tileImg, Point(0, 0))
								placed = placed + 1
							else
								problems[err] = true
							end
						end
					else
						-- 1 direção: a direção de cada frame vem da ordem [1:...] da tag.
						local dir = "Sul"
						if config.sourceDirs and #config.sourceDirs > 0 then
							dir = config.sourceDirs[(fi % #config.sourceDirs) + 1]
						end
						local gi = stateStart + fi
						local col = gi % cols
						local row = math.floor(gi / cols)
						local tileImg = extractTile(img, col * fw, row * fh, fw, fh, master.colorMode)
						local layer, err = ensureTargetLayer(master, dir)
						if layer then
							master:newCel(layer, fromFrame + fi, tileImg, Point(0, 0))
							placed = placed + 1
						else
							problems[err] = true
						end
					end
				end
			end
			stateStart = stateStart + s.dirs * s.frames
		end
	end)

	app.refresh()
	local msg = placed .. " tile(s) posicionados em " .. (#states - #skipped) .. " state(s)."
	if #skipped > 0 then
		msg = msg .. "\n\nSem tag correspondente (ignorados):\n  " .. table.concat(skipped, ", ")
	end
	for err in pairs(problems) do
		msg = msg .. "\n\n⚠ " .. err
	end
	app.alert({ title = "Importação nas tags", text = msg })
end

--- Aprende a tabela canônica: usa a base completa (DMI) + o .aseprite mestre.
local function learnCanonicalMapping()
	local master = app.activeSprite
	if not master then
		return app.alert("Abra o .aseprite mestre (com as tags) antes de aprender o mapeamento.")
	end
	if #master.tags == 0 then
		return app.alert("O sprite mestre não possui tags.")
	end

	local dlg = Dialog("Aprender mapeamento (base completa)")
	dlg:label({ text = "Escolha o DMI da BASE COMPLETA (todos os icon states)." })
	dlg:label({ text = "O mestre aberto deve ter as tags na mesma ordem." })
	dlg:file({ id = "file", label = "DMI base:", filetypes = { "dmi", "png" }, open = true })
	dlg:button({ id = "ok", text = "Aprender", focus = true })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()
	if not (dlg.data.ok and dlg.data.file ~= "") then
		return
	end

	local f = io.open(dlg.data.file, "rb")
	if not f then
		return app.alert("Não foi possível abrir: " .. dlg.data.file)
	end
	local fileData = f:read("*all")
	f:close()
	if not extractZtxtChunk(fileData) or not parsedStates or #parsedStates == 0 then
		return app.alert("Não foi possível ler os icon states do DMI base.")
	end

	local map, err = deriveCanonicalMapping(parsedStates, master)
	if not map then
		return app.alert({ title = "Falha ao aprender", text = err })
	end
	canonicalMapping = map
	saveCanonicalMapping(map)
	app.alert("Mapeamento aprendido e salvo: " .. #parsedStates .. " states ↔ tags.")
end

-- =============================================================================
-- MENU PRINCIPAL UNIFICADO
-- =============================================================================

local function showMainDialog()
	if rawZtxtChunk == nil then
		rawZtxtChunk = loadMetadataFromFile("dmi_metadata.bin")
	end
	if rawZtxtChunk and not parsedStates then
		local states = parseStatesFromRawChunk(rawZtxtChunk)
		if #states > 0 then
			parsedStates = states
		end
	end
	if canonicalMapping == nil then
		canonicalMapping = loadCanonicalMapping()
	end

	local dlg = Dialog("AsepriteDmi")

	dlg:separator({ text = "Arquivo DMI (com metadados)" })
	dlg:button({
		id = "importDMI",
		text = "Importar DMI",
		onclick = function()
			dlg:close()
			importDMI()
			showMainDialog()
		end,
	})
	dlg:button({
		id = "exportDMI",
		text = "Exportar DMI",
		onclick = function()
			dlg:close()
			exportDMI()
			showMainDialog()
		end,
	})

	dlg:separator({ text = "DMI → Tags (mapeamento canônico)" })
	dlg:button({
		id = "learnMapping",
		text = "Aprender mapeamento (base completa)",
		onclick = function()
			dlg:close()
			learnCanonicalMapping()
			showMainDialog()
		end,
	})
	dlg:button({
		id = "importMapped",
		text = "Importar DMI nas tags",
		onclick = function()
			dlg:close()
			importDmiIntoTags()
			showMainDialog()
		end,
	})
	dlg:label({
		text = canonicalMapping and "✓ Mapeamento carregado" or "✗ Sem mapeamento (aprenda primeiro)",
	})

	dlg:separator({ text = "Folha BYOND (layers por direção)" })
	dlg:button({
		id = "exportSheet",
		text = "Exportar Folha",
		onclick = function()
			dlg:close()
			showExportDialog()
		end,
	})
	dlg:button({
		id = "importSheet",
		text = "Importar Folha",
		onclick = function()
			dlg:close()
			importByondSheet()
		end,
	})

	dlg:separator({ text = "Operações de Sprite" })
	dlg:button({
		id = "mirror",
		text = "Espelhar Leste → Oeste",
		onclick = function()
			dlg:close()
			mirrorEastToWest()
			showMainDialog()
		end,
	})
	dlg:button({
		id = "deleteWest",
		text = "Apagar Frames Oeste",
		onclick = function()
			dlg:close()
			deleteWestFrames()
			showMainDialog()
		end,
	})

	dlg:separator({ text = "Status dos Metadados" })
	if rawZtxtChunk then
		dlg:label({ text = "✓ Metadado DMI carregado (" .. #rawZtxtChunk .. " bytes)" })
		if parsedStates and #parsedStates > 0 then
			dlg:label({ text = "✓ " .. #parsedStates .. " icon state(s) lidos" })
			dlg:button({
				id = "viewStates",
				text = "Ver Icon States",
				onclick = function()
					app.alert({ title = "Icon States do DMI", text = summarizeStates(parsedStates) })
				end,
			})
		end
		dlg:button({
			id = "viewMetadata",
			text = "Ver Metadado (Hex)",
			onclick = function()
				local hexData = bytesToHex(rawZtxtChunk, 200)
				local textData = ""
				for i = 1, math.min(200, #rawZtxtChunk) do
					local byte = string.byte(rawZtxtChunk, i)
					textData = textData .. ((byte >= 32 and byte <= 126) and string.char(byte) or ".")
				end
				local metadlg = Dialog("Metadado DMI bruto")
				metadlg:label({ text = "Metadado (Hex):" })
				metadlg:entry({
					id = "hex",
					text = hexData,
					readonly = true,
					multiline = true,
					width = 400,
					height = 150,
				})
				metadlg:label({ text = "Caracteres imprimíveis:" })
				metadlg:entry({
					id = "text",
					text = textData,
					readonly = true,
					multiline = true,
					width = 400,
					height = 150,
				})
				metadlg:button({ id = "close", text = "Fechar" })
				metadlg:show()
			end,
		})
		dlg:button({
			id = "clearMetadata",
			text = "Limpar Metadado",
			onclick = function()
				rawZtxtChunk = nil
				parsedStates = nil
				safeRemoveFile("dmi_metadata.bin")
				dlg:close()
				showMainDialog()
			end,
		})
	else
		dlg:label({ text = "✗ Nenhum metadado DMI carregado" })
	end

	dlg:separator({})
	dlg:check({ id = "debug", text = "Modo Debug", selected = debugMode })
	dlg:button({ id = "close", text = "Fechar" })
	dlg:show()

	if dlg.data.debug ~= nil then
		debugMode = dlg.data.debug
	end
end

-- =============================================================================
-- PONTO DE ENTRADA
-- =============================================================================
showMainDialog()
