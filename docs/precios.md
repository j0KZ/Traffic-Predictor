# Costos, precios y cobranza

Cifras en pesos chilenos, a septiembre de 2026. Dólar a $950.

## 1. Lo que cuesta hoy operar

| Ítem | Costo |
|---|---|
| Dominio `etacheck.cl` | $10.000, ya pagado, se renueva una vez al año |
| Sitio en Cloudflare Workers | $0 |
| Correo: Cloudflare Routing + Gmail + Brevo | $0 |
| APIs de ruteo, dentro del tramo gratis | $0 |
| Servidor | $0, es el que ya tienes |
| **Salida de caja mensual** | **$0** |

No hay costo mensual. El dominio ya está pagado y el próximo desembolso es su
renovación, en un año. Repartirlo en doce cuotas es contabilidad, no una
cuenta que llegue: mientras nadie cobre nada, mantener esto andando cuesta
cero. No existe punto de equilibrio que alcanzar, el primer peso que entre es
margen.

## 2. Costo marginal por corredor

Un corredor medido cada 30 minutos son 48 consultas diarias a cada proveedor,
o 1.440 al mes por proveedor.

**Dentro del tramo gratis:** TomTom regala del orden de 2.500 consultas diarias
y Mapbox 100.000 mensuales. El que se agota primero es TomTom: 2.500 / 48 da
un techo de unos **52 corredores** a esa cadencia. Hoy corren 25, o sea queda
espacio para unos 27 corredores de clientes sin pagar un peso.

**Pasado el tramo gratis:** Mapbox cobra del orden de US$2 por mil consultas de
ruteo y TomTom US$0,50. Por corredor y mes:

    Mapbox   1.440 × US$2,00/1000  = US$2,88
    TomTom   1.440 × US$0,50/1000  = US$0,72
    Total                          ≈ US$3,60  ≈  $3.500

**$3.500 al mes por corredor** es el costo real y el peor caso. A cadencia de
una hora es la mitad. Cualquier precio sobre $50.000 por corredor deja más de
90% de margen bruto, y eso no va a cambiar con la escala.

El recurso escaso no es la plata, es la atención: dar de alta un corredor y
revisar su informe. `add-client-corridor.py` y `make-report.py` ya bajan eso a
cerca de una hora al mes por cliente. Y el piloto gratis no cuesta dinero,
cuesta cuota de TomTom: no tener más de tres pilotos abiertos a la vez.

## 3. Precios

La referencia no es el costo, que es ridículo, sino el daño que se evita. El
informe de ejemplo muestra $3.450.000 al mes en entregas que dejarían de llegar
tarde. Cobrar entre 10% y 15% de eso es defendible en cualquier reunión.

| Producto | Precio | Costo directo | Margen |
|---|---|---|---|
| Piloto: 1 corredor, 2 semanas | $0 | ~$1.800 | puerta de entrada |
| Auditoría: hasta 5 corredores, 4 semanas | $1.500.000 | ~$20.000 | 98% |
| Monitoreo: por corredor al mes | $90.000, mínimo 5 corredores | $3.500 | 96% |
| Monitoreo sobre 20 corredores | $60.000 cada uno | $3.500 | 94% |
| Factor por API, integrado a su TMS | $350.000/mes + $50.000 por corredor | $3.500 | 95% |
| Licencia a una plataforma multicourier | $8.000.000 a $15.000.000 al año | — | conversación aparte |

**El piloto no es gratis para ellos:** la condición es que entreguen tiempos
reales de viaje en CSV. Sin eso el informe describe el corredor, no audita a su
proveedor. Pedirlo filtra a los curiosos y consigue la verdad de terreno, que
es lo que hace crecer el producto.

**La auditoría es la puerta, la suscripción es el negocio.** Una auditoría es
un pago; el factor se desactualiza con las estaciones y las obras en la vía, y
eso es cierto, no un argumento de venta. Ahí vive la recurrencia.

## 4. Cómo se cobra

### Persona natural, que es por donde partir

Boleta de honorarios electrónica en sii.cl, gratis, se emite en dos minutos.

- **El cliente retiene 15,25%** y lo paga al SII a tu nombre (Ley 21.133; era
  14,5% en 2025 y llega a 17% en 2028). De una boleta de $1.000.000 recibes
  $847.500. Hay que cotizar pensando en bruto y no gastar el retenido: parte
  vuelve en la declaración de abril y parte se va en cotizaciones obligatorias.
- **Servicios profesionales de persona natural están exentos de IVA.** Contra
  una SpA que factura con 19%, eres 19% más barato para un cliente que no
  recupera IVA, y el papeleo es de un día.

### SpA, cuando corresponda

Constituir en Empresa en un Día, factura electrónica gratis en el portal MIPYME
del SII, **con IVA 19%** sobre el servicio y sin retención. Conviene cuando:
un cliente grande exige factura y orden de compra, quieres separar tu
patrimonio del negocio, entra un socio, o vas a licenciar el algoritmo. Antes
de eso es costo y contabilidad mensual sin beneficio.

### Medio de pago

