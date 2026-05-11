-- =============================================================================
-- SheetGen — Exportar e Importar SpriteSheets no formato BYOND/DMI
-- =============================================================================
--
-- BYOND organiza os tiles de uma folha assim (exemplo: 4 frames, 4 direções):
--
--   Índice: 0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
--   Frame:  F1  F1  F1  F1  F2  F2  F2  F2  F3  F3  F3  F3  F4  F4  F4  F4
--   Dir:    S   N   L   O   S   N   L   O   S   N   L   O   S   N   L   O
--
-- Ou seja: para cada frame, as 4 direções aparecem consecutivas (S, N, L, O).
-- O "jump" entre um frame e o próximo é sempre 4 (número de direções).
--
-- Para animações com 1 direção e 4 frames:
--
--   Índice: 0   1   2   3
--   Frame:  F1  F2  F3  F4
--   Dir:    S   S   S   S
--
-- Nesse caso o jump é 1 (sem intercalação de direções).
-- =============================================================================

-- =============================================================================
-- UTILITÁRIOS GERAIS
-- =============================================================================

--- Encontra a primeira cel com imagem no sprite (percorre todas as layers).
--- Usada no import para localizar a folha carregada.
--- @param sprite Sprite  O sprite do Aseprite a percorrer.
--- @return Cel|nil       A primeira cel encontrada, ou nil se não houver.
local function findFirstCel(sprite)
	for _, layer in ipairs(sprite.layers) do
		local cel = layer:cel(1)
		if cel then
			return cel
		end
	end
	return nil
end

--- Extrai um recorte retangular de uma imagem maior.
--- Funciona deslocando a imagem de origem negativamente para que o ponto (x, y)
--- coincida com a origem (0, 0) do buffer de destino.
--- @param sourceImage Image  A imagem de origem (a folha completa).
--- @param x number           Coordenada X do canto superior esquerdo do tile.
--- @param y number           Coordenada Y do canto superior esquerdo do tile.
--- @param fw number          Largura do frame (tile).
--- @param fh number          Altura do frame (tile).
--- @param colorMode number   Modo de cor do sprite (ex.: ColorMode.RGB).
--- @return Image             Nova imagem com o conteúdo recortado.
local function extractTile(sourceImage, x, y, fw, fh, colorMode)
	local img = Image(fw, fh, colorMode)
	-- drawImage com offset negativo faz o ponto (x,y) da fonte cair em (0,0)
	img:drawImage(sourceImage, Point(-x, -y))
	return img
end

--- Compõe todas as cels visíveis de uma lista de layers em um único buffer.
--- Isso simula o "achatamento" (flatten) de um grupo de layers para um frame.
--- @param layerList table  Lista de layers (não-grupo) a compor.
--- @param frameIndex number  Índice do frame a compor (base 1).
--- @param w number          Largura do buffer de destino.
--- @param h number          Altura do buffer de destino.
--- @param colorMode number   Modo de cor.
--- @return Image             Buffer composto com todas as cels renderizadas.
local function composeLayers(layerList, frameIndex, w, h, colorMode)
	local buffer = Image(w, h, colorMode)
	buffer:clear()
	for _, layer in ipairs(layerList) do
		local cel = layer:cel(frameIndex)
		if cel then
			-- cel.position é o offset da cel dentro do canvas do sprite
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

local function trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function normalizeDirName(text)
	local key = trim(text):lower()
	return DIR_ALIASES[key]
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

--- Lê convenções simples no nome da tag para decidir o layout de exportação.
---
--- Padrão:
---   "andar"                       -> 4 direções
---   "meditar [1]"                 -> 1 direção, sempre usando a layer Sul
---   "chute giratorio dirs=1"      -> 1 direção, sempre usando a layer Sul
---   "chute [1:Sul,Leste,Norte,Oeste]"
---                                  -> 1 direção, escolhendo a layer por frame
local function parseTagExportConfig(tagName)
	local lower = tagName:lower()
	local config = { dirCount = 4, sourceDirs = nil, invalidDirs = {} }

	local orderSpec = tagName:match("%[1%s*:%s*([^%]]+)%]")
		or tagName:match("%[1dir%s*:%s*([^%]]+)%]")
		or tagName:match("%[dirs%s*=%s*1%s*:%s*([^%]]+)%]")

	if orderSpec
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

