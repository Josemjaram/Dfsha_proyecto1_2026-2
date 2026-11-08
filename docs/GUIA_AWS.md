# Guía de despliegue de DFSha en AWS Academy (Learner Lab)

Objetivo: dejar corriendo **3 controladores (Raft) + 4 nodos de datos + 1 cliente**, demostrar las fallas que pide el PDF y recolectar la evidencia (capturas, logs, CSV) para el informe y el video.

> Todo lo que está aquí se probó en un clúster local (14/14 pruebas). **Lo que no se pudo probar fuera de AWS**: Docker (construcción de la imagen y reinicio automático con `docker kill`), el límite real de instancias de su Learner Lab y los tiempos de red reales. Anótenlo como "verificado en AWS" en el informe solo cuando lo ejecuten allí.

Convención de IPs de esta guía (cámbienlas por las suyas, **siempre privadas**):

| Rol | Nombre | IP privada |
|---|---|---|
| Controlador | c1, c2, c3 | 10.0.1.11, 10.0.1.12, 10.0.1.13 |
| Nodo de datos | n1, n2, n3, n4 | 10.0.1.21 … 10.0.1.24 |
| Cliente | cli | 10.0.1.30 |

Si el Learner Lab no deja crear 8 instancias, ver el apartado "Plan B si hay pocas instancias" al final.

---

## Camino rápido: despliegue automático con `deploy/desplegar.sh`

Si ya crearon las 8 VMs (paso 1) y el security group, este script hace los pasos 2 a 6 por SSH desde su computador (Linux, macOS, WSL o Git Bash; necesita `python3`, `openssl`, `ssh` y `scp`):

```bash
pip install -r requirements.txt                    # para generar los certificados
cp deploy/hosts.example.txt deploy/hosts.txt       # edite: nombre  ip_privada  ip_publica
export SSH_KEY=~/llave-aws.pem                     # la .pem de AWS Academy
export SSH_USER=ec2-user                           # ubuntu si las VMs son Ubuntu
DRY_RUN=1 bash deploy/desplegar.sh                 # opcional: muestra lo que haría, sin tocar las VMs
bash deploy/desplegar.sh
```

Genera los secretos (`deploy/secrets.generated.env`), la CA y un certificado por nodo, instala Docker, copia el código, construye la imagen, arranca los 3 controladores y luego los nodos de datos, prepara el cliente y termina con una prueba de punta a punta (sube 32 MiB, los baja y compara el hash). Se puede repetir sin problema. Las VMs se siguen creando a mano en la consola de AWS.

Qué se verificó y qué no: la generación de secretos, certificados y `cluster.json`, y el orden de los pasos, se probaron en modo simulación (`DRY_RUN=1`). **La parte por SSH contra VMs reales no se pudo probar fuera de AWS**: si algo falla, el script dice en qué VM y deja el registro en `deploy/logs/<nombre>.log`; los pasos manuales de abajo siguen siendo válidos.

Después del script, sigan en la sección 7 (guion de evidencia) y la 8 (mediciones).

---

## 0. Antes de empezar (en su computador)

1. Tener el repositorio (o el zip) con el código. No necesitan haberlo subido a GitHub para empezar (ver la respuesta sobre GitHub en la conversación), pero **jamás** deben subir `certs/`, `env` ni llaves (`.gitignore` ya los excluye).
2. Python 3.10+ con `pip install -r requirements.txt` (para generar certificados).
3. Un par de llaves SSH (`.pem` de AWS Academy) para entrar a las VMs.

## 1. Red y máquinas

1. **VPC**: usen la VPC por defecto o creen una; una subred es suficiente. Es importante que todas las VMs estén en la misma VPC.
2. **Security group `dfsha-sg`** (uno solo para todas las VMs):
   - Entrada TCP 22 desde su IP (para SSH).
   - Entrada TCP 8001, 4321 y 9001 **solo desde el propio security group** (origen = `dfsha-sg`). 4321 es Raft entre controladores, 8001 es la API de controladores y 9001 la de nodos de datos.
   - Nada más abierto. En particular, no abran 8001/9001 a `0.0.0.0/0`.
