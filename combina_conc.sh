#!/bin/bash
# ==============================================================================
# combina_conc.sh
# Descripción: Combina archivos de concentración horaria generados por CALPOST
#              en un único CSV consolidado por receptor (x_km, y_km).
#
# Contexto:
#   CALPOST genera un archivo por contaminante con el patrón:
#   RANK(0)_<COMPUESTO>_8760HR_CONC.CSV  (8760 horas = año completo 2023)
#   Cada archivo contiene coordenadas de receptor y concentración en g/m³.
#
# Estrategia:
#   Las coordenadas se extraen una sola vez del primer archivo (son idénticas
#   en todos los archivos porque comparten la misma malla de receptores).
#   Luego se extrae solo la columna de valores de cada compuesto y se ensambla
#   fila por fila para garantizar alineación exacta entre receptores y valores.
#
# Entrada:
#   - RANK(0)_*_8760HR_CONC.CSV  : archivos de concentración de CALPOST
#                                   (uno por contaminante, en el directorio actual)
# Salida:
#   - concentraciones_combinadas.csv : tabla con columnas x_km, y_km, COMP1, COMP2, ...
#
# Uso:
#   bash combina_conc.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# Configuración general
# ------------------------------------------------------------------------------
OUT="concentraciones_combinadas.csv"       # Archivo CSV de salida consolidado
TMPDIR=$(mktemp -d)                        # Directorio temporal para archivos intermedios
                                           # (se crea con nombre único para evitar colisiones)

# ==============================================================================
# PASO 1: Descubrir archivos de entrada
# Se usa find con -print0 / read -d '' para manejar nombres con espacios o
# caracteres especiales de forma segura.
# ==============================================================================
FILES=()
while IFS= read -r -d '' f; do
    FILES+=("$f")
done < <(find . -maxdepth 1 -type f -name 'RANK(0)_*_8760HR_CONC.CSV' -print0)

# Abortar si no hay archivos que procesar
if [ ${#FILES[@]} -eq 0 ]; then
    echo "No se encontraron archivos."
    exit 1
fi

echo "Archivos detectados:"
printf " - %s\n" "${FILES[@]}"
echo ""

# ==============================================================================
# PASO 2: Extraer coordenadas de receptores desde el primer archivo
#
# Todos los archivos comparten la misma malla de receptores (mismo x_km, y_km),
# por lo que basta leerlas una sola vez del primer archivo.
#
# Filtros aplicados:
#   - grep -v "RECEPTOR" : elimina líneas de encabezado que contienen esa palabra
#   - grep -E '^[[:space:]]*[0-9]' : conserva solo filas que inician con número
#   - awk : elimina espacios en las columnas 1 y 2, y las imprime como "x,y"
# ==============================================================================
FIRST="${FILES[0]}"
echo "Extrayendo x_km,y_km desde: $FIRST"

grep -v "RECEPTOR" "$FIRST" | \
grep -E '^[[:space:]]*[0-9]'  | \
awk -F',' '{
    gsub(/ /,"",$1);   # Eliminar espacios en columna x_km
    gsub(/ /,"",$2);   # Eliminar espacios en columna y_km
    print $1","$2      # Imprimir par de coordenadas separado por coma
}' > "$TMPDIR/coords.csv"   # Una línea "x,y" por receptor

# ==============================================================================
# PASO 3: Extraer columna de concentración de cada archivo
#
# Por cada archivo de compuesto se genera un archivo .col con una sola columna:
# el valor de concentración (campo 3) por receptor, en el mismo orden que coords.csv.
# Este enfoque columnar permite ensamblar el CSV final fila por fila sin riesgo
# de desalineación entre compuestos.
# ==============================================================================
COLNAMES=()   # Acumulará los nombres de compuestos en el orden de procesamiento

for f in "${FILES[@]}"; do

    base=$(basename "$f")
    # Extraer el nombre del compuesto: es el segundo token separado por "_"
    # Ejemplo: RANK(0)_SO2_8760HR_CONC.CSV  →  SO2
    name=$(echo "$base" | awk -F'_' '{print $2}')

    COLNAMES+=("$name")   # Registrar nombre para el encabezado y el ensamblado

    echo "Procesando $f → columna $name"

    grep -v "RECEPTOR" "$f" | \
    grep -E '^[[:space:]]*[0-9]' | \
    awk -F',' '{
        gsub(/ /,"",$3);   # Eliminar espacios en la columna de concentración
        print $3           # Imprimir solo el valor de concentración
    }' > "$TMPDIR/$name.col"   # Archivo temporal: una línea de concentración por receptor

done

# ==============================================================================
# PASO 4: Escribir encabezado del CSV final
# Formato: x_km,y_km,COMP1,COMP2,...,COMPn
# Los compuestos aparecen en el mismo orden en que fueron descubiertos por find.
# ==============================================================================
echo -n "x_km,y_km" > "$OUT"
for c in "${COLNAMES[@]}"; do
    echo -n ",$c" >> "$OUT"   # Agregar cada compuesto como columna adicional
done
echo "" >> "$OUT"   # Salto de línea al cerrar el encabezado

# ==============================================================================
# PASO 5: Ensamblar el CSV final fila por fila
#
# Se itera por número de línea (1 a NROWS) para garantizar que cada receptor
# recibe exactamente los valores que le corresponden de cada compuesto.
# sed -n "${i}p" extrae la línea i-ésima del archivo correspondiente.
#
# Si se usara paste en su lugar, un archivo .col con longitud diferente
# podría causar desalineación silenciosa; el bucle explícito lo evita.
# ==============================================================================
NROWS=$(wc -l < "$TMPDIR/coords.csv")   # Total de receptores a procesar

for ((i=1; i<=NROWS; i++)); do
    # Leer las coordenadas del receptor i-ésimo
    ROW=$(sed -n "${i}p" "$TMPDIR/coords.csv")

    # Concatenar el valor de concentración de cada compuesto en la misma fila
    for c in "${COLNAMES[@]}"; do
        val=$(sed -n "${i}p" "$TMPDIR/$c.col")   # Concentración del compuesto c para el receptor i
        ROW="$ROW,$val"
    done

    echo "$ROW" >> "$OUT"   # Escribir la fila completa en el CSV final
done

# ==============================================================================
# Resumen final
# ==============================================================================
echo ""
echo "Archivo generado correctamente: $OUT"
echo "Encabezado resultante:"
head -1 "$OUT"

# Nota: $TMPDIR NO se elimina automáticamente en este script.
# Para limpieza automática, agregar al inicio:
#   trap 'rm -rf "$TMPDIR"' EXIT
