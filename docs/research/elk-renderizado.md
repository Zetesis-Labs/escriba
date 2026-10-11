# ELK Layered para renderizar grafos en Escriba

Investigación de fuentes primarias sobre reducir solapamientos de texto y rutas que atraviesan nodos. El alcance conserva el Canvas de macOS, la WebView de Tauri y los datos locales; esta nota no añade dependencias ni modifica el código.

## Hallazgos

- **ELK calcula layout, no dibuja.** `elkjs` es la adaptación JavaScript del Eclipse Layout Kernel y devuelve posiciones para que el cliente las represente. ELK Layered separa el trabajo en ruptura de ciclos, asignación de capas, minimización de cruces, colocación de nodos y trazado de aristas. El render Canvas debe consumir las coordenadas y los puntos de quiebre devueltos; recalcular el trazo desde los extremos anularía el beneficio. [elkjs README](https://github.com/kieler/elkjs), [fases de Layered](https://eclipse.dev/elk/blog/posts/2025/25-08-21-layered.html).

- **Etiquetas y dimensiones son parte del modelo de layout.** Las etiquetas son rectángulos con `x/y/width/height`, y ELK Layered las contempla durante la asignación de capas. Enviar el texto y su ancho/alto medidos con la misma fuente y tamaño que usará Canvas permite que ELK reserve espacio. Dibujar después una etiqueta sin dimensiones correctas puede volver a producir solapamientos. La posición `CENTER` es la predeterminada; `HEAD` y `TAIL` son alternativas. Para muchas etiquetas, ajustar `elk.spacing.edgeLabel`, `elk.layered.spacing.edgeNodeBetweenLayers` y `elk.layered.spacing.edgeNode`. [estructura del grafo](https://eclipse.dev/elk/documentation/tooldevelopers/graphdatastructure.html), [ubicación de edge labels](https://eclipse.dev/elk/reference/options/org-eclipse-elk-edgeLabels-placement.html), [espacio edge-node por capa](https://eclipse.dev/elk/reference/options/org-eclipse-elk-layered-spacing-edgeNodeBetweenLayers.html).

- **Rutas ortogonales y puertos explícitos están soportados.** Layered admite trazado `ORTHOGONAL`; en ese modo respeta restricciones de puertos. Los puertos son puntos de conexión rectangulares pertenecientes a nodos. Configurar `elk.portConstraints` (`FIXED_SIDE`, `FIXED_ORDER`, etc.) y `elk.port.side` por puerto hace predecibles los lados de entrada/salida. [ELK Layered: capacidades](https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html), [restricciones de puertos](https://eclipse.dev/elk/reference/options/org-eclipse-elk-portConstraints.html), [estructura de puertos y secciones de arista](https://eclipse.dev/elk/documentation/tooldevelopers/graphdatastructure.html).

- **Cruces y colisiones: mitigación, no promesa absoluta.** La minimización de cruces usa heurísticas (por defecto `LAYER_SWEEP`) que buscan menos cruces; ELK no garantiza un dibujo sin ningún cruce para cualquier grafo. El espaciado reservado depende del tamaño real de nodos/etiquetas y de las opciones de separación. La documentación de Layered describe el enrutado y la minimización, pero no ofrece una garantía universal de ausencia de todo cruce o intersección en grafos arbitrarios. Conviene detectar y revisar visualmente casos límite en un conjunto sintético representativo. [minimización de cruces y heurísticas](https://eclipse.dev/elk/blog/posts/2025/25-08-21-layered.html), [opciones Layered](https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html).

- **Self-loops y aristas paralelas son capacidades declaradas.** ELK Layered lista ambos como soportados. Puede configurarse `elk.layered.edgeRouting.selfLoopDistribution` / `selfLoopOrdering`; la opción `elk.insideSelfLoops.activate` por defecto es `false`. Cada arista del modelo debería conservar un ID y su propia etiqueta para no colapsar relaciones paralelas antes de pasarlas a ELK. [capacidades y opciones de Layered](https://eclipse.dev/elk/reference/algorithms/org-eclipse-elk-layered.html), [modelo de arista](https://eclipse.dev/elk/documentation/tooldevelopers/graphdatastructure.html).

## Configuración de partida

Para un grafo dirigido y plano, con flujo izquierda a derecha:

```ts
const graph = {
  id: 'root',
  layoutOptions: {
    'elk.algorithm': 'layered',
    'elk.direction': 'RIGHT',
    'elk.edgeRouting': 'ORTHOGONAL',
    'elk.layered.spacing.nodeNodeBetweenLayers': '48',
    'elk.layered.spacing.edgeNodeBetweenLayers': '24',
    'elk.spacing.edgeNode': '16',
    'elk.spacing.edgeLabel': '8',
  },
  children: [/* nodos con width/height y ports */],
  edges: [/* id estable, sources/targets, labels con width/height */],
}
```

Los valores de separación son una propuesta para experimentar, no valores recomendados por ELK. Medir etiquetas antes del layout. Para los puertos, declarar identificadores y lados solo si la semántica del grafo lo requiere; dejar que Layered los asigne libremente puede ser más legible para grafos de conocimiento. ELK JSON soporta aristas dirigidas y secciones con extremos y bend points, además de etiquetas en los elementos. [elkjs: opciones y formato de entrada/salida](https://github.com/kieler/elkjs#layout-options), [opciones oficiales](https://eclipse.dev/elk/reference/options.html).

## Web Worker en Vite/Tauri

`elkjs` admite `workerUrl` para ejecutar el layout fuera del hilo de interfaz, evitando congelar el render. Vite empaqueta workers como chunks y permite importar una URL de asset con `?url`; hay que comprobar en build que el worker de `elkjs` queda incluido en los recursos locales de la app y que la URL resuelta llega a `workerUrl`. También existe la vía Vite `new Worker(new URL(..., import.meta.url))`, aunque su detección exige esa forma literal. En una app Tauri empaquetada, la prueba debe ejecutarse sin red externa. [elkjs README: Workers y API](https://github.com/kieler/elkjs#usage), [Vite: Web Workers y assets](https://vite.dev/guide/features.html#web-workers).

## Límites prácticos para Escriba

ELK es adecuado como motor geométrico para un grafo explícito de nodos y relaciones dirigidas; no reemplaza el Canvas, los gestos, la selección ni el encuadre. La capa Canvas debe dibujar las secciones devueltas (incluidos los bend points) y posicionar labels según `x/y` calculados. Los nodos y etiquetas necesitan tamaños medidos; etiquetas largas aumentan el lienzo. Antes de integrarlo, comparar con datos sintéticos que incluyan ciclos, self-loops, varias relaciones entre los mismos extremos, nombres largos y nodos de alto grado. Ninguna nota, audio ni dato real debe salir del almacenamiento local para ejecutar el layout.
