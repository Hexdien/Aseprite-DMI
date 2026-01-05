-- SheetGen: Exportar e Importar SpriteSheets (4 direções)

local spr = app.activeSprite
if not spr then
	return app.alert("Nenhum sprite aberto!")
end

----------------------------------------------------
-- Função Export
----------------------------------------------------
-- ====================================================
-- Exportar SpriteSheet (4 direções) - versão corrigida
-- ====================================================

local spr = app.activeSprite
if not spr then
	return app.alert("Nenhum sprite aberto!")
end

local function showExportDialog()
	----------------------------------------------------
	-- 1) Listagem recursiva para popular os combos
	----------------------------------------------------
	local layerOptions = {}
	local layerRefs = {}

	local function collectOptions(parent, prefix)
		-- parent pode ser spr (Sprite) ou um Group
		local list = parent.layers
		for _, l in ipairs(list) do
			local label = prefix .. l.name
			table.insert(layerOptions, label)
			layerRefs[label] = l
			if l.isGroup then
				collectOptions(l, label .. "/")
			end
		end
	end

	collectOptions(spr, "") -- popula layerOptions/layerRefs
	if #layerOptions == 0 then
		return app.alert("Não há layers/grupos para listar.")
	end

	----------------------------------------------------
	-- 2) UI
	----------------------------------------------------
	local dlg = Dialog("Exportar SpriteSheet")

	dlg:combobox({ id = "layerSul", label = "Layer Sul:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerNorte", label = "Layer Norte:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerLeste", label = "Layer Leste:", option = layerOptions[1], options = layerOptions })
	dlg:combobox({ id = "layerOeste", label = "Layer Oeste:", option = layerOptions[1], options = layerOptions })

	dlg:number({ id = "columns", label = "Colunas:", text = "17" })
	dlg:button({ id = "ok", text = "Exportar", focus = true })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	local data = dlg.data
	if not data.ok then
		return
	end

	----------------------------------------------------
	-- 3) Resolve direções selecionadas
	----------------------------------------------------
	local dirOffsets = { Sul = 0, Norte = 1, Leste = 2, Oeste = 3 }

	local function expandLayer(key)
		local node = layerRefs[key]
		local out = {}
		local function collect(node)
			if node.isGroup then
				for _, child in ipairs(node.layers) do
					collect(child)
				end
			else
				-- Layer de imagem (não grupo)
				table.insert(out, node)
			end
		end
		if node then
			collect(node)
		end
		return out
	end

	local selectedLayers = {
		Sul = expandLayer(data.layerSul),
		Norte = expandLayer(data.layerNorte),
		Leste = expandLayer(data.layerLeste),
		Oeste = expandLayer(data.layerOeste),
	}

	----------------------------------------------------
	-- 4) Parâmetros do sheet
	----------------------------------------------------
	local totalCols = tonumber(data.columns) or 17
	if totalCols < 1 then
		totalCols = 1
	end

	local frameCount = #spr.frames
	if frameCount == 0 then
		return app.alert("Sprite não possui frames.")
	end

	local w, h = spr.width, spr.height
	local jump = 4

	-- linhas necessárias (considerando maior índice em Oeste)
	local lastPos = dirOffsets["Oeste"] + (frameCount - 1) * jump
	local rows = math.floor(lastPos / totalCols) + 1

	-- Cria a sheet final
	local sheet = Image(w * totalCols, h * rows, spr.colorMode)
	sheet:clear()

	----------------------------------------------------
	-- 5) Export: compõe por frame -> cola no tile
	----------------------------------------------------
	for dir, layerList in pairs(selectedLayers) do
		local baseCol = dirOffsets[dir]

		for f = 1, frameCount do
			local posIndex = baseCol + (f - 1) * jump
			local col = posIndex % totalCols
			local row = math.floor(posIndex / totalCols)
			local dx = col * w
			local dy = row * h

			-- 🔑 Composição do frame em tampão w x h
			local frameImg = Image(w, h, spr.colorMode)
			frameImg:clear()

			-- desenha as cels (com offset) dentro do frameImg; qualquer excesso é recortado
			for _, layer in ipairs(layerList) do
				local cel = layer:cel(f)
				if cel then
					-- respeita o offset da cel, mas clipa dentro do frame
					frameImg:drawImage(cel.image, cel.position)
				end
			end

			-- cola o frame composto no tile correspondente
			sheet:drawImage(frameImg, Point(dx, dy))
		end
	end

	----------------------------------------------------
	-- 6) Cria um novo sprite com a sheet
	----------------------------------------------------
	local newSpr = Sprite(sheet.width, sheet.height, spr.colorMode)
	newSpr:newCel(newSpr.layers[1], 1, sheet, Point(0, 0))
	app.activeSprite = newSpr
