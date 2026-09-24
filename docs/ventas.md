# Textos listos para enviar

Todo lo de acá se copia y se pega. Nada se manda automático.

---

## 1. Permiso a los proveedores (mandar primero)

Sin esta respuesta no se publica ninguna comparación entre proveedores.
Mapbox prohíbe almacenar sus resultados; TomTom prohíbe cachearlos más allá
de sus cabeceras. Pedir permiso cuesta un correo.

### Para TomTom — `developer.support@tomtom.com`

> Asunto: Permiso para publicar un estudio independiente de precisión de ETA
>
> Estimados,
>
> Opero un sistema que mide tiempos de viaje en 25 corredores urbanos de todo
> el mundo, cada 30 minutos, usando su Routing API junto a otra fuente, y los
> contrasta con tiempos de viaje reales.
>
> Quiero publicar un informe periódico con estadísticas agregadas: error medio
> por ciudad y franja horaria, sin exponer respuestas individuales de la API ni
> permitir su reconstrucción. Entiendo que sus términos limitan el
> almacenamiento de resultados, por lo que les consulto antes de publicar nada.
>
> ¿Bajo qué condiciones podría publicar agregados derivados de su API,
> identificando a TomTom como fuente? Si prefieren revisar la metodología antes,
> se las envío completa.
>
> Quedo atento,

### Para Mapbox — `support@mapbox.com`

Mismo texto, cambiando el nombre. Mapbox es el más restrictivo: sus términos
prohíben exportar, descargar, cachear o almacenar resultados del servicio.
Si la respuesta es no, se publica el índice sin identificar proveedores, o se
publica solo sobre datos propios y del cliente.

---

## 2. Publicación en LinkedIn

Abre con la frase que todos reconocen, explica qué es un margen antes de usar la
cifra, y recién ahí los datos. Sin la entrada, el lector ve números sueltos y
sigue bajando.

> "Tu pedido llega entre 3 y 4 de la tarde."
>
> Detrás de esa frase hay un ETA: la estimación de tiempo de viaje que entrega un
> proveedor de ruteo, el mismo tipo de número que te muestra Google Maps. Si se
> equivoca, la ventana se cae, alguien reprograma un camión y el cliente reclama.
>
> Me quedé con la duda de cuánto se equivoca de verdad. No contra otra app —eso
> es comparar dos predicciones entre sí— sino contra el reloj.
>
> Chicago publica cada viaje de taxi: hora de salida y duración exacta,
> anonimizados. Tomé 466 viajes de más de 25 minutos y le pregunté a dos de las
> fuentes de ruteo más usadas del mercado qué habrían predicho para ese mismo
> instante. 591 comparaciones.
>
> Error medio: 14,2%. En un viaje de 40 minutos son casi 6 minutos de diferencia,
> y es bastante más de lo que uno supondría de una tecnología que ya damos por
> resuelta.
>
> Pero el dato que me hizo cambiar el producto es otro.
>
> Hablemos de margen. Es por cuánto multiplicas el ETA antes de prometerlo: si el
> sistema dice 30 minutos y tú prometes 39, tu margen es ×1,30. Toda operación
> usa uno, y casi siempre es el mismo para todas sus rutas.
>
> Medí cuánto margen necesita cada corredor para cumplirle al 90% de los
> clientes. Los doce corredores salen del mismo punto —el aeropuerto— hacia
> distintos destinos de la misma ciudad, en el mismo mes. El resultado va de
> ×1,04 a ×1,41.
>
> Cambia solo el destino, y el margen se triplica.
>
> Un margen plano, entonces, falla en los corredores difíciles y regala capacidad
> en los fáciles. Al mismo tiempo. Y no hay manera de saber cuál es cuál sin
> medirlo.
>
> También publico lo que no funcionó: calcular un factor de corrección por
> corredor y aplicarlo al ETA no baja el error medio. La dispersión dentro de un
> corredor es mayor que el sesgo, y un factor corrige sesgo, no varianza.
> Recentra la predicción, no la aprieta. Si alguien te ofrece bajar tu error a la
> mitad con un multiplicador, no lo midió contra viajes reales.
>
> Lo que sí se puede saber es cuál es la ventana correcta para cada corredor y
> cada hora. Eso se mide.
>
> Método, datos y límites, incluidos los del propio estudio: etacheck.cl/estudio
>
> Si reparten con ventana horaria y quieren saber el margen de sus rutas, mido un
> corredor dos semanas sin costo. Respóndeme con una comuna.

