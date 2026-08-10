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
Brewfile              paquetes de Homebrew
zsh/.zshrc            PATH + activación de mise
git/.gitconfig        config de git (sin identidad)
git/.gitignore_global
mise/config.toml      versiones globales de runtimes
vscode/settings.json  ajustes del editor
vscode/extensions.txt lista de extensiones
install.sh            symlinks + instalación completa
```

La identidad de git vive en `~/.gitconfig.local`, **fuera del repo**, para que
esto pueda ser público y cada máquina use su propio nombre/email.

## Uso diario

```bash
brew upgrade                  # actualiza todo lo del sistema
mise upgrade                  # actualiza runtimes

# Tras instalar algo nuevo, volcarlo al repo:
brew bundle dump --file=~/dotfiles/Brewfile --force
code --list-extensions > ~/dotfiles/vscode/extensions.txt
```

Fijar versiones en un proyecto (crea `mise.toml`, versiónalo con el repo):

```bash
mise use node@24 python@3.13
```
