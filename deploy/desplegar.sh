#!/usr/bin/env bash
# Despliegue automático de DFSha en las VMs de AWS Academy, desde SU computador (Linux, macOS, WSL o Git Bash).
#
# Qué hace (todo por SSH, en este orden):
#   1. Genera los secretos (una vez), la CA y un certificado por nodo, y el cluster.json a partir de hosts.txt.
#   2. En cada VM de servidor: instala Docker, copia el código, los certificados, cluster.json y el env, y construye la imagen.
#   3. Arranca los 3 controladores y luego los nodos de datos con deploy/run_controller.sh y deploy/run_datanode.sh.
#   4. Prepara la VM cliente y hace una prueba de punta a punta (put, get, comparación de hash, estado del clúster).
#
# Uso:
#   cp deploy/hosts.example.txt deploy/hosts.txt      # y edite las IPs (nombre ip_privada ip_publica)
#   export SSH_KEY=~/llave-aws.pem                    # llave .pem de AWS Academy
#   export SSH_USER=ec2-user                          # ubuntu si las VMs son Ubuntu
#   bash deploy/desplegar.sh                          # DRY_RUN=1 bash deploy/desplegar.sh solo muestra lo que haría
#
# Se puede repetir sin problema: recrea los contenedores y conserva los secretos y certificados ya generados.
# ca.key y secrets.generated.env se quedan en su computador (el .gitignore los excluye): NO los suba a GitHub.
set -euo pipefail
cd "$(dirname "$0")/.."

HOSTS=${HOSTS:-deploy/hosts.txt}
SSH_KEY=${SSH_KEY:?Defina SSH_KEY con la ruta de su llave .pem}
SSH_USER=${SSH_USER:-ec2-user}
DRY_RUN=${DRY_RUN:-0}
SECRETS=deploy/secrets.generated.env
LOGS=deploy/logs
SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o ServerAliveInterval=15)

[[ -f "$HOSTS" ]] || { echo "Falta $HOSTS (copie deploy/hosts.example.txt y edítelo)"; exit 1; }
mkdir -p "$LOGS" certs

# ---------------------------------------------------------------- lectura de hosts
NAMES=(); PRIV=(); PUB=()
while read -r n priv pub _; do
  [[ -z "${n:-}" || "$n" == \#* ]] && continue
  NAMES+=("$n"); PRIV+=("$priv"); PUB+=("${pub:-$priv}")
done < "$HOSTS"
CTRL=(); DATA=(); CLI=""
for i in "${!NAMES[@]}"; do
  case "${NAMES[$i]}" in
    cli*) CLI="$i";;
    c*) CTRL+=("$i");;
    n*) DATA+=("$i");;
  esac
