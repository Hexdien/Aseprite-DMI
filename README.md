# AsepriteDmi - Aseprite Script

Generate sprite sheets from directional frames (North, South, East, West) or import them back into separate layers directly inside **Aseprite** with just a few clicks.

---

## 🇺🇸 English

### 📖 About
AsepriteDmi is an Aseprite script that helps you organize and generate sprite sheets from your layered frames, or import frames from a sprite sheet into separate layers by direction.  
It is especially useful for character animations where frames are separated by direction (North, South, East, West).

### 🚀 Installation
1. Download the `AsepriteDmi.lua` file.  
2. Place it inside your **Aseprite scripts folder**:
   - Windows: `C:\Users\<YourUser>\AppData\Roaming\Aseprite\scripts`
   - Linux: `~/.config/aseprite/scripts`
   - macOS: `~/Library/Application Support/Aseprite/scripts`
3. Restart Aseprite (or press **F5** to refresh scripts).  
4. Go to **File > Scripts > AsepriteDmi** to open the tool.

### 🕹️ How to Use
1. Prepare your project file using the **model file** provided in this repository.  
2. Organize your frames into layers or groups for each direction:
   - **Layer South** → Frames facing south  
   - **Layer North** → Frames facing north  
   - **Layer East** → Frames facing east  
   - **Layer West** → Frames facing west  
3. Run the script.  
4. In the initial dialog, choose either **Export** or **Import**:
   - **Export** → Generates a sprite sheet with frames positioned according to direction and columns.  
   - **Import** → Reads a sprite sheet and distributes frames into separate layers by direction.  
5. For Export, select the layers or groups for each direction and set the total number of columns for the sheet.  
6. AsepriteDmi will handle the layout automatically.

### 🏷️ Tag-based Export
Export can use Aseprite tags to mix regular 4-direction animations with 1-direction animations in the same sheet.

- Normal tags are exported as 4 directions: `South, North, East, West` for every frame.
- Add `[1]`, `[1dir]`, or `dirs=1` to a tag name to export that tag as 1 direction.
- For 1-direction tags, the source layer is `South` by default.
- To pick the source layer per frame, add an order after `[1:]`.

Example:

```text
walk                 -> 4 directions
meditate [1]         -> 1 direction, using South layer
spin kick [1:S,E,N,W] -> 1 direction, frames pulled from South, East, North, West layers
```

### ❤️ Support
If you want to support the project, you can donate here:  
- [PayPal](https://paypal.me/hexdien)  

---

## 🇧🇷 Português (Brasil)

### 📖 Sobre
O **AsepriteDmi** é um script para Aseprite que ajuda a organizar e gerar sprite sheets a partir de frames separados por direção (Norte, Sul, Leste, Oeste), ou importar frames de uma sprite sheet de volta para camadas separadas por direção.  
É ideal para animações de personagens em jogos.

### 🚀 Instalação
1. Baixe o arquivo `AsepriteDmi.lua`.  
2. Coloque-o na pasta de scripts do **Aseprite**:
   - Windows: `C:\Users\<SeuUsuario>\AppData\Roaming\Aseprite\scripts`
   - Linux: `~/.config/aseprite/scripts`
   - macOS: `~/Library/Application Support/Aseprite/scripts`
3. Reinicie o Aseprite (ou pressione **F5** para atualizar os scripts).  
4. Vá em **File > Scripts > AsepriteDmi** para abrir a ferramenta.

### 🕹️ Como Usar
1. Prepare seu arquivo utilizando o **modelo** disponível neste repositório.  
2. Organize seus frames em camadas ou grupos para cada direção:
   - **Layer Sul** → Frames voltados para o sul  
   - **Layer Norte** → Frames voltados para o norte  
   - **Layer Leste** → Frames voltados para o leste  
   - **Layer Oeste** → Frames voltados para o oeste  
3. Execute o script.  
4. No diálogo inicial, escolha **Exportar** ou **Importar**:
   - **Exportar** → Gera um sprite sheet com os frames posicionados de acordo com a direção e o número de colunas.  
   - **Importar** → Lê um sprite sheet e distribui os frames em camadas separadas por direção.  
5. Para Exportar, selecione as layers ou grupos correspondentes a cada direção e defina o número total de colunas da folha.  
6. O AsepriteDmi fará a organização automática dos frames.

### 🏷️ Exportação por Tags
O export pode usar tags do Aseprite para misturar animações normais de 4 direções com animações de 1 direção na mesma folha.

- Tags normais são exportadas como 4 direções: `Sul, Norte, Leste, Oeste` para cada frame.
- Adicione `[1]`, `[1dir]` ou `dirs=1` no nome da tag para exportar aquela tag como 1 direção.
- Em tags de 1 direção, a layer usada por padrão é `Sul`.
- Para escolher a layer usada em cada frame, coloque a ordem depois de `[1:]`.

Exemplo:

```text
andando                         -> 4 direções
meditar [1]                     -> 1 direção, usando a layer Sul
chute giratorio [1:S,L,N,O]     -> 1 direção, frames puxados das layers Sul, Leste, Norte, Oeste
```

### ❤️ Apoie o Projeto
Se você quiser apoiar o projeto, pode fazer uma doação:  
- [PayPal](https://paypal.me/hexdien)  