--- Percorre recursivamente todas as layers de um sprite (ou grupo),
--- construindo duas estruturas paralelas:
---   layerOptions — lista ordenada de rótulos (ex.: "Corpo", "Grupo/Cabelo")
---   layerRefs    — mapa de rótulo -> objeto Layer
--- O prefixo cresce a cada nível de grupo para refletir a hierarquia.
--- @param parent Sprite|Layer  Nó pai (sprite raiz ou grupo).
--- @param prefix string        Prefixo acumulado de nomes de grupos.
--- @param layerOptions table   Lista de rótulos (modificada in-place).
--- @param layerRefs table      Mapa rótulo->Layer (modificado in-place).
local function collectLayerOptions(parent, prefix, layerOptions, layerRefs)
	for _, layer in ipairs(parent.layers) do
		local label = prefix .. layer.name
		table.insert(layerOptions, label)
		layerRefs[label] = layer
		if layer.isGroup then
			-- recursão: entra no grupo com prefixo estendido
			collectLayerOptions(layer, label .. "/", layerOptions, layerRefs)
		end
	end
end

--- Dado um nó de layer (que pode ser grupo ou folha), retorna uma lista
--- contendo apenas as layers de imagem (não-grupo) que estão dentro dele.
--- Se o nó já for uma folha, retorna uma lista com ele mesmo.
--- @param node Layer  O nó a expandir.
--- @return table      Lista plana de layers de imagem.
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
-- EXPORTAR
-- =============================================================================

--- Abre o diálogo de exportação e, após confirmação, gera a spritesheet
--- no formato BYOND (direções intercaladas) como um novo sprite.
local function showExportDialog()
	local spr = app.activeSprite
	if not spr then
		return app.alert("Nenhum sprite aberto!")
	end

	-- -------------------------------------------------------------------------
	-- Passo 1: Coleta todas as layers disponíveis para popular os comboboxes.
	-- -------------------------------------------------------------------------
	local layerOptions = {}
	local layerRefs = {}
	collectLayerOptions(spr, "", layerOptions, layerRefs)

	if #layerOptions == 0 then
		return app.alert("Não há layers/grupos para listar.")
	end

	-- -------------------------------------------------------------------------
	-- Passo 2: Exibe o diálogo de configuração.
	-- -------------------------------------------------------------------------
	local dlg = Dialog("Exportar SpriteSheet")

	-- Cada combobox associa uma direção BYOND a uma layer/grupo do sprite.
	dlg:combobox({ id = "layerSul", label = "Layer Sul:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerNorte", label = "Layer Norte:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerLeste", label = "Layer Leste:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerOeste", label = "Layer Oeste:", option = layerOptions[1], options = layerOptions })

	-- Número de colunas da folha gerada (padrão BYOND é 17 para ícones 32x32).
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

	-- -------------------------------------------------------------------------
	-- Passo 3: Resolve quais layers de imagem compõem cada direção.
	-- -------------------------------------------------------------------------
	-- dirOffsets: posição relativa de cada direção dentro de um grupo de 4 tiles.
	-- No formato BYOND a ordem é sempre S=0, N=1, L=2, O=3.
	local dirOffsets = DIR_OFFSETS

	-- Para cada direção, expande o nó selecionado até as layers de imagem folha.
	local selectedLayers = {
		Sul = expandToImageLayers(layerRefs[data.layerSul]),
		Norte = expandToImageLayers(layerRefs[data.layerNorte]),
		Leste = expandToImageLayers(layerRefs[data.layerLeste]),
		Oeste = expandToImageLayers(layerRefs[data.layerOeste]),
	}

	-- -------------------------------------------------------------------------
	-- Passo 4: Calcula as dimensões da folha de saída.
	-- -------------------------------------------------------------------------
	local totalCols = math.max(1, tonumber(data.columns) or 17)
	local frameCount = #spr.frames

	if frameCount == 0 then
		return app.alert("Sprite não possui frames.")
	end

	local w, h = spr.width, spr.height
	local jump = 4 -- Número de slots entre o mesmo frame em direções diferentes.
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
					"Tag com direção inválida: "
						.. tag.name
						.. "\nUse S, N, L, O ou Sul, Norte, Leste, Oeste."
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
		-- Modo legado: todos os frames são exportados como 4 direções BYOND.
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

	-- Cria a imagem da folha final com as dimensões calculadas.
	local sheet = Image(w * totalCols, h * totalRows, spr.colorMode)
	sheet:clear()

	-- -------------------------------------------------------------------------
	-- Passo 5: Preenche a folha tile a tile.
	-- -------------------------------------------------------------------------
	-- No modo por tags, exportTiles já está na ordem exata da folha.
	-- No modo legado, mantemos a fórmula antiga de offset por direção.
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

		-- Compõe todas as layers deste frame em um buffer único.
		local tileImg = composeLayers(selectedLayers[tile.dir], tile.frame, w, h, spr.colorMode)

		-- Cola o buffer na posição correta da folha.
		sheet:drawImage(tileImg, Point(dx, dy))
	end

	-- -------------------------------------------------------------------------
	-- Passo 6: Cria um novo sprite contendo apenas a folha gerada.
	-- -------------------------------------------------------------------------
	local newSpr = Sprite(sheet.width, sheet.height, spr.colorMode)
	newSpr:newCel(newSpr.layers[1], 1, sheet, Point(0, 0))
	app.activeSprite = newSpr