3. **Instancias**: 8 × `t3.small` o `t3.medium` (Amazon Linux 2023 o Ubuntu 22.04), disco de 20–30 GB. Nómbrenlas `dfsha-c1`… `dfsha-cli`. Para que las IPs coincidan con la tabla, fijen la IP privada al crear cada instancia (Configuración de red → IP privada principal).
4. Las **IP privadas se conservan** al detener/iniciar el lab; las públicas cambian. Usen solo las privadas en `cluster.json` y en los certificados.

## 2. Certificados (en su computador, no en las VMs)

```bash
python scripts/gen_certs.py certs \
  --node c1=10.0.1.11 --node c2=10.0.1.12 --node c3=10.0.1.13 \
  --node n1=10.0.1.21 --node n2=10.0.1.22 --node n3=10.0.1.23 --node n4=10.0.1.24
```

Resultado: `certs/ca.pem`, `certs/ca.key` y `certs/<nodo>/server.pem|server.key`.

- A cada VM le copian **solo** `ca.pem` y la carpeta de **su** nodo. A la VM cliente solo `ca.pem`.
- `ca.key` (la llave que firma todo) **no sale de su computador** y no va al repositorio.

## 3. Secretos y configuración

1. Generen los secretos **una sola vez** en su computador y guárdenlos en un lugar privado (gestor de contraseñas):

   ```bash
   echo "DFSHA_CLUSTER_KEY=$(openssl rand -hex 32)"
   echo "DFSHA_ADMIN_KEY=$(openssl rand -hex 32)"
   echo "DFSHA_NODE_KEY_n1=$(openssl rand -hex 32)"   # una por nodo de datos (pueden ser distintas)
   ```

2. Archivo `/opt/dfsha/env` en cada VM (permisos 600). No hace falta escribir `export`: los scripts de despliegue ya lo hacen por ustedes.
   - Controladores (c1–c3):
     ```
     DFSHA_CLUSTER_KEY=<el mismo en TODAS las VMs>
     DFSHA_ADMIN_KEY=<el mismo en los 3 controladores>
     ```
   - Nodos de datos (n1–n4):
     ```
     DFSHA_CLUSTER_KEY=<el mismo en TODAS las VMs>
     DFSHA_NODE_KEY=<la de ese nodo>
     ```
   Sin estos valores el proceso **se niega a arrancar** (es intencional; `DFSHA_DEV=1` es solo para desarrollo local, no lo usen en AWS).
3. `/opt/dfsha/cluster.json`: partan de `deploy/cluster.example.json`, ajusten las IPs y déjenlo igual en las 7 VMs (c1–c3, n1–n4). No cambien `retention` (360) a un valor menor que `read_ttl` (300).

## 4. Preparar cada VM (las 7 de servidor)

Por SSH, en cada una (ajusten la instalación de Docker a su sistema: `dnf` en Amazon Linux, `apt` en Ubuntu):

```bash
sudo dnf install -y docker git        # Ubuntu: sudo apt-get install -y docker.io git
sudo systemctl enable --now docker    # arranca Docker solo tras un reinicio de la VM
sudo usermod -aG docker $USER         # cierren sesión y vuelvan a entrar
sudo mkdir -p /opt/dfsha/certs /var/lib/dfsha-state /var/lib/dfsha-data
sudo chown -R $USER /opt/dfsha
```

Copien (con `scp`): el código del proyecto a `~/dfsha`, `cluster.json`, `ca.pem`, la carpeta del nodo y el archivo `env`:

```bash
scp -i llave.pem -r dfsha-proyecto/ ec2-user@<IP_PUBLICA>:~/dfsha
scp -i llave.pem certs/ca.pem certs/c1/server.pem certs/c1/server.key ec2-user@<IP_PUBLICA>:/opt/dfsha/certs/
scp -i llave.pem cluster.json env-c1 ec2-user@<IP_PUBLICA>:/opt/dfsha/   # luego: mv env-c1 env; chmod 600 env
```

