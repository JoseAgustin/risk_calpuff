# risk_calpuff
# Descripción del Proyecto: Simulaciones de Determinación de Riesgo con CALPUFF

## Resumen General

Sistema de simulación de dispersión atmosférica para la **evaluación de riesgo toxicológico** (cancerígeno y no cancerígeno) de emisiones industriales, utilizando el modelo CALPUFF sobre datos meteorológicos del año 2023 para la región de Nuevo León (NL).

---

## Arquitectura de Directorios

```
$HOME/NL/
├── FCST/          # Simulación principal: 40 fuentes × 12 especies + CALMET.DAT
├── S0148/         # Simulación completa: 48 fuentes × 12 especies
├── S0112/         # Fuentes 01–12 × 12 especies
├── S1324/         # Fuentes 13–24 × 12 especies
├── S2536/         # Fuentes 25–36 × 12 especies
├── S3740/         # Fuentes 37–40 × 4 fuentes × 4 especies
├── S3748/         # Fuentes 37–48 × 12 especies
├── CALPUFF/       # Ejecutable del modelo de dispersión (calpuff.x)
└── CALPOST/       # Ejecutable de postprocesamiento (calpost.exe)
```

Cada subdirectorio de simulación contiene:
- `calpuff.inp` — configuración del modelo de dispersión
- `calpost.inp` — configuración del postprocesador
- Enlace simbólico a `FCST/CALMET.DAT` — datos meteorológicos compartidos

---

## Metodología

### 1. Factor de Dilución
Cada subdirectorio `S01xx`–`S37xx` simula empresas individuales con una emisión unitaria de **1 Mg/año por especie**, lo que permite calcular el **factor de dilución** específico por empresa. Este factor es luego escalado con las emisiones reales de cada planta para obtener concentraciones ambientales representativas.

### 2. Estimación de Riesgo (fuera de línea, en Excel)
Con las concentraciones obtenidas y los parámetros toxicológicos (IUR y concentración de referencia), se calculan:

| Archivo de salida       | Contenido                              |
|-------------------------|----------------------------------------|
| `riesgos.csv`           | Riesgo cancerígeno por industria       |
| `riesgosC.csv`          | Riesgo cancerígeno por contaminante    |
| `ncancerI.csv`          | Riesgo no cancerígeno por industria    |
| `ncancerC.csv`          | Riesgo no cancerígeno por sustancia    |

---

## Flujo de Ejecución

```
[Ambiente Intel OneAPI]
        ↓
[calpuff.x] → dispersión atmosférica
        ↓
[calpost.exe] → postprocesamiento de concentraciones
        ↓
[procesa_conc.sh] → concentraciones_combinadas.csv
        ↓
[Excel] → riesgos.csv / riesgosC.csv / ncancerI.csv / ncancerC.csv
        ↓
[Mapas.ipynb] → visualización cartográfica de riesgos
```

### Comandos por directorio de simulación

```bash
# 1. Cargar compilador Intel
source /opt/intel/oneapi/setvars.sh intel64

# 2. Entrar al directorio de simulación
cd S0148

# 3. Ejecutar modelo de dispersión
../CALPUFF/calpuff.x CALPUFF.INP

# 4. Ejecutar postprocesador
../CALPOST/calpost.exe calpost.inp

# 5. Procesar salidas
bash ../FCST/procesa_conc.sh
```

---

## Dependencias y Herramientas

| Herramienta | Función |
|---|---|
| **CALPUFF** | Modelo de dispersión atmosférica Lagrangiano |
| **CALPOST** | Postprocesador de concentraciones de CALPUFF |
| **CALMET.DAT** | Campos meteorológicos 3D para todo 2023 |
| **Intel OneAPI** | Compilador Fortran para los ejecutables |
| **Excel** | Cálculo de factores de riesgo toxicológico |
| **Mapas.ipynb** | Notebook de visualización geoespacial (Python) |