done
[[ ${#CTRL[@]} -eq 3 ]] || { echo "Se necesitan exactamente 3 controladores (c1 c2 c3); hay ${#CTRL[@]}"; exit 1; }
[[ ${#DATA[@]} -ge 4 ]] || { echo "Se necesitan al menos 4 nodos de datos (n1..n4); hay ${#DATA[@]}"; exit 1; }
echo "Controladores: ${#CTRL[@]}  Nodos de datos: ${#DATA[@]}  Cliente: ${CLI:+sí}"

say() { echo; echo "== $*"; }
ssh_run() { local ip=$1; shift; if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] ssh $SSH_USER@$ip: $*"; else ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "$@"; fi; }
ssh_put() { local ip=$1 dest=$2; if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] escribir $dest en $ip"; cat >/dev/null; else ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "umask 077; cat > $dest"; fi; }

# ---------------------------------------------------------------- 1. secretos, certificados, cluster.json
say "1. Secretos, certificados y cluster.json"
if [[ ! -f "$SECRETS" ]]; then
  ( umask 077
    echo "DFSHA_CLUSTER_KEY=$(openssl rand -hex 32)" >  "$SECRETS"
    echo "DFSHA_ADMIN_KEY=$(openssl rand -hex 32)"   >> "$SECRETS"
    for i in "${DATA[@]}"; do echo "NODE_KEY_${NAMES[$i]}=$(openssl rand -hex 32)" >> "$SECRETS"; done )
  echo "Secretos generados en $SECRETS (guárdelos en un lugar privado)"
fi
# un nodo nuevo agregado a hosts.txt recibe su propia llave sin tocar las demás
for i in "${DATA[@]}"; do grep -q "^NODE_KEY_${NAMES[$i]}=" "$SECRETS" || echo "NODE_KEY_${NAMES[$i]}=$(openssl rand -hex 32)" >> "$SECRETS"; done
get_secret() { grep "^$1=" "$SECRETS" | head -1 | cut -d= -f2-; }

NODEARGS=()
for i in "${!NAMES[@]}"; do
  [[ "${NAMES[$i]}" == cli* ]] && continue
  [[ -f "certs/${NAMES[$i]}/server.pem" ]] || NODEARGS+=(--node "${NAMES[$i]}=${PRIV[$i]}")
done
if [[ ${#NODEARGS[@]} -gt 0 ]]; then
  python3 scripts/gen_certs.py certs "${NODEARGS[@]}"   # reutiliza certs/ca.key si ya existe
else
  echo "Certificados ya generados: se reutilizan"
fi

python3 - "$HOSTS" > deploy/cluster.generated.json <<'EOF'
import json, sys
ctrl = []
for line in open(sys.argv[1]):
    p = line.split()
    if len(p) >= 2 and not line.lstrip().startswith("#") and p[0].startswith("c") and not p[0].startswith("cli"):
        ctrl.append({"id": p[0], "raft": f"{p[1]}:4321", "api": f"https://{p[1]}:8001"})
base = json.load(open("deploy/cluster.example.json"))
base["controllers"] = ctrl
print(json.dumps(base, indent=2))
EOF
echo "cluster.generated.json listo ($(python3 -c "import json;print(len(json.load(open('deploy/cluster.generated.json'))['controllers']))") controladores)"

# ---------------------------------------------------------------- 2. preparar cada VM de servidor
prepare() {   # $1 = índice en NAMES
  local i=$1 n=${NAMES[$1]} ip=${PUB[$1]}
  echo "[$n] instalando Docker y copiando archivos"
  ssh_run "$ip" 'command -v docker >/dev/null || { if command -v dnf >/dev/null; then sudo dnf install -y docker; else sudo apt-get update -y && sudo apt-get install -y docker.io; fi; }; sudo systemctl enable --now docker; sudo mkdir -p /opt/dfsha/certs /var/lib/dfsha-state /var/lib/dfsha-data; sudo chown -R "$USER" /opt/dfsha; mkdir -p ~/dfsha'
  if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] copiar código (tar) y certificados de $n a $ip"; else
    tar czf - --exclude=certs --exclude=__pycache__ --exclude=.git --exclude='deploy/logs' --exclude='*.generated.*' --exclude='deploy/hosts.txt' . \
      | ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "tar xzf - -C ~/dfsha"
    scp "${SSH_OPTS[@]}" -q certs/ca.pem "certs/$n/server.pem" "certs/$n/server.key" "$SSH_USER@$ip:/opt/dfsha/certs/"
    scp "${SSH_OPTS[@]}" -q deploy/cluster.generated.json "$SSH_USER@$ip:/opt/dfsha/cluster.json"
  fi
  if [[ "$n" == c* ]]; then
    printf 'DFSHA_CLUSTER_KEY=%s\nDFSHA_ADMIN_KEY=%s\n' "$(get_secret DFSHA_CLUSTER_KEY)" "$(get_secret DFSHA_ADMIN_KEY)" | ssh_put "$ip" /opt/dfsha/env
  else
    printf 'DFSHA_CLUSTER_KEY=%s\nDFSHA_NODE_KEY=%s\n' "$(get_secret DFSHA_CLUSTER_KEY)" "$(get_secret NODE_KEY_$n)" | ssh_put "$ip" /opt/dfsha/env
  fi
  ssh_run "$ip" 'chmod 600 /opt/dfsha/certs/server.key /opt/dfsha/env; cd ~/dfsha && sudo docker build -t dfsha . >/tmp/dfsha-build.log 2>&1 || { tail -20 /tmp/dfsha-build.log; exit 1; }'
  echo "[$n] imagen construida"
}
say "2. Preparando las VMs de servidor (en paralelo; registro en $LOGS/<nombre>.log)"
PIDS=(); ORDER=()
for i in "${CTRL[@]}" "${DATA[@]}"; do
  prepare "$i" > "$LOGS/${NAMES[$i]}.log" 2>&1 & PIDS+=($!); ORDER+=("${NAMES[$i]}")
done
FAIL=0
for k in "${!PIDS[@]}"; do
  if wait "${PIDS[$k]}"; then echo "  ${ORDER[$k]}: listo"; else echo "  ${ORDER[$k]}: FALLÓ (vea $LOGS/${ORDER[$k]}.log)"; FAIL=1; fi
done
[[ $FAIL == 0 ]] || { echo "Corrija lo anterior y vuelva a ejecutar el script."; exit 1; }

# ---------------------------------------------------------------- 3. arrancar
say "3. Arrancando controladores y nodos de datos"
for i in "${CTRL[@]}"; do
  ssh_run "${PUB[$i]}" "sudo docker rm -f dfsha-${NAMES[$i]} >/dev/null 2>&1 || true; cd ~/dfsha && sudo bash ./deploy/run_controller.sh ${NAMES[$i]} ${PRIV[$i]}"
done
sleep 5
for i in "${DATA[@]}"; do
  ssh_run "${PUB[$i]}" "sudo docker rm -f dfsha-${NAMES[$i]} >/dev/null 2>&1 || true; cd ~/dfsha && sudo bash ./deploy/run_datanode.sh ${NAMES[$i]} ${PRIV[$i]}"
done

# ---------------------------------------------------------------- 4. cliente y prueba de punta a punta
if [[ -n "$CLI" ]]; then
  say "4. Cliente y prueba de punta a punta (${NAMES[$CLI]})"
  ip=${PUB[$CLI]}
  ssh_run "$ip" 'mkdir -p ~/dfsha /opt/dfsha/certs 2>/dev/null || sudo mkdir -p /opt/dfsha/certs; sudo chown -R "$USER" /opt/dfsha; command -v pip3 >/dev/null || { if command -v dnf >/dev/null; then sudo dnf install -y python3-pip; else sudo apt-get update -y && sudo apt-get install -y python3-pip; fi; }'
  if [[ $DRY_RUN != 1 ]]; then
    tar czf - --exclude=certs --exclude=__pycache__ --exclude=.git --exclude='deploy/logs' --exclude='*.generated.*' --exclude='deploy/hosts.txt' . | ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "tar xzf - -C ~/dfsha"
    scp "${SSH_OPTS[@]}" -q certs/ca.pem "$SSH_USER@$ip:/opt/dfsha/certs/"
  fi
  URLS=""; for i in "${CTRL[@]}"; do URLS+="https://${PRIV[$i]}:8001,"; done; URLS=${URLS%,}
  printf 'export DFSHA_CONTROLLERS=%s\nexport DFSHA_CA=/opt/dfsha/certs/ca.pem\nexport DFSHA_ADMIN_KEY=%s\n' "$URLS" "$(get_secret DFSHA_ADMIN_KEY)" | ssh_put "$ip" '~/dfsha_cliente_env.sh'
  ssh_run "$ip" 'cd ~/dfsha && (pip3 install --user -q -r requirements.txt || pip3 install --user -q --break-system-packages -r requirements.txt)'
  if [[ $DRY_RUN == 1 ]]; then echo "[dry-run] prueba put/get/hash/cluster desde el cliente"; else
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" 'bash -s' <<'REMOTE'
set -e
source ~/dfsha_cliente_env.sh; cd ~/dfsha
echo "esperando a que el clúster elija líder y los nodos se registren..."
ok=0
for t in $(seq 1 24); do
  if out=$(bash ./dfsha-cli cluster 2>/dev/null) && echo "$out" | grep -q '"leader_api"'; then
    n=$(echo "$out" | grep -c '"state": "ALIVE"' || true); [ "${n:-0}" -ge 4 ] && { ok=1; break; }
  fi
  sleep 5
done
[ $ok = 1 ] || { echo "El clúster no quedó listo en 2 minutos. Revise: sudo docker logs dfsha-<id> en cada VM"; bash ./dfsha-cli cluster || true; exit 1; }
bash ./dfsha-cli register --user demo --password demo-clave-123 2>/dev/null || bash ./dfsha-cli login --user demo --password demo-clave-123
head -c 32M /dev/urandom > /tmp/prueba.bin
bash ./dfsha-cli put /tmp/prueba.bin /prueba.bin
bash ./dfsha-cli get /prueba.bin /tmp/prueba.out
A=$(sha256sum /tmp/prueba.bin | cut -d' ' -f1); B=$(sha256sum /tmp/prueba.out | cut -d' ' -f1)
echo "hash original: $A"; echo "hash recuperado: $B"
[ "$A" = "$B" ] && echo "PRUEBA DE PUNTA A PUNTA: OK" || { echo "PRUEBA DE PUNTA A PUNTA: FALLÓ"; exit 1; }
bash ./dfsha-cli cluster
REMOTE
  fi
fi

say "Listo"
echo "Siguiente paso: guion de evidencia en docs/GUIA_AWS.md (sección 7) y mediciones con scripts/aws_bench.py."
echo "Guarde $SECRETS y certs/ca.key fuera del repositorio."
