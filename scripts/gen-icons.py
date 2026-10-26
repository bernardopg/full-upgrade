#!/usr/bin/env python3
"""Gera os ícones do full-upgrade a partir da fonte Material Symbols Rounded.

É a mesma fonte variável que o DankMaterialShell usa no `DankIcon` (e os
plugins DMS, como o AiOverviewControl), nos mesmos eixos padrão: FILL 0,
GRAD 0, opsz 24, wght 400. Assim o applet fica com a mesma linguagem visual
da barra e dos menus do shell.

Os SVGs saem monocromáticos com `TRAY_ICON_PLACEHOLDER` como cor; o applet
troca essa cor pela cor de texto do tema GTK em tempo de execução. Os arquivos
gerados são versionados em assets/icons/, então este script só roda quando um
ícone muda — ele não é dependência de build nem de runtime.

Uso:
    python3 -I scripts/gen-icons.py <MaterialSymbolsRounded[...].ttf> [saída]

Material Symbols: Copyright Google LLC, Apache License 2.0.
"""
import sys
from pathlib import Path

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib import instancer

# Cor neutra dos ícones simbólicos (convenção GNOME): legível em tema claro e
# escuro quando nada a substitui (yad, notificação, tema de ícones).
PLACEHOLDER = "#bebebe"

# Estados do applet: a família "deployed_code" (pacote) dá a identidade; o
# glifo varia com o estado e o arquivo mantém o nome que o código já resolve.
TRAY = {
    "full-upgrade-tray-idle": "deployed_code",
    "full-upgrade-tray-updates": "deployed_code_update",
    "full-upgrade-tray-running": "deployed_code_history",
    "full-upgrade-tray-attention": "deployed_code_alert",
    "full-upgrade-tray-error": "error",
}

# Itens do menu, por papel (o nome do arquivo não muda se o glifo mudar).
MENU = {
    "check-error": "sync_problem",
    "checked": "schedule",
    "summary": "info",
    "repo": "package_2",
    "aur": "deployed_code",
    "flatpak": "apps",
    "artcraft": "palette",
    "pending": "pending_actions",
    "update": "deployed_code_update",
    "update-system": "system_update_alt",
    "update-packages": "package_2",
    "doctor": "stethoscope",
    "repair": "build",
    "refresh": "refresh",
    "logs": "description",
    "log": "article",
    "report": "summarize",
    "log-folder": "folder_open",
    "quit": "logout",
}

AXES = {"FILL": 0, "GRAD": 0, "opsz": 24, "wght": 400}


def glyph_path(font, glyphs, name):
    """Contorno do glifo no espaço 0 -960 960 960 dos SVGs oficiais."""
    pen = SVGPathPen(glyphs)
    # A fonte é y-para-cima; o SVG oficial do Material Symbols usa y negativo.
    glyphs[name].draw(TransformPen(pen, (1, 0, 0, -1, 0, 0)))
    return pen.getCommands()


def symbolic_svg(path, comment):
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        f"<!-- {comment} — Material Symbols Rounded (Apache-2.0). Gerado por scripts/gen-icons.py. -->\n"
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 -960 960 960" width="24" height="24">\n'
        f'  <path fill="{PLACEHOLDER}" d="{path}"/>\n'
        "</svg>\n"
    )


def app_svg(path):
    # Ícone do aplicativo (launcher, notificação, .desktop): o mesmo glifo da
    # marca sobre um tile arredondado nos tons de superfície do Material 3.
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        "<!-- full-upgrade — ícone do aplicativo. Glifo deployed_code_update do Material Symbols\n"
        "     Rounded (Apache-2.0) sobre tile arredondado. Gerado por scripts/gen-icons.py. -->\n"
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">\n'
        '  <rect x="32" y="32" width="448" height="448" rx="112" ry="112" fill="#2b2930"/>\n'
        '  <g transform="translate(96 416) scale(0.3333333)">\n'
        f'    <path fill="#e6e0e9" d="{path}"/>\n'
        "  </g>\n"
        "</svg>\n"
    )


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = Path(sys.argv[2] if len(sys.argv) > 2 else Path(__file__).resolve().parents[1] / "assets/icons")
    font = instancer.instantiateVariableFont(TTFont(sys.argv[1]), AXES)
    cmap = font.getBestCmap()
    by_name = {glyph: glyph for glyph in cmap.values()}
    glyphs = font.getGlyphSet()

    def path_for(name):
        if name not in by_name:
            sys.exit(f"glifo ausente na fonte: {name}")
        return glyph_path(font, glyphs, name)

    out.mkdir(parents=True, exist_ok=True)
    for filename, glyph in TRAY.items():
        state = filename.rsplit("-", 1)[1]
        (out / f"{filename}.svg").write_text(symbolic_svg(path_for(glyph), f"full-upgrade tray — {state} ({glyph})"))
    for role, glyph in MENU.items():
        (out / f"full-upgrade-menu-{role}.svg").write_text(symbolic_svg(path_for(glyph), f"full-upgrade menu — {role} ({glyph})"))
    (out / "full-upgrade.svg").write_text(app_svg(path_for("deployed_code_update")))
    print(f"{len(TRAY) + len(MENU) + 1} ícones em {out}")


if __name__ == "__main__":
    main()
