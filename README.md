# risk_calpuff

Sistema de simulación de dispersión atmosférica para la **evaluación de riesgo toxicológico** (cancerígeno y no cancerígeno) de emisiones industriales, utilizando el modelo CALPUFF sobre datos meteorológicos del año 2023 para la región de Nuevo León (NL).

---

## Tabla de Contenidos

- [Resumen General](#resumen-general)
- [Arquitectura de Directorios](#arquitectura-de-directorios)
- [Archivos del Repositorio](#archivos-del-repositorio)
- [Metodología](#metodología)
- [Flujo de Ejecución](#flujo-de-ejecución)
- [Scripts de Procesamiento](#scripts-de-procesamiento)
- [Salidas del Sistema](#salidas-del-sistema)
- [Dependencias y Herramientas](#dependencias-y-herramientas)

---

## Resumen General

El sistema implementa una cadena de procesamiento completa para estimar el riesgo toxicológico al que están expuestas las comunidades cercanas a zonas industriales. Parte de simulaciones de dispersión atmosférica con emisiones unitarias (1 Mg/año) para calcular factores de dilución por empresa, que luego se escalan con las emisiones reales de cada planta para obtener concentraciones ambientales. A partir de estas concentraciones y los parámetros toxicológicos (IUR y concentración de referencia), se estiman los riesgos cancerígeno y no cancerígeno por empresa y por contaminante.

---

## Arquitectura de Directorios

```
$HOME/NL/
├── FCST/          # Simulación principal: 40 fuentes × 12 especies + CALMET.DAT (meteorología 2023)
├── S0148/         # Simulación completa: 48 fuentes × 12 especies
├── S0112/         # Fuentes 01–12 × 12 especies
├── S1324/         # Fuentes 13–24 × 12 especies
├── S2536/         # Fuentes 25–36 × 12 especies
├── S3740/         # Fuentes 37–40 × 4 fuentes × 12 especies
├── S3748/         # Fuentes 37–48 × 12 especies
├── CALPUFF/       # Ejecutable del modelo de dispersión (calpuff.x)
└── CALPOST/       # Ejecutable de postprocesamiento (calpost.exe)
```

Cada subdirectorio de simulación (`S01xx`–`S37xx`, `FCST`) contiene:

- `CALPUFF.INP` — configuración del modelo de dispersión atmosférica
- `calpost.inp` — configuración del postprocesador de concentraciones
- Enlace simbólico a `FCST/CALMET.DAT` — campos meteorológicos 3D compartidos (año 2023 completo)

---

## Archivos del Repositorio

| Archivo | Descripción |
|---|---|
| `CALPUFF.INP` | Archivo de configuración de referencia para el modelo CALPUFF |
| `calpost.inp` | Archivo de configuración de referencia para CALPOST |
| `combina_conc.sh` | Script que concatena las salidas de CALPOST (archivos `RANK(0)_*_8760HR_CONC.CSV`) en un único CSV por malla de receptores |
| `procesa_conc.sh` | Script que aplica los valores IUR a las concentraciones para calcular el riesgo cancerígeno por receptor y contaminante |
| `Mapas.ipynb` | Notebook de Python para visualización geoespacial de los riesgos calculados |
| `iur.txt` | Tabla de valores IUR (Inhalation Unit Risk) por sustancia, usada por `procesa_conc.sh` |

---

## Metodología

### 1. Datos meteorológicos

Los campos meteorológicos tridimensionales (`CALMET.DAT`) abarcan el año 2023 completo (8 760 horas) y son compartidos por todos los subdirectorios de simulación mediante un enlace simbólico, evitando duplicación y garantizando consistencia meteorológica.

### 2. Factor de dilución

Cada subdirectorio simula una empresa o grupo de empresas con una emisión unitaria de **1 Mg/año por especie**. Al usar esta emisión unitaria se obtiene directamente el **factor de dilución** (concentración por unidad de emisión) específico de cada empresa. Posteriormente, este factor se escala con las emisiones reales de cada planta para obtener las concentraciones ambientales representativas.

| Directorio | Fuentes simuladas | Especies |
|---|---|---|
| `FCST` | 1–40 (40 fuentes) | 12 |
| `S0148` | 1–48 (48 fuentes) | 12 |
| `S0112` | 1–12 | 12 |
| `S1324` | 13–24 | 12 |
| `S2536` | 25–36 | 12 |
| `S3740` | 37–40 | 12 |
| `S3748` | 37–48 | 12 |

### 3. Cálculo de concentraciones ambientales

CALPOST genera un archivo por contaminante con la concentración media anual en cada receptor de la malla. El script `combina_conc.sh` consolida estos archivos en una tabla única `concentraciones_combinadas.csv` con columnas `x_km`, `y_km`, `COMP1`, `COMP2`, …

### 4. Estimación de riesgo toxicológico

El script `procesa_conc.sh` lee los valores **IUR** (*Inhalation Unit Risk*, riesgo cancerígeno incremental por unidad de concentración en µg/m³) desde `iur.txt` y calcula para cada receptor y contaminante:

```
concentración [µg/m³] = concentración [g/m³] × 1 000
riesgo cancerígeno    = concentración [µg/m³] × IUR
```

El cálculo de riesgo no cancerígeno y la agregación por empresa se realizan fuera de línea en Excel, utilizando el archivo `concentraciones_combinadas.csv` como entrada.

---

## Flujo de Ejecución

```
[Ambiente Intel OneAPI]
        │
        ▼
[calpuff.x + CALPUFF.INP]
  Modelo de dispersión atmosférica Lagrangiano
        │  genera archivos de concentración por hora
        ▼
[calpost.exe + calpost.inp]
  Postprocesamiento → RANK(0)_<COMPUESTO>_8760HR_CONC.CSV
        │              (uno por contaminante)
        ▼
[combina_conc.sh]
  Concatena archivos por compuesto en un CSV por receptor
        │  → concentraciones_combinadas.csv
        ▼
[procesa_conc.sh + iur.txt]
  Aplica IUR → riesgo cancerígeno por receptor y compuesto
        │  → concentraciones_combinadas.csv (con riesgos)
        ▼
[Excel]
  Escala con emisiones reales, agrega por empresa y sustancia
        │  → riesgos.csv  riesgosC.csv  ncancerI.csv  ncancerC.csv
        ▼
[Mapas.ipynb]
  Visualización geoespacial de riesgos sobre mapa de la región
```

### Comandos de ejecución por directorio de simulación

```bash
# 1. Cargar compilador Intel (requerido por CALPUFF y CALPOST)
source /opt/intel/oneapi/setvars.sh intel64

# 2. Entrar al directorio de simulación
cd S0148

# 3. Ejecutar el modelo de dispersión atmosférica
../CALPUFF/calpuff.x CALPUFF.INP

# 4. Ejecutar el postprocesador de concentraciones
../CALPOST/calpost.exe calpost.inp

# 5. Combinar archivos de concentración por compuesto
bash combina_conc.sh

# 6. Calcular riesgo cancerígeno aplicando IUR
bash ../FCST/procesa_conc.sh

# 7. Descargar concentraciones_combinadas.csv para cálculo en Excel
```

---

## Scripts de Procesamiento

### `combina_conc.sh`

Combina los archivos de salida de CALPOST en un único CSV consolidado.

**Entrada:** archivos `RANK(0)_<COMPUESTO>_8760HR_CONC.CSV` en el directorio actual  
**Salida:** `concentraciones_combinadas.csv` con columnas `x_km,y_km,COMP1,COMP2,...`

**Estrategia:** extrae las coordenadas de receptores una sola vez del primer archivo (la malla es idéntica para todos los compuestos) y luego ensambla fila por fila para garantizar alineación exacta.

```bash
bash combina_conc.sh
```

### `procesa_conc.sh`

Aplica los factores IUR para calcular el riesgo cancerígeno incremental por receptor.

**Entradas:** archivos `RANK(0)_*_481HR_CONC.CSV` + `iur.txt`  
**Salida:** `concentraciones_combinadas.csv` con riesgo cancerígeno `[adimensional]` por receptor y contaminante

**Conversión de unidades:** g/m³ → µg/m³ (× 1 000) → riesgo (× IUR)

```bash
bash ../FCST/procesa_conc.sh
```

---

## Salidas del Sistema

| Archivo | Contenido | Generado por |
|---|---|---|
| `concentraciones_combinadas.csv` | Concentraciones o riesgos por receptor y compuesto | `combina_conc.sh` / `procesa_conc.sh` |
| `riesgos.csv` | Riesgo cancerígeno agregado por industria | Excel |
| `riesgosC.csv` | Riesgo cancerígeno agregado por contaminante | Excel |
| `ncancerI.csv` | Riesgo no cancerígeno agregado por industria | Excel |
| `ncancerC.csv` | Riesgo no cancerígeno agregado por sustancia | Excel |

---

## Dependencias y Herramientas

| Herramienta | Versión / Fuente | Función |
|---|---|---|
| **CALPUFF** | [src.com/calpuff](http://www.src.com/calpuff/calpuff1.htm) | Modelo de dispersión atmosférica Lagrangiano |
| **CALPOST** | src.com/calpuff | Postprocesador de concentraciones de CALPUFF |
| **CALMET.DAT** | Año 2023 completo (8 760 h) | Campos meteorológicos 3D de entrada |
| **Intel oneAPI** | `/opt/intel/oneapi/` | Compilador Fortran para ejecutables CALPUFF/CALPOST |
| **Bash** | ≥ 4.0 | Ejecución de `combina_conc.sh` y `procesa_conc.sh` |
| **Python 3** | con `pandas`, `geopandas`, `matplotlib` | Visualización geoespacial en `Mapas.ipynb` |
| **Excel** | — | Cálculo de riesgos por empresa y contaminante |

---

## Licencia

Este proyecto está bajo la licencia [MIT](LICENSE).