end

----------------------------------------------------
-- Função Import
----------------------------------------------------

----------------------------------------------------
-- IMPORT AUTOMÁTICO BYOND (4 direções)
----------------------------------------------------
local function importByondSheet()
	local spr = app.activeSprite
	if not spr then
		return app.alert("Nenhum sprite aberto.")
	end

	-- Assume que a folha está em uma cel/frame
	local sheetCel
	for _, layer in ipairs(spr.layers) do
		local cel = layer:cel(1)
		if cel then
			sheetCel = cel
			break
		end
	end
	if not sheetCel then
		return app.alert("Nenhuma imagem encontrada.")
	end

	local sheet = sheetCel.image

	------------------------------------------------
	-- UI mínima: apenas tamanho do frame
	------------------------------------------------
	local dlg = Dialog("Importar SpriteSheet BYOND")
	dlg:number({ id = "fw", label = "Frame Width", text = "32" })
	dlg:number({ id = "fh", label = "Frame Height", text = "32" })
	dlg:button({ id = "ok", text = "Importar", focus = true })
	dlg:button({ id = "cancel", text = "Cancelar" })
	dlg:show()

	if not dlg.data.ok then
		return
	end

	local fw = tonumber(dlg.data.fw)
	local fh = tonumber(dlg.data.fh)
	if fw <= 0 or fh <= 0 then
		return app.alert("Frame inválido.")
	end

	------------------------------------------------
	-- Dedução automática da folha
	------------------------------------------------
	local cols = sheet.width / fw
	local rows = sheet.height / fh

	if cols % 1 ~= 0 or rows % 1 ~= 0 then
		return app.alert("O tamanho do frame não divide a folha corretamente.")
	end

	local totalCells = cols * rows
	local framesCount = math.floor(totalCells / 4)

	if framesCount == 0 then
		return app.alert("Folha inválida para 4 direções.")
	end

	------------------------------------------------
	-- Cria sprite destino
	------------------------------------------------
	local newSpr = Sprite(fw, fh, spr.colorMode)
	while #newSpr.frames < framesCount do
		newSpr:newFrame()
	end

	local directions = { "Sul", "Norte", "Leste", "Oeste" }
	local layers = {}

	for _, name in ipairs(directions) do
		local l = newSpr:newLayer()
		l.name = name
		table.insert(layers, l)
	end

	------------------------------------------------
	-- Função de extração
	------------------------------------------------
	local function extract(x, y)
		local img = Image(fw, fh, spr.colorMode)
		img:drawImage(sheet, Point(-x, -y))
		return img
	end

	------------------------------------------------
	-- Importação real
	------------------------------------------------
	for i = 0, framesCount - 1 do
		for dir = 0, 3 do
			local index = dir + i * 4
			local col = index % cols
			local row = math.floor(index / cols)

			local x = col * fw
			local y = row * fh

			local img = extract(x, y)
			newSpr:newCel(layers[dir + 1], i + 1, img, Point(0, 0))
		end
	end

	app.activeSprite = newSpr
	app.refresh()
	app.alert("Importação concluída (" .. framesCount .. " frames).")
end

----------------------------------------------------
-- Menu inicial
----------------------------------------------------
local function showMainMenu()
	local dlg = Dialog("SheetGen")
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
end

----------------------------------------------------
-- Execução
----------------------------------------------------
showMainMenu()