end

-- =============================================================================
-- IMPORTAR
-- =============================================================================

-- BYOND organiza os tiles de acordo com o número de direções:
--
--   4 direções → posIndex = dir + frame * 4
--                (S, N, L, O aparecem intercalados a cada 4 slots)
--
--   1 direção  → posIndex = frame
--                (tiles simplesmente em sequência)
--
-- Dado um posIndex e o número de direções, extraímos col/row na folha:
--   col = posIndex % totalCols
--   row = posIndex // totalCols

--- Lê a folha do sprite ativo e abre o diálogo de importação.
--- Permite escolher entre 1 ou 4 direções e gera um sprite organizado em layers.
local function importByondSheet()
	local spr = app.activeSprite
	if not spr then
		return app.alert("Nenhum sprite aberto.")
	end

	-- -------------------------------------------------------------------------
	-- Passo 1: Encontra a imagem da folha no sprite aberto.
	-- -------------------------------------------------------------------------
	local sheetCel = findFirstCel(spr)
	if not sheetCel then
		return app.alert("Nenhuma imagem encontrada no sprite.")
	end

	local sheet = sheetCel.image

	-- -------------------------------------------------------------------------
	-- Passo 2: Diálogo de configuração da importação.
	-- -------------------------------------------------------------------------
	local dlg = Dialog("Importar SpriteSheet BYOND")
	dlg:number({ id = "fw", label = "Largura do Frame (px):", text = "32" })
	dlg:number({ id = "fh", label = "Altura do Frame (px):", text = "32" })

	-- Novidade: o usuário escolhe quantas direções a folha contém.
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

	-- -------------------------------------------------------------------------
	-- Passo 3: Valida as dimensões informadas.
	-- -------------------------------------------------------------------------
	local fw = tonumber(dlg.data.fw)
	local fh = tonumber(dlg.data.fh)

	if not fw or not fh or fw <= 0 or fh <= 0 then
		return app.alert("Dimensões de frame inválidas.")
	end

	-- -------------------------------------------------------------------------
	-- Passo 4: Calcula o layout da folha.
	-- -------------------------------------------------------------------------
	local cols = sheet.width / fw -- número de colunas de tiles
	local rows = sheet.height / fh -- número de linhas de tiles

	-- A divisão deve ser exata; caso contrário o tamanho de frame está errado.
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

	-- -------------------------------------------------------------------------
	-- Passo 5: Determina o número de direções e de frames.
	-- -------------------------------------------------------------------------
	-- dirCount é o "jump": de quanto em quanto slots a mesma direção avança.
	-- Com 4 dirs: [S, N, L, O, S, N, L, O, …] → a cada 4 slots volta ao S.
	-- Com 1 dir:  [S, S, S, S, …]              → a cada 1 slot avança o frame.
	local dirCount
	if dlg.data.dirMode == "1 (só Sul)" then
		dirCount = 1
	else
		dirCount = 4
	end

	-- A quantidade de tiles deve ser divisível pelo número de direções.
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

	-- -------------------------------------------------------------------------
	-- Passo 6: Define os nomes das direções que serão criadas como layers.
	-- -------------------------------------------------------------------------
	local dirNames
	if dirCount == 1 then
		dirNames = { "Sul" }
	else
		-- Ordem BYOND: Sul=0, Norte=1, Leste=2, Oeste=3
		dirNames = { "Sul", "Norte", "Leste", "Oeste" }
	end

	-- -------------------------------------------------------------------------
	-- Passo 7: Cria o sprite destino com frames e layers adequados.
	-- -------------------------------------------------------------------------
	local newSpr = Sprite(fw, fh, spr.colorMode)

	-- O sprite começa com 1 frame; adiciona os demais até chegar em framesCount.
	while #newSpr.frames < framesCount do
		newSpr:newFrame()
	end

	-- Cria uma layer para cada direção (a layer padrão já existe, deletamos depois).
	-- Estratégia: criar as novas layers e depois remover a layer inicial vazia.
	local dirLayers = {}
	for _, name in ipairs(dirNames) do
		local layer = newSpr:newLayer()
		layer.name = name
		table.insert(dirLayers, layer)
	end

	-- Remove a layer padrão criada automaticamente pelo Aseprite (está no índice 1
	-- antes de adicionarmos as nossas). Como adicionamos layers acima ela ficou
	-- como a layer mais antiga; verificamos se está vazia antes de remover.
	-- (Aseprite adiciona a layer padrão sem nome ou com nome "Layer 1".)
	for _, layer in ipairs(newSpr.layers) do
		if layer.name == "Layer 1" or layer.name == "" then
			-- Verifica se nenhuma cel foi colocada nela
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

	-- -------------------------------------------------------------------------
	-- Passo 8: Extrai cada tile e coloca na layer/frame correspondente.
	-- -------------------------------------------------------------------------
	-- Para cada frame (i, base 0) e direção (d, base 0):
	--   posIndex = d + i * dirCount
	--   col = posIndex % cols
	--   row = posIndex // cols
	--   x   = col * fw  (pixels)
	--   y   = row * fh  (pixels)
	for i = 0, framesCount - 1 do
		for d = 0, dirCount - 1 do
			local posIndex = d + i * dirCount
			local col = posIndex % cols
			local row = math.floor(posIndex / cols)

			local x = col * fw
			local y = row * fh

			local tileImg = extractTile(sheet, x, y, fw, fh, spr.colorMode)

			-- newCel: (layer, índice do frame base-1, imagem, posição no canvas)
			newSpr:newCel(dirLayers[d + 1], i + 1, tileImg, Point(0, 0))
		end
	end

	-- -------------------------------------------------------------------------
	-- Passo 9: Finaliza e exibe o resultado.
	-- -------------------------------------------------------------------------
	app.activeSprite = newSpr
	app.refresh()
	app.alert("Importação concluída!\n" .. framesCount .. " frame(s) × " .. dirCount .. " direção(ões).")
end

-- =============================================================================
-- MENU PRINCIPAL
-- =============================================================================

--- Exibe o menu inicial e encaminha para Exportar ou Importar.
local function showMainMenu()
	-- Verificação antecipada: ambas as funções precisam de um sprite aberto,
	-- mas só avisamos aqui para não repetir a mensagem desnecessariamente.
	if not app.activeSprite then
		return app.alert("Abra um sprite antes de usar o SheetGen.")
	end

	local dlg = Dialog("BYOND/DMI")
	dlg:button({ id = "export", text = "Exportar" })
	dlg:button({ id = "import", text = "Importar" })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	local data = dlg.data
	if data.export then
		showExportDialog()
	elseif data.import then
		importByondSheet()
	end
	-- Se "cancel" ou fechou o diálogo, simplesmente termina.
end

-- =============================================================================
-- PONTO DE ENTRADA
-- =============================================================================
showMainMenu()