Ritmo: una publicación al mes, con un dato duro. No más.

## 3. Acercamiento directo

Para jefes de operaciones, distribución o flota. Corto, sin adjuntos. Abre con
el dato, cierra con una pregunta que se contesta en una palabra.

> Asunto: el margen que tu ETA necesita no es el que estás usando
>
> Hola [nombre],
>
> Medí 466 viajes reales contra lo que predecían dos de las fuentes de ruteo más
> usadas. El margen que cada corredor necesita para cumplirle al 90% va de ×1,04
> a ×1,41, con el mismo origen y en la misma ciudad.
>
> O sea que el margen plano que usa tu operación falla en los corredores
> difíciles y regala capacidad en los fáciles, y no hay forma de saber cuál es
> cuál sin medirlo. El estudio completo, con lo que no funcionó, está en
> etacheck.cl/estudio
>
> Si [empresa] promete ventanas de entrega, mido un corredor dos semanas sin
> costo y te entrego la tabla de márgenes por franja horaria.
>
> ¿Cuál es la ruta que más se les cae?
>
> [firma]

## 4. Respuesta cuando pidan la medición

> Perfecto. Necesito tres cosas para partir:
>
> 1. Origen y destino del corredor (dirección o coordenadas).
> 2. Horario en que operan esa ruta.
> 3. Cuántos viajes hacen por día en ella.
>
> Con eso lo doy de alta hoy y en dos semanas te mando el informe.
>
> Si además me pueden compartir los tiempos reales de algunos viajes ya hechos
> (hora de salida y duración, un CSV basta), el informe pasa de describir el
> corredor a medir el error exacto de su proveedor. Es la diferencia entre una
> foto y una auditoría.

Ese último párrafo es el que consigue la verdad de terreno, que es lo que
convierte esto en producto.

---

## 5. Los dos primeros, ya escritos

### Shipit — borrador en Gmail, listo para revisar y enviar

Está en los borradores de `etacheck1@gmail.com`, dirigido a `contacto@shipit.cl`,
que es la dirección pública que publican en su página de contacto. Antes de
apretar enviar, revisar que el **De** diga `contacto@etacheck.cl` y no el Gmail.

### Envíame — no publican correo, solo formulario

En `enviame.io/contacto/` no hay ninguna dirección, ni en el pie de página.
El formulario pide: nombre, teléfono, correo, página web, empresa, país,
cuántos envíos hiciste el último mes, y cómo podemos ayudarte.

Está pensado para un comercio que quiere despachar, no para esto, así que en
"cuántos envíos" corresponde la opción más baja: no somos un cargador. Lo que
importa es el último campo:

> Mido precisión de tiempos de viaje en corredores urbanos: consulto el mismo
> trayecto cada 30 minutos y lo contrasto con el tiempo real. El error no es
> parejo: en un mismo corredor va de 4% de madrugada a más de 20% en la punta,
> y el sesgo es local, no se traslada entre ciudades.
>
> Para una plataforma multicourier eso significa que parte del incumplimiento
> no es del courier, es de la hora. Puedo medir dos semanas un corredor suyo
> sin costo y entregarles el error por franja horaria y el factor que lo
> corrige. El método está abierto en etacheck.cl/metodo.
>
> Busco conversar con quien vea precisión de entrega o datos de última milla.

Para Envíame la vía más directa es igual LinkedIn: Jefe o Gerente de Última
Milla, o el analista de datos de logística. El formulario cae en ventas.
