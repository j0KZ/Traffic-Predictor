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

Versión segura, sin publicar comparaciones entre proveedores hasta tener el
permiso del punto 1.

> Llevo un mes midiendo tiempos de viaje en 25 corredores urbanos, de Santiago
> a Yakarta, cada 30 minutos.
>
> Un hallazgo que no esperaba: el error de las APIs de ruteo no es parejo. En
> un mismo corredor puede ser de 2% a las 3 de la mañana y de 20% a las 8. Y
> el sesgo es local: lo aprendido en una ciudad no sirve en la de al lado.
>
> Para una operación que promete ventanas horarias, esto significa que el
> margen que usas de noche no te sirve en la punta de la mañana, y que copiar
> el margen de otra ciudad es una apuesta.
>
> Lo medible: con una o dos mediciones reales por corredor y franja, el error
> baja a menos de la mitad.
>
> Si repartes con ventana horaria y quieres saber cuánto se equivoca tu
> proveedor en TUS rutas, escríbeme. Mido dos semanas sin costo.

Ritmo: una publicación al mes, con un dato duro. No más.

---

## 3. Acercamiento directo

Para jefes de operaciones, distribución o flota. Corto, sin adjuntos.

> Asunto: cuánto se equivoca tu ETA en la punta de la mañana
>
> Hola [nombre],
>
> Mido precisión de tiempos de viaje en corredores urbanos. En las 25 rutas que
> sigo, el error del proveedor cambia fuerte según la hora: donde de madrugada
> acierta al 2%, en la punta se va al 20%.
>
> Si [empresa] promete ventanas de entrega, ese error se paga en reprogramaciones.
>
> Te ofrezco medir tu corredor principal dos semanas, sin costo ni compromiso.
> Te entrego el desglose por franja horaria y cuántas entregas al mes explica ese
> error. Si te sirve, conversamos; si no, te quedas con el dato.
>
> ¿Cuál es la ruta que más te duele?
>
> [firma]

La última pregunta es la importante: obliga a responder algo concreto.

---

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
