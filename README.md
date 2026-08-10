# dotfiles

Entorno de desarrollo de esta máquina, declarado como código.

## Máquina nueva

```bash
git clone <este-repo> ~/dotfiles
~/dotfiles/install.sh
```

## Arquitectura

| Capa | Herramienta | Qué gestiona |
|---|---|---|
| Sistema | Homebrew | CLIs y apps nativas (`Brewfile`) |
| Runtimes | mise | node, python, go… por proyecto (`mise/config.toml`) |
| Python | uv | paquetes, venvs y proyectos |
| Rust | rustup | toolchains |

Regla: **Homebrew instala programas, mise instala runtimes.** Nunca un runtime
por Homebrew — te ata a una sola versión global y rompe proyectos con otra.

El Python del sistema (`/usr/bin/python3`) no se toca nunca.

## Ficheros

```
Brewfile               paquetes, apps y extensiones de VS Code
zsh/.zshrc             PATH, historial, fzf, alias
zsh/.zsh_plugins.txt   plugins (antidote)
starship.toml          prompt
ghostty/config         terminal
git/.gitconfig         config de git (sin identidad)
git/.gitignore_global
mise/config.toml       versiones globales de runtimes
vscode/settings.json   ajustes del editor
claude/statusline.sh            statusline de Claude Code
claude/subagent-statusline.sh   telemetría por agente en el panel de agentes
claude/statusline-demo.sh       las renderiza con casos de ejemplo
install.sh             symlinks + instalación completa
```

`~/.zsh_plugins.zsh` es **generado**, no se versiona: antidote lo regenera
solo cuando `.zsh_plugins.txt` cambia.

La identidad de git vive en `~/.gitconfig.local`, **fuera del repo**, para que
esto pueda ser público y cada máquina use su propio nombre/email.

`~/.claude/settings.json` tampoco se enlaza: Claude Code lo reescribe solo
(tema, `/config`…) y un symlink acabaría sobrescrito. `install.sh` le hace
merge de `statusLine` y `subagentStatusLine` con `jq`, que es idempotente.

Para verlas sin reiniciar Claude, incluidos los casos que no puedes provocar a
voluntad (límite al 95 %, contexto en rojo, PR con cambios pedidos, un agente
atascado):

```bash
~/dotfiles/claude/statusline-demo.sh
```

La statusline principal son dos líneas: identidad arriba (modelo, ruta, rama,
PR) en estilo powerline, y medidores abajo (contexto, límites de 5 h y 7 días,
coste) sobre fondo limpio, para que el color siga funcionando como alarma.
`STYLE` y `LINES`, al principio del script, cambian a `minimal` y a una sola
línea. Ambas requieren una Nerd Font: la config de Ghostty ya la fija.

## Uso diario

```bash
brew upgrade                  # actualiza todo lo del sistema
mise upgrade                  # actualiza runtimes

# Tras instalar algo nuevo, volcarlo al repo (incluye extensiones de VS Code):
brew bundle dump --file=~/dotfiles/Brewfile --force
```

Fijar versiones en un proyecto (crea `mise.toml`, versiónalo con el repo):

```bash
mise use node@24 python@3.13
```
