#!/bin/bash
# Transforme une image de squircle (rendu IA, sur fond gris) en VRAIE icône macOS :
# détoure le squircle (fond → transparent, coins arrondis clippés), le pose sur la grille
# Apple (corps 824 dans un canevas 1024 transparent), puis génère icon/Murmure.icns.
#
#   ./make-icon.sh [source.png]    # défaut : docs/img/icon-waveform.png
set -euo pipefail
cd "$(dirname "$0")"

SRC="${1:-docs/img/icon-waveform.png}"
[ -f "$SRC" ] || { echo "✗ source introuvable : $SRC" >&2; exit 1; }
mkdir -p icon

echo "▸ Détourage du squircle → icon/icon-1024.png"
RADIUS="${RADIUS:-0.2235}"   # rayon des coins (fraction du côté) — ajustable via env
python3 - "$SRC" icon/icon-1024.png "$RADIUS" <<'PY'
from PIL import Image, ImageDraw, ImageFilter
import sys
src, out, radius_frac = sys.argv[1], sys.argv[2], float(sys.argv[3])

im = Image.open(src).convert("RGBA")
W, H = im.size

# 1) bbox du squircle = pixels SATURÉS (le squircle est coloré ; le fond est gris désaturé,
#    l'ombre portée aussi → exclus). MinFilter retire les pixels parasites isolés.
sat = im.convert("RGB").convert("HSV").split()[1]
mask = sat.point(lambda v: 255 if v > 60 else 0).filter(ImageFilter.MinFilter(3))
bb = mask.getbbox()
if not bb:
    raise SystemExit("squircle introuvable (image trop désaturée ?)")
x0, y0, x1, y1 = bb
cx, cy = (x0 + x1) // 2, (y0 + y1) // 2
side = max(x1 - x0, y1 - y0)
half = side // 2
L, T = max(0, cx - half), max(0, cy - half)
R, B = min(W, cx + half), min(H, cy + half)
crop = im.crop((L, T, R, B))

# 2) travail en haute résolution + masque coins arrondis (clippe les coins gris résiduels)
WORK = 1024
crop = crop.resize((WORK, WORK), Image.LANCZOS)
m = Image.new("L", (WORK, WORK), 0)
ImageDraw.Draw(m).rounded_rectangle([0, 0, WORK - 1, WORK - 1],
                                    radius=int(radius_frac * WORK), fill=255)
crop.putalpha(m)

# 3) grille Apple : corps 824 centré dans un canevas 1024 transparent (marge = ombre système)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
body = crop.resize((824, 824), Image.LANCZOS)
canvas.paste(body, ((1024 - 824) // 2, (1024 - 824) // 2), body)
canvas.save(out)
print(f"   squircle détecté: {side}px  →  master 1024 (corps 824)")
PY

echo "▸ Génération du .icns (toutes tailles)"
ICONSET="$(mktemp -d)/Murmure.iconset"
mkdir -p "$ICONSET"
for sz in 16 32 128 256 512; do
  sips -z "$sz" "$sz"             icon/icon-1024.png --out "$ICONSET/icon_${sz}x${sz}.png"    >/dev/null
  d=$((sz * 2)); sips -z "$d" "$d" icon/icon-1024.png --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o icon/Murmure.icns
rm -rf "$(dirname "$ICONSET")"

echo "✅ icon/Murmure.icns + icon/icon-1024.png"
