#!/usr/bin/env bash
# ==============================================================================
# procesa_conc.sh
# Descripción: Procesa archivos de concentración generados por CALPOST para
#              calcular el riesgo cancerígeno (CR) y no cancerígeno (NCancer)
#              por receptor (x_km, y_km) y contaminante.
#
# Metodología:
#   1. Lee IUR y REL desde iur_rel.txt
#   2. Por cada contaminante con archivo RANK(0)_*_8760HR_CONC.CSV:
#      - Convierte concentración: g/m³ → µg/m³  (× 1000)
#      - Riesgo cancerígeno  CR      = µg/m³ × IUR        (si IUR > 0)
#      - Riesgo no cancerígeno NC    = µg/m³ × 100 / REL  (si REL > 0)
#   3. Genera dos archivos de salida:
#      - riesgos.csv  : riesgo cancerígeno  por receptor y compuesto
#      - ncancer.csv  : riesgo no cancerígeno por receptor y compuesto
#
# Entrada:
#   - iur_rel.txt                    : tabla con columnas Substancia, IUR, REL
#   - RANK(0)_*_8760HR_CONC.CSV       : archivos de concentración de CALPOST
#
# Salida:
#   - riesgos.csv   : CR  por receptor y contaminante (IUR > 0)
#   - ncancer.csv   : NC  por receptor y contaminante (REL > 0)
#
# Uso:
#   bash procesa_conc.sh
# ==============================================================================

set -euo pipefail   # Abortar en error; error si variable no definida; captura errores en pipes
IFS=$'\n\t'         # Separador de campos: saltos de línea y tabuladores

# ------------------------------------------------------------------------------
# Configuración general
# ------------------------------------------------------------------------------
OUT_CR="riesgos.csv"                               # Salida: riesgo cancerígeno
OUT_NC="ncancer.csv"                               # Salida: riesgo no cancerígeno
TMPDIR="$(mktemp -d -t tmp_conc_XXXX)"            # Directorio temporal para archivos intermedios
trap 'rm -rf "$TMPDIR"' EXIT                       # Limpieza automática al salir

# ==============================================================================
# PASO 1: Cargar tabla de parámetros toxicológicos desde iur_rel.txt
#
# Formato esperado (separado por tabuladores):
#   Substancia    IUR     REL
#
# Casos especiales:
#   - IUR vacío o 0  → sustancia sin riesgo cancerígeno (se omite en riesgos.csv)
#   - REL vacío o 0  → sustancia sin riesgo no cancerígeno (se omite en ncancer.csv)
# ==============================================================================
declare -A IUR        # Arreglo: clave=compuesto(mayúsculas), valor=IUR numérico
declare -A REL        # Arreglo: clave=compuesto(mayúsculas), valor=REL numérico