Construyan la imagen: `cd ~/dfsha && docker build -t dfsha .` (una vez por VM).

## 5. Arrancar el clúster

Primero los 3 controladores (uno por VM), luego los nodos de datos:

```bash
# en la VM c1 (y análogo en c2 y c3 con su id e IP)
cd ~/dfsha && ./deploy/run_controller.sh c1 10.0.1.11

# en la VM n1 (y análogo en n2, n3, n4)
cd ~/dfsha && ./deploy/run_datanode.sh n1 10.0.1.21
```

Los contenedores quedan con `--restart unless-stopped`: Docker los vuelve a levantar si el proceso muere o si la VM se reinicia. Revisen:

```bash
docker ps
docker logs --tail 30 dfsha-c1      # busquen "líder" / "listo" y que no haya errores de TLS
```

Esperen ~10 s a que Raft elija líder y los nodos de datos envíen su primer heartbeat.

## 6. Cliente

En la VM `cli` (instalen Python y dependencias, copien el código y `ca.pem`):

```bash
sudo dnf install -y python3-pip && cd ~/dfsha && pip3 install -r requirements.txt
export DFSHA_CONTROLLERS=https://10.0.1.11:8001,https://10.0.1.12:8001,https://10.0.1.13:8001
export DFSHA_CA=/opt/dfsha/certs/ca.pem
./dfsha-cli register --user ana --password clave12345   # solo la primera vez
./dfsha-cli login --user ana --password clave12345
./dfsha-cli mkdir /pruebas
head -c 64M /dev/urandom > /tmp/grande.bin
./dfsha-cli put /tmp/grande.bin /pruebas/grande.bin
./dfsha-cli get /pruebas/grande.bin /tmp/grande.copia
sha256sum /tmp/grande.bin /tmp/grande.copia      # deben ser idénticos
./dfsha-cli ls /pruebas
```

(`./dfsha-cli --help` lista todos los subcomandos.)

Verificación del clúster: `./dfsha-cli cluster --admin-key <DFSHA_ADMIN_KEY>` debe mostrar 3 controladores y ≥4 nodos vivos. Hagan una captura.

## 7. Qué demostrar y cómo (guion para la evidencia)

Para cada ítem: **comando → qué debe pasar → qué capturar**. Dejen una terminal con `docker logs -f` del líder visible.

| # | Prueba | Comando | Resultado esperado | Evidencia |
|---|---|---|---|---|
| 1 | Carga y recuperación | `put` y `get` de 64 MiB, `sha256sum` | hashes idénticos | captura de ambos hashes |
| 2 | Replicación | `./dfsha-cli stat /pruebas/grande.bin` y `cluster --admin-key ...` | bloques repartidos en ≥2 nodos (3 al terminar la réplica asíncrona); verifíquenlo mirando los directorios de datos de los nodos | captura del manifiesto |
| 3 | Caída de un nodo | en n1: `docker stop dfsha-n1`; seguir leyendo/escribiendo | lecturas y escrituras siguen; tras ~20 s el nodo se marca caído y se repara la réplica faltante | log del líder + `get` correcto durante la caída. Reiniciar con `docker start dfsha-n1` |
| 4 | Reinicio automático | en n2: `docker kill dfsha-n2`; esperar 10 s; `docker ps` | Docker lo levanta solo (`--restart unless-stopped`) y el nodo vuelve al clúster | captura de `docker ps` antes/después |
| 5 | Réplica desconectada | en n3: `docker pause dfsha-n3`, escribir un archivo, `docker unpause dfsha-n3` | la escritura confirma con 2 acuses; n3 se pone al día por blockreport/reparación | log |
| 6 | Failover de controlador | `docker kill` del contenedor del líder (el log dice cuál) | nuevo líder en ~3–5 s; los metadatos se conservan; el cliente reintenta solo | tiempo medido + `ls` correcto |
| 7 | Pérdida de mayoría | detener 2 de 3 controladores | las escrituras/lecturas de metadatos responden `503 UNAVAILABLE` (sistema CP, no inventa datos) | captura del error; luego recuperar con `docker start` y comprobar que vuelve |
| 8 | Concurrencia | dos clientes escriben el mismo archivo | el segundo recibe `423 LOCKED`; lectores ven un snapshot consistente | salida de ambos |
| 9 | Modificar 1 byte | `./dfsha-cli write /pruebas/grande.bin --offset 1000 --data "X"` | solo se reenvía el bloque afectado; versión anterior intacta | log: 1 bloque nuevo |
| 10 | Seguridad | `curl` sin token a un nodo; `openssl s_client -connect 10.0.1.21:9001 -tls1_3`; buscar texto plano en el disco de un nodo (`grep -r` en `/var/lib/dfsha-data`) | 401/403; TLS 1.3; cero coincidencias de texto plano | capturas |
| 11 | Agregar un nodo | seguir "Agregar un nodo de datos" del README | el nodo aparece solo y recibe bloques nuevos | `cluster` antes/después |

