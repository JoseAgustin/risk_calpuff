#!/usr/bin/env bash
# ==============================================================================
# procesa_conc.sh
# Descripción: Procesa archivos de concentración generados por CALPOST para
#              calcular el riesgo cancerígeno por receptor (x_km, y_km).
#
# Metodología:
#   1. Lee los valores IUR (Inhalation Unit Risk) desde iur.txt
#   2. Por cada contaminante con archivo RANK(0)_*_481HR_CONC.CSV:
#      - Convierte concentración de g/m³ a µg/m³
#      - Multiplica por IUR para obtener riesgo cancerígeno
#   3. Consolida todos los contaminantes en un único CSV por receptor
#
# Entrada:
#   - iur.txt                        : tabla de valores IUR por sustancia
#   - RANK(0)_*_481HR_CONC.CSV       : archivos de concentración de CALPOST
#
# Salida:
#   - concentraciones_combinadas.csv : riesgo por receptor y contaminante
#
# Uso:
#   bash procesa_conc.sh
# ==============================================================================

set -euo pipefail   # -e: abortar en error; -u: error si variable no definida; -o pipefail: captura errores en pipes
IFS=$'\n\t'         # Separador de campos: solo saltos de línea y tabuladores (evita divisiones por espacios accidentales)

# ------------------------------------------------------------------------------
# Configuración general
# ------------------------------------------------------------------------------
OUT="concentraciones_combinadas.csv"               # Archivo CSV de salida con riesgos combinados
TMPDIR="$(mktemp -d -t tmp_conc_XXXX)"            # Directorio temporal único para archivos intermedios
trap 'rm -rf "$TMPDIR"' EXIT                       # Limpieza automática del directorio temporal al salir (éxito o error)

# ==============================================================================
# PASO 1: Cargar tabla de IUR (Inhalation Unit Risk) desde iur.txt
# Formato esperado: Substancia<sep>IUR  (separado por espacios o tabuladores)
# El IUR es el riesgo cancerígeno incremental por unidad de concentración [1/(µg/m³)]
# ==============================================================================
declare -A IUR   # Arreglo asociativo: clave=compuesto(mayúsculas), valor=IUR numérico

while read -r line; do
  # Saltar líneas vacías (solo espacios) o que sean el encabezado
  [[ -z "${line// /}" ]] && continue
  [[ "$line" =~ ^[[:space:]]*Substancia ]] && continue

  # Extraer columna 1 (nombre del compuesto) y última columna (valor IUR)
  comp=$(echo "$line" | awk '{print $1}')
  val=$(echo "$line"  | awk '{print $NF}')

  # Normalizar nombre: convertir a MAYÚSCULAS y eliminar espacios internos
  # Esto garantiza coincidencia consistente con los nombres de los archivos CSV
  comp=$(echo "$comp" | tr '[:lower:]' '[:upper:]' | tr -d ' ')

  IUR["$comp"]="$val"   # Almacenar en el arreglo asociativo
done < iur.txt

# Mostrar los valores IUR cargados para verificación
echo "IUR cargados:"
for k in "${!IUR[@]}"; do
  echo "  $k = ${IUR[$k]}"
done
echo

# ==============================================================================
# PASO 2: Procesar cada archivo de concentración de CALPOST
# Patrón de archivo: RANK(0)_<COMPUESTO>_481HR_CONC.CSV
# Contiene: coordenadas de receptor (x_km, y_km) y concentración en g/m³
# ==============================================================================
shopt -s nullglob   # Si el glob no encuentra archivos, devuelve lista vacía (no falla)