while IFS=$'\t' read -r comp iur_val rel_val; do
  # Saltar líneas vacías o encabezado
  [[ -z "${comp// /}" ]] && continue
  [[ "$comp" =~ ^[[:space:]]*Substancia ]] && continue

  # Normalizar nombre: MAYÚSCULAS y sin espacios internos
  comp_u=$(echo "$comp" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

  # Limpiar espacios en los valores
  iur_val=$(echo "$iur_val" | tr -d ' ')
  rel_val=$(echo "$rel_val" | tr -d ' ')

  # Almacenar IUR (dejar vacío si no tiene valor)
  IUR["$comp_u"]="${iur_val:-0}"

  # Almacenar REL (dejar 0 si está vacío → indica sin dato de REL)
  REL["$comp_u"]="${rel_val:-0}"

done < iur_rel.txt

# Mostrar parámetros cargados para verificación
echo "Parámetros toxicológicos cargados:"
echo "  $(printf '%-20s %15s %15s' 'SUSTANCIA' 'IUR' 'REL')"
echo "  $(printf '%-20s %15s %15s' '---------' '---' '---')"
for k in $(echo "${!IUR[@]}" | tr ' ' '\n' | sort); do
  printf "  %-20s %15s %15s\n" "$k" "${IUR[$k]}" "${REL[$k]}"
done
echo

# ==============================================================================
# PASO 2: Procesar cada archivo de concentración de CALPOST
#
# Por cada compuesto se generan hasta dos archivos temporales:
#   $TMPDIR/<COMP>_cr.csv  → columna de riesgo cancerígeno  (si IUR > 0)
#   $TMPDIR/<COMP>_nc.csv  → columna de riesgo no cancerígeno (si REL > 0)
#
# Ambos comparten el mismo archivo de coordenadas (extraído una sola vez).
# ==============================================================================
shopt -s nullglob

# Listas de compuestos con datos válidos para cada tipo de riesgo
comps_cr=()   # Compuestos con IUR > 0 (riesgo cancerígeno)
comps_nc=()   # Compuestos con REL > 0 (riesgo no cancerígeno)
coords_saved=false

for file in RANK\(0\)_*_8760HR_CONC.CSV; do
  [[ ! -f "$file" ]] && continue

  # Extraer nombre del compuesto desde el nombre del archivo
  base="${file#RANK(0)_}"
  comp="${base%_8760HR_CONC.CSV}"
  comp_u=$(echo "$comp" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

  echo "Procesando: $file → $comp_u"

  # Verificar que el compuesto tiene parámetros en iur_rel.txt
  if [[ -z "${IUR[$comp_u]+set}" ]]; then
    echo "  ADVERTENCIA: '$comp_u' no está en iur_rel.txt (se omitirá)."
    continue
  fi

  iur_val="${IUR[$comp_u]}"
  rel_val="${REL[$comp_u]}"

  # ---- Extraer coordenadas de receptores (solo la primera vez) ----
  # Todos los archivos comparten la misma malla de receptores
  if [[ "$coords_saved" == false ]]; then
    grep -v "RECEPTOR" "$file" | \
    grep -E '^[[:space:]]*[0-9]' | \
    awk -F',' '{
      gsub(/^[ \t]+|[ \t]+$/,"",$1)
      gsub(/^[ \t]+|[ \t]+$/,"",$2)
      printf("%.6f,%.6f\n", $1+0, $2+0)
    }' > "$TMPDIR/coords.csv"
    coords_saved=true
    echo "  Coordenadas extraídas: $(wc -l < "$TMPDIR/coords.csv") receptores"
  fi

  # ---- Calcular riesgo cancerígeno (CR) si IUR > 0 ----
  if awk "BEGIN{ exit !($iur_val > 0) }"; then
    echo "  → Calculando CR  (IUR=$iur_val)"
    awk -v iur="$iur_val" -F',' '
      BEGIN{ OFS="," }
      {
        for(i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/,"",$i)
        if (NF>=3 && $1 ~ /^[0-9]/ && $3 ~ /[0-9Ee.+-]/) {
          ug   = ($3 + 0) * 1000.0    # g/m³ → µg/m³
          risk = ug * iur              # Riesgo cancerígeno (adimensional)
          printf("%.6f,%.6f,%.12e\n", $1+0, $2+0, risk)
        }
      }
    ' "$file" > "$TMPDIR/${comp_u}_cr.csv"
    comps_cr+=("$comp_u")
  else
    echo "  → Sin CR (IUR=0 o no definido)"
  fi

  # ---- Calcular riesgo no cancerígeno (NC) si REL > 0 ----
  if awk "BEGIN{ exit !($rel_val > 0) }"; then
    echo "  → Calculando NC  (REL=$rel_val µg/m³)"
    awk -v rel="$rel_val" -F',' '
      BEGIN{ OFS="," }
      {
        for(i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/,"",$i)
        if (NF>=3 && $1 ~ /^[0-9]/ && $3 ~ /[0-9Ee.+-]/) {
          ug    = ($3 + 0) * 1000.0    # g/m³ → µg/m³
          ncr   = ug * 100.0 / rel     # Índice de peligro no cancerígeno (%)
          printf("%.6f,%.6f,%.12e\n", $1+0, $2+0, ncr)
        }
      }
    ' "$file" > "$TMPDIR/${comp_u}_nc.csv"
    comps_nc+=("$comp_u")
  else
    echo "  → Sin NC (REL=0 o no definido)"
  fi

done

# ==============================================================================
# PASO 3: Validar que se procesó al menos un compuesto
# ==============================================================================
if [[ ${#comps_cr[@]} -eq 0 && ${#comps_nc[@]} -eq 0 ]]; then
  echo "ERROR: No se procesó ningún compuesto."
  exit 1
fi

echo ""
echo "Compuestos con CR : ${comps_cr[*]:-ninguno}"
echo "Compuestos con NC : ${comps_nc[*]:-ninguno}"
echo ""

# ==============================================================================
# FUNCIÓN: ensamblar_csv
# Genera el CSV final combinando coordenadas con las columnas de riesgo.
# Argumentos:
#   $1 = archivo de salida
#   $2 = sufijo de los archivos temporales (_cr o _nc)
#   $3 = array con nombres de compuestos (pasado como "comps_cr[@]" o "comps_nc[@]")
# ==============================================================================
ensamblar_csv() {
  local out_file="$1"
  local sufijo="$2"
  local -n comps_ref="$3"   # nameref al array de compuestos

  # Ordenar compuestos alfabéticamente para columnas reproducibles
  IFS=$'\n' local sorted=($(printf "%s\n" "${comps_ref[@]}" | sort))

  # ---- Encabezado ----
  echo -n "x_km,y_km" > "$out_file"
  for c in "${sorted[@]}"; do
    echo -n ",$c" >> "$out_file"
  done
  echo >> "$out_file"

  # ---- Datos: un receptor por fila ----
  while IFS= read -r coord; do
    x=$(echo "$coord" | cut -d',' -f1)
    y=$(echo "$coord" | cut -d',' -f2)
    printf "%s,%s" "$x" "$y" >> "$out_file"

    for c in "${sorted[@]}"; do
      # Buscar valor en el archivo temporal del compuesto para este receptor
      # Si no existe (receptor sin dato), escribir 0
      val=$(awk -F',' -v xx="$x" -v yy="$y" \
        '$1+0==xx+0 && $2+0==yy+0 { printf "%s",$3; found=1; exit }
         END{ if(!found) printf "0" }' \
        "$TMPDIR/${c}${sufijo}.csv")
      printf ",%s" "$val" >> "$out_file"
    done
    echo >> "$out_file"
  done < "$TMPDIR/coords.csv"

  echo "Generado: $out_file  ($(( $(wc -l < "$out_file") - 1 )) receptores, ${#sorted[@]} compuestos)"
}

# ==============================================================================
# PASO 4: Generar archivos de salida
# ==============================================================================
if [[ ${#comps_cr[@]} -gt 0 ]]; then
  echo "Ensamblando $OUT_CR ..."
  ensamblar_csv "$OUT_CR" "_cr" comps_cr
else
  echo "AVISO: Ningún compuesto tiene IUR > 0; no se genera $OUT_CR."
fi

if [[ ${#comps_nc[@]} -gt 0 ]]; then
  echo "Ensamblando $OUT_NC ..."
  ensamblar_csv "$OUT_NC" "_nc" comps_nc
else
  echo "AVISO: Ningún compuesto tiene REL > 0; no se genera $OUT_NC."
fi

echo ""
echo "Proceso completado."
# El trap elimina $TMPDIR automáticamente al salir
