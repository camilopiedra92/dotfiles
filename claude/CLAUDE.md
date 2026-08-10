# Preferencias globales

## Entorno

`~/Development` es una carpeta contenedora, no un proyecto. Cada subcarpeta es un
proyecto independiente con su propio git, su propio toolchain y sus propias
convenciones. No asumas que algo visto en un proyecto aplica a otro, y no crees
archivos sueltos en la raíz de `~/Development`.

La configuración de Claude Code y de la shell vive en `~/dotfiles` (versionado).
Los cambios a `~/.claude/*.sh` van ahí, no en copias sueltas.

Stack habitual: Python, Node/TypeScript/JavaScript, React, shell e infra.

## Idioma

Respóndeme en español. El código en inglés: nombres, comentarios, mensajes de
commit, documentación en el repo, strings de log. Un repo puede acabar siendo
público o compartido.

## Cómo trabajar

Calibra por tamaño. Un cambio acotado o mecánico hazlo directo y cuéntamelo
después. Si toca varios archivos, cambia una interfaz o implica una decisión de
diseño con alternativas reales, propón el enfoque antes de escribir.

Antes de introducir una dependencia nueva, pregunta. Casi siempre prefiero
resolverlo con lo que ya está en el proyecto o con la librería estándar.

Respeta el toolchain que ya usa cada proyecto: el gestor de paquetes que indique
el lockfile, el formateador y el linter que estén configurados. No los cambies
ni añadas config nueva por iniciativa propia.

No crees archivos que no hagan falta. Nada de READMEs, resúmenes ni documentos
de "notas de implementación" salvo que te los pida.

## Código

Comenta el porqué, no el qué. Si el comentario repite lo que ya dice la línea
siguiente, sobra. Los que valen la pena explican una decisión, un caso borde o
algo que sorprendería a quien lea.

Escribe tests cuando haya lógica con casos borde reales. No para getters,
wrappers ni funciones de una línea.

Al terminar, di lo que pasó de verdad: si un test falla, enséñame la salida; si
dejaste algo a medias, dilo. Prefiero un reporte incómodo a uno optimista.