Importante para el profesor (autoría y coherencia): cada captura debe corresponder a algo que realmente hicieron; guarden fecha y hora (usen `date` en la terminal).

## 8. Mediciones de rendimiento (en la VM cliente)

```bash
python3 scripts/aws_bench.py --user ana --password clave12345 \
    --size-mib 64 --reps 5 --blocks 1,4,8 --clients 1,2,4 --out results/aws_perf.csv
```

- Mide put/get (mediana y p95) para bloque de 1/4/8 MiB con 1 cliente y para 1/2/4 clientes simultáneos con bloque de 8 MiB, verifica el SHA-256 de cada archivo recuperado y también la latencia de metadatos (`stat`).
- Es exactamente el patrón de `t_rendimiento` pero contra el clúster real. Con ≥5 repeticiones (lo que pide el PDF).
- Pongan en el informe el tipo de instancia, región y que las cifras son de AWS (las de `results/` son de localhost y no son representativas).

## 9. Recoger evidencia y apagar

- Copien a su computador: `results/aws_perf.csv`, `docker logs dfsha-<id> > log-<id>.txt` de cada VM, y las capturas.
- **Antes de apagar el lab**: no borren los volúmenes si quieren repetir una prueba (los datos están en `/var/lib/dfsha-*`). Al detener/iniciar el Learner Lab los contenedores vuelven solos por Docker (si `docker` está habilitado en `systemctl`) y las IP privadas se conservan.
- El Learner Lab tiene presupuesto: apaguen las VMs cuando no las usen.

## 10. Problemas frecuentes

| Síntoma | Causa probable | Qué hacer |
|---|---|---|
| El contenedor sale al instante | falta un secreto en `env` o el archivo no es legible | `docker logs dfsha-<id>`; revisar `/opt/dfsha/env` |
| `certificate verify failed` | `DFSHA_CA` no apunta a `ca.pem`, o el certificado del nodo no tiene su IP | regenerar ese nodo con `gen_certs.py --node` con la IP correcta |
| Controladores no eligen líder | el 4321 está bloqueado en el security group, o IPs distintas en `cluster.json` | revisar el SG (origen = el propio SG) y que `cluster.json` sea idéntico |
| Nodos no aparecen | `--advertise` con IP equivocada o 9001 bloqueado | revisar el comando de `run_datanode.sh` y el SG |
| `UNAVAILABLE` permanente | menos de 2 controladores vivos | levantar controladores con `docker start` |
| `docker kill` no reinicia el contenedor | contenedor creado sin `--restart` | recrear con el script de despliegue |

## Plan B si hay pocas instancias

Si el laboratorio solo permite, por ejemplo, 5 instancias: pongan **un controlador y un nodo de datos en la misma VM** (puertos distintos: 8001/4321 y 9001, ya no chocan) hasta tener 3 VMs con controlador y 4 nodos de datos repartidos. Anótenlo en el informe como limitación del laboratorio. No pongan dos controladores en la misma VM: perderían la tolerancia a fallos (una sola VM caída quitaría la mayoría).