**Transferencia bancaria, comisión cero.** Nada de Webpay (2,95% + IVA) ni
Mercado Pago (~3,5%) para cobros B2B: en una suscripción de $450.000 son
$13.000 regalados cada mes. Khipu o Flow solo si algún día quieres cobro
automático recurrente, y recién cuando haya varios clientes.

## 5. El cuello de botella real: el plazo, no el precio

Nadie va a discutir $450.000 al mes contra $3.450.000 de daño. Lo que duele es
cuándo llega la plata.

- **Las grandes** (CCU, Agrosuper, Coca-Cola Andina) pagan a 30 o 60 días desde
  la factura, y antes te hacen pasar por alta de proveedor: RUT, ficha, a veces
  seguros y certificados. Entre el sí y el primer pago pueden pasar dos o tres
  meses.
- **Las plataformas** (Shipit, Envíame) aprueban por correo y pagan en 15 a 30
  días. Por eso convienen primero: no por el ticket, por el flujo de caja.

Qué poner en las condiciones:

1. **Auditoría: 50% al empezar a medir, 50% contra entrega del informe.** Nunca
   medir cuatro semanas contra una promesa verbal.
2. **Monitoreo prepago**, mensual o trimestral. Trimestral con 10% de descuento
   te adelanta caja y baja la cobranza a cuatro veces al año.
3. **Orden de compra escrita antes de medir**, aunque sea un correo del jefe de
   operaciones. Es lo que después hace que finanzas pague.
4. La **Ley 21.131 obliga a pagar a 30 días** y permite cobrar interés y una
   comisión por mora. Citarla en las condiciones no es agresivo, es estándar.

## 6. Dónde se rompe esto

Honestidad sobre el modelo, que es lo que hay que vigilar:

- **El ciclo de venta**, no el costo, es el riesgo. Con costo fijo de $1.000 no
  te quiebras; te aburres esperando.
- **Un piloto que no convierte** cuesta cuota y atención. Tope de tres abiertos.
- **El cliente puede copiarlo.** El método está publicado a propósito: lo que
  no se copia es la serie histórica por corredor y la disciplina de medir cada
  30 minutos durante meses. Si un cliente grande decide hacerlo en casa, el
  negocio con él era la auditoría, no la suscripción. Conviene saberlo antes.
- **Los términos de los proveedores** limitan qué se publica, no qué se vende.
  Medir para un cliente y entregarle su informe está permitido; publicar
  comparaciones nombrando proveedores, no, hasta que respondan.

## 7. Qué nos protege y qué no

### Lo que no nos protege

- **El método.** Está publicado y un buen ingeniero lo replica en una semana.
  Publicarlo fue una decisión de confianza, no una ventaja.
- **La serie de 25 corredores.** Nuestro propio hallazgo la desarma: con dos
  mediciones el error ya baja a 5,8% y la tercera casi no aporta. Entonces la
  barrera de entrada para competir por *un cliente concreto* es de dos semanas
  de medición, no de meses. La serie histórica defiende el índice público y la
  credibilidad, no la cuenta de un cliente.
- **Las herramientas.** Cuatro scripts de Python. No son un activo.

### Lo que sí nos protege

1. **La neutralidad, que es estructural.** Un proveedor de ruteo no puede
   auditarse a sí mismo, y quien vende ETA predictivo (NextBillion, Locus) no
   puede vender "cuánto se equivoca tu ETA" sin cortarse las piernas. Los que
   tienen más datos y más plata están excluidos por conflicto de interés, no
   por capacidad. Eso no se copia sin canibalizarse.
2. **Estar dentro del flujo.** Un informe se lee y se archiva. Un factor que
   entra por API al TMS y desde el cual se fijan las ventanas de promesa no se
   saca sin volver a calibrar las promesas. Por eso el producto de API importa
   más que el de informe, y conviene llegar ahí rápido.
3. **El corpus de viajes reales.** Es lo único que compone. Ningún proveedor
   tiene "qué pasó de verdad" con la flota de otro. Cada cliente que entrega su
   CSV agrega algo que no se compra en ninguna parte.
4. **Ser el número de referencia.** Transit App no defiende su benchmark con
   tecnología, lo defiende con que es el que todos citan. Eso se construye
   publicando seguido y equivocándose en público cuando corresponde.

### La amenaza real no es un imitador

Es el analista de datos del propio cliente. Puede hacer esto, y en una empresa
grande eventualmente lo va a hacer. Las tres razones por las que no lo hace hoy:
no es KPI de nadie, requiere una medición que corre para siempre y no un
proyecto de tres semanas, y quien podría construirlo está ocupado.

La defensa ahí es el precio, no la tecnología: $450.000 al mes contra un
analista que cuesta $2.500.000. Mientras contratarnos sea más barato que la
fracción del sueldo que tomaría el problema, construirlo en casa es irracional.
Si subimos el precio a donde duela, invitamos a que lo hagan ellos.

### La decisión pendiente

`metodo.html` promete que los viajes de un cliente no se usan para calibrar
rutas de otro. Esa promesa gana confianza y **bloquea el único activo que
compone**, el corpus. Recomiendo partirla en dos: mantener intacto que los
datos de un cliente nunca calibran a otro ni se exponen, y agregar una opción
de consentimiento para que entren, sin identificación, en las estadísticas
agregadas del índice. Se conserva lo que importa y el corpus crece.