for file in RANK\(0\)_*_481HR_CONC.CSV; do   # Los paréntesis se escapan para el shell
  [[ ! -f "$file" ]] && continue              # Saltar si por alguna razón no es un archivo regular

  # ---- Extraer nombre del compuesto desde el nombre del archivo ----
  base="${file#RANK(0)_}"                     # Eliminar prefijo  "RANK(0)_"
  comp="${base%_481HR_CONC.CSV}"              # Eliminar sufijo   "_481HR_CONC.CSV"
  comp_u=$(echo "$comp" | tr '[:lower:]' '[:upper:]' | tr -d ' ')   # Normalizar a mayúsculas

  echo "Procesando: $file -> $comp_u"

  # ---- Verificar que existe IUR para este compuesto ----
  if [[ -z "${IUR[$comp_u]:-}" ]]; then
    echo "  ADVERTENCIA: no hay IUR para '$comp_u' (se omitirá)."
    continue   # Saltar compuestos sin IUR definido
  fi

  iur_val="${IUR[$comp_u]}"   # Recuperar el valor IUR del compuesto actual

  # ---- Calcular riesgo cancerígeno por receptor con awk ----
  # Para cada fila válida del CSV de CALPOST:
  #   1. Limpiar espacios iniciales/finales en cada campo
  #   2. Validar que la fila tiene al menos 3 campos numéricos (x, y, conc)
  #   3. Convertir concentración: g/m³ → µg/m³  (× 1000)
  #   4. Calcular riesgo: µg/m³ × IUR  →  riesgo adimensional
  #   5. Escribir: x_km, y_km, riesgo  en el archivo temporal del compuesto
  awk -v iur="$iur_val" -F',' '
    BEGIN{ OFS="," }
    {
      # Eliminar espacios y tabuladores al inicio/fin de cada campo
      for(i=1;i<=NF;i++) gsub(/^[ \t]+|[ \t]+$/,"",$i)

      # Filtrar solo filas con coordenadas numéricas y concentración válida
      if (NF>=3 && $1 ~ /^[0-9]/ && $2 ~ /^[ \t]*[0-9]/ && $3 ~ /[0-9Ee.+-]/) {
        x = $1 + 0          # Coordenada X del receptor [km]
        y = $2 + 0          # Coordenada Y del receptor [km]
        v = $3 + 0          # Concentración en g/m³
        ug   = v * 1000.0   # Conversión a µg/m³
        risk = ug * iur     # Riesgo cancerígeno incremental (adimensional)
        printf("%.6f,%.6f,%.12e\n", x, y, risk)   # 6 decimales en coords, notación científica en riesgo
      }
    }
  ' "$file" > "$TMPDIR/${comp_u}.csv"   # Un CSV temporal por compuesto
done

# ==============================================================================
# PASO 3: Validar que al menos un compuesto fue procesado exitosamente
# ==============================================================================
files=( "$TMPDIR"/*.csv )
if [[ ${#files[@]} -eq 0 ]]; then
  echo "No se procesó ningún archivo (¿existen los RANK(0)_*_481HR_CONC.CSV?)."
  exit 1
fi

# ==============================================================================
# PASO 4: Construir lista única y ordenada de receptores (x_km, y_km)
# Se combina la columna x,y de todos los archivos temporales y se eliminan duplicados
# ==============================================================================
awk -F',' '{ printf("%.6f,%.6f\n",$1+0,$2+0) }' "$TMPDIR"/*.csv \
  | sort -u > "$TMPDIR/receptores.txt"   # Receptores únicos ordenados lexicográficamente

# ==============================================================================
# PASO 5: Escribir encabezado del CSV final
# Formato: x_km,y_km,COMP1,COMP2,...,COMPn  (compuestos en orden alfabético)
# ==============================================================================
echo "****  Encabezado   *****"
echo -n "x_km,y_km" > "$OUT"   # Iniciar archivo de salida con columnas de coordenadas

# Recopilar nombres de compuestos desde los archivos temporales generados
comps=()
for f in "$TMPDIR"/*.csv; do
  name=$(basename "$f" .csv)   # El nombre del archivo temporal ES el nombre del compuesto
  comps+=("$name")
done

# Ordenar alfabéticamente para garantizar orden reproducible de columnas
IFS=$'\n' sorted_comps=($(printf "%s\n" "${comps[@]}" | sort))

# Agregar cada compuesto como columna en el encabezado
for c in "${sorted_comps[@]}"; do
  echo -n ",$c" >> "$OUT"
done
echo >> "$OUT"   # Salto de línea al final del encabezado

# ==============================================================================
# PASO 6: Rellenar el CSV final receptor por receptor
# Para cada receptor (x,y) se busca el riesgo de cada compuesto.
# Si un receptor no tiene valor para un compuesto, se asigna 0 (no detectado).
# ==============================================================================
echo "****  Junta  RECEPTORES  ***"

while IFS= read -r coord; do
  # Separar coordenadas x e y desde la línea del archivo de receptores
  x=$(echo "$coord" | cut -d',' -f1)
  y=$(echo "$coord" | cut -d',' -f2)

  printf "%s,%s" "$x" "$y" >> "$OUT"   # Escribir coordenadas al inicio de la fila

  # Para cada compuesto (en el orden del encabezado), buscar el riesgo del receptor actual
  for c in "${sorted_comps[@]}"; do
    # Buscar en el CSV temporal del compuesto la fila que coincide con x,y
    # Si no se encuentra, awk devuelve "0" (receptor sin concentración registrada)
    val=$(awk -F',' -v xx="$x" -v yy="$y" \
      '$1+0==xx+0 && $2+0==yy+0 { printf "%s",$3; found=1; exit }
       END{ if(!found) printf "0" }' \
      "$TMPDIR/$c.csv")

    printf ",%s" "$val" >> "$OUT"   # Agregar valor (o 0) a la fila del receptor
  done

  echo >> "$OUT"   # Salto de línea al finalizar todos los compuestos del receptor
done < "$TMPDIR/receptores.txt"

echo "Generado: $OUT"
# El trap definido al inicio eliminará automáticamente $TMPDIR al salir
