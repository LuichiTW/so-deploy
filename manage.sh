#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

BOLD=$(tput bold)
NORMAL=$(tput sgr0)
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)

# =====================================================
# Helpers
# =====================================================

log_info()  { echo -e "${BOLD}$1${NORMAL}"; }
log_ok()    { echo -e "${GREEN}✓${NORMAL} $1"; }
log_err()   { echo -e "${RED}✗${NORMAL} $1"; }
log_warn()  { echo -e "${YELLOW}!${NORMAL} $1"; }

ssh_cmd() {
    local ip="$1"; shift
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${ip}" "$@"
}

ensure_sshpass() {
    if ! command -v sshpass &>/dev/null; then
        log_warn "sshpass no encontrado. Instalando..."
        sudo apt-get update -qq && sudo apt-get install -y -qq sshpass
    fi
}

get_local_ip() {
    if command -v hostname &>/dev/null; then
        hostname -I | awk '{print $1}'
    elif command -v ip &>/dev/null; then
        ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1
    else
        echo ""
    fi
}

# =====================================================
# Profile lookup
# =====================================================

get_components() {
    local ip="$1"
    case "$ip" in
        "$VM1_IP") echo "kernel_memory io" ;;
        "$VM2_IP") echo "kernel_scheduler memory_stick" ;;
        "$VM3_IP") echo "cpu swap" ;;
        *) echo "" ;;
    esac
}

get_configs() {
    local ip="$1"
    case "$ip" in
        "$VM1_IP") echo "$VM1_CONFIGS" ;;
        "$VM2_IP") echo "$VM2_CONFIGS" ;;
        "$VM3_IP") echo "$VM3_CONFIGS" ;;
        *) echo "" ;;
    esac
}

get_remote_ips() {
    local local_ip
    local_ip=$(get_local_ip)
    for ip in "$VM1_IP" "$VM2_IP" "$VM3_IP"; do
        [[ "$ip" != "$local_ip" ]] && echo "$ip"
    done
}

is_local_ip() {
    [[ "$1" == "$(get_local_ip)" ]]
}

build_deploy_args() {
    local ip="$1"
    local components configs args=""
    components=$(get_components "$ip")
    configs=$(get_configs "$ip")

    for comp in $components; do
        args+=" -p=${comp}"
    done
    for cfg in $configs; do
        args+=" -c=${cfg}"
    done
    echo "$args"
}

# =====================================================
# Deploy
# =====================================================

deploy_local() {
    local ip local_ip args cmd
    local_ip=$(get_local_ip)
    ip="$local_ip"

    ensure_sshpass

    components=$(get_components "$ip")
    configs=$(get_configs "$ip")
    args=$(build_deploy_args "$ip")

    log_info "=== Deploy local (${ip}) ==="
    log_info "Componentes: ${components}"

    cd "${SCRIPT_DIR}"
    export GITHUB_TOKEN
    eval "./deploy.sh ${args} ${REPO_NAME}"

    log_ok "Deploy local completado"
}

deploy_remote() {
    local ip="$1"
    local args components

    ensure_sshpass

    components=$(get_components "$ip")
    args=$(build_deploy_args "$ip")

    log_info "=== Deploy remoto (${ip}) ==="
    log_info "Componentes: ${components}"

    ssh_cmd "$ip" "
        export GITHUB_TOKEN='${GITHUB_TOKEN}' &&
        rm -rf so-deploy &&
        git clone --depth=1 https://github.com/LuichiTW/so-deploy.git &&
        cd so-deploy &&
        chmod +x deploy.sh configure.sh manage.sh &&
        ./deploy.sh ${args} ${REPO_NAME}
    "

    log_ok "Deploy remoto completado: ${ip}"
}

deploy_all() {
    local ip local_ip
    local_ip=$(get_local_ip)

    deploy_local

    for ip in $(get_remote_ips); do
        deploy_remote "$ip"
    done

    log_info "=== Deploy completado en todas las VMs ==="
}

# =====================================================
# Config
# =====================================================

config_local() {
    local key="$1" value="$2"
    local repo_dir="${SCRIPT_DIR}/${REPO_NAME}"

    log_info "Configurando localmente: ${key}=${value}"

    cd "${repo_dir}"
    grep -Rl "^\s*${key}\s*=" . | grep -E '\.config|\.cfg' | xargs -r sed -i "s|^\(${key}\s*=\).*|\1${value}|"

    log_ok "Config local actualizada"
}

config_remote() {
    local ip="$1" key="$2" value="$3"
    local remote_dir="~/so-deploy/${REPO_NAME}"

    log_info "Configurando remoto (${ip}): ${key}=${value}"

    ssh_cmd "$ip" "
        cd ${remote_dir} &&
        grep -Rl '^\s*${key}\s*=' . | grep -E '\.config|\.cfg' | xargs -r sed -i 's|^\(${key}\s*=\).*|\1${value}|'
    "

    log_ok "Config remota actualizada: ${ip}"
}

config_all() {
    local key="$1" value="$2"
    local ip local_ip
    local_ip=$(get_local_ip)

    config_local "$key" "$value"

    for ip in $(get_remote_ips); do
        config_remote "$ip" "$key" "$value"
    done

    log_info "=== Config actualizada en todas las VMs ==="
}

# =====================================================
# Run
# =====================================================

run_binary() {
    local binary="$1"; shift
    local extra_args=("$@")
    local repo_dir="${SCRIPT_DIR}/${REPO_NAME}"
    local bin_dir="${repo_dir}/${binary}/bin"

    if [[ ! -f "${bin_dir}/${binary}" ]]; then
        log_err "Binario no encontrado: ${bin_dir}/${binary}"
        log_err "Ejecuta './manage.sh deploy' primero"
        return 1
    fi

    cd "${repo_dir}/${binary}"

    case "$binary" in
        kernel_scheduler)
            local prc="${extra_args[0]:-PHP.prc}"
            if [[ ! "${prc}" = *"/"* ]]; then
                prc="${repo_dir}/kernel_memory/scripts/${prc}"
            fi
            "./bin/${binary}" "${binary}.config" "${prc}"
            ;;
        kernel_memory)
            "./bin/${binary}" "${binary}.config"
            ;;
        cpu)
            local cpu_id="${extra_args[0]:-1}"
            "./bin/${binary}" "${binary}.config" "${cpu_id}"
            ;;
        io)
            local io_type="${extra_args[0]:-SLEEP}"
            "./bin/${binary}" "${binary}.config" "${io_type}"
            ;;
        memory_stick)
            local instance="${extra_args[0]:-1}"
            local config_file="${binary}.config"
            [[ "$instance" -gt 1 ]] && config_file="${binary}_${instance}.config"
            local mem_size="${extra_args[1]:-16}"
            "./bin/${binary}" "${config_file}" "${mem_size}"
            ;;
        swap)
            "./bin/${binary}" "${binary}.config"
            ;;
        *)
            log_err "Binario desconocido: ${binary}"
            echo "Binarios disponibles: kernel_scheduler kernel_memory cpu io memory_stick swap"
            return 1
            ;;
    esac
}

run_local() {
    local binary="$1"; shift
    log_info "=== Ejecutando ${binary} localmente ==="
    run_binary "$binary" "$@"
}

run_remote() {
    local ip="$1" binary="$2"; shift 2
    local extra_args=("$@")
    local remote_dir="~/so-deploy/${REPO_NAME}"

    log_info "=== Ejecutando ${binary} en ${ip} ==="

    local run_cmd="cd ${remote_dir}/${binary}"

    case "$binary" in
        kernel_scheduler)
            local prc="${extra_args[0]:-PHP.prc}"
            if [[ ! "${prc}" = *"/"* ]]; then
                prc="${remote_dir}/kernel_memory/scripts/${prc}"
            fi
            run_cmd+=" && ./bin/${binary} ${binary}.config ${prc}"
            ;;
        kernel_memory)
            run_cmd+=" && ./bin/${binary} ${binary}.config"
            ;;
        cpu)
            local cpu_id="${extra_args[0]:-1}"
            run_cmd+=" && ./bin/${binary} ${binary}.config ${cpu_id}"
            ;;
        io)
            local io_type="${extra_args[0]:-SLEEP}"
            run_cmd+=" && ./bin/${binary} ${binary}.config ${io_type}"
            ;;
        memory_stick)
            local instance="${extra_args[0]:-1}"
            local config_file="${binary}.config"
            [[ "$instance" -gt 1 ]] && config_file="${binary}_${instance}.config"
            local mem_size="${extra_args[1]:-16}"
            run_cmd+=" && ./bin/${binary} ${config_file} ${mem_size}"
            ;;
        swap)
            run_cmd+=" && ./bin/${binary} ${binary}.config"
            ;;
        *)
            log_err "Binario desconocido: ${binary}"
            return 1
            ;;
    esac

    ssh_cmd -t "$ip" "$run_cmd"
}

# =====================================================
# Status
# =====================================================

status_vm() {
    local ip="$1"
    local components local_ip
    local_ip=$(get_local_ip)
    components=$(get_components "$ip")

    if [[ -z "$components" ]]; then
        log_warn "IP desconocida: ${ip}"
        return
    fi

    log_info "VM: ${ip}"

    if [[ "$ip" == "$local_ip" ]]; then
        local repo_dir="${SCRIPT_DIR}/${REPO_NAME}"
        if [[ -d "${repo_dir}" ]]; then
            log_ok "Repositorio clonado"
            for comp in $components; do
                if [[ -f "${repo_dir}/${comp}/bin/${comp}" ]]; then
                    log_ok "Binario compilado: ${comp}"
                else
                    log_err "Binario NO compilado: ${comp}"
                fi
            done
        else
            log_err "Repositorio NO clonado"
        fi
    else
        local remote_dir="~/so-deploy/${REPO_NAME}"
        ssh_cmd "$ip" "
            if [[ -d '${remote_dir}' ]]; then
                echo '  ✓ Repositorio clonado'
                for comp in ${components}; do
                    if [[ -f '${remote_dir}/\${comp}/bin/\${comp}' ]]; then
                        echo \"  ✓ Binario compilado: \${comp}\"
                    else
                        echo \"  ✗ Binario NO compilado: \${comp}\"
                    fi
                done
            else
                echo '  ✗ Repositorio NO clonado'
            fi
        " 2>/dev/null || log_err "No se pudo conectar a ${ip}"
    fi
}

status_all() {
    log_info "=== Status ==="
    echo ""
    for ip in "$VM1_IP" "$VM2_IP" "$VM3_IP"; do
        status_vm "$ip"
        echo ""
    done
}

# =====================================================
# Help
# =====================================================

usage() {
    cat <<EOF
Uso: $(basename "$0") <comando> [args...]

Comandos:
  deploy                      Deploy completo (local + remotas)
  deploy-local                Deploy solo en esta VM
  deploy-remote <IP>          Deploy solo en VM remota

  config <KEY> <VALUE>        Modificar config en todas las VMs
  config-local <KEY> <VALUE>  Modificar config solo local
  config-remote <IP> <KEY> <VALUE>  Modificar config en VM remota

  run <binario> [args...]     Ejecutar binario localmente
  run-remote <IP> <binario> [args...]  Ejecutar binario en VM remota

  status                      Verificar clonacion y compilacion

Binarios:
  kernel_scheduler [prc]      (default: PHP.prc)
  kernel_memory
  cpu [id]                    (default: 1)
  io [tipo]                   (default: SLEEP)
  memory_stick [instancia] [size]  (default: 1, 16)
  swap

Ejemplos:
  $(basename "$0") deploy
  $(basename "$0") config IP_KERNEL_SCHEDULER=192.168.100.99
  $(basename "$0") run kernel_scheduler PHP.prc
  $(basename "$0") run memory_stick 2
  $(basename "$0") run-remote 192.168.100.135 kernel_scheduler
  $(basename "$0") status
EOF
}

# =====================================================
# Main
# =====================================================

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

CMD="$1"; shift

case "$CMD" in
    deploy)
        deploy_all
        ;;
    deploy-local)
        deploy_local
        ;;
    deploy-remote)
        [[ $# -lt 1 ]] && { log_err "Uso: deploy-remote <IP>"; exit 1; }
        deploy_remote "$1"
        ;;
    config)
        [[ $# -lt 2 ]] && { log_err "Uso: config <KEY> <VALUE>"; exit 1; }
        config_all "$1" "$2"
        ;;
    config-local)
        [[ $# -lt 2 ]] && { log_err "Uso: config-local <KEY> <VALUE>"; exit 1; }
        config_local "$1" "$2"
        ;;
    config-remote)
        [[ $# -lt 3 ]] && { log_err "Uso: config-remote <IP> <KEY> <VALUE>"; exit 1; }
        config_remote "$1" "$2" "$3"
        ;;
    run)
        [[ $# -lt 1 ]] && { log_err "Uso: run <binario> [args...]"; exit 1; }
        run_local "$@"
        ;;
    run-remote)
        [[ $# -lt 2 ]] && { log_err "Uso: run-remote <IP> <binario> [args...]"; exit 1; }
        run_remote "$@"
        ;;
    status)
        status_all
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        log_err "Comando desconocido: ${CMD}"
        usage
        exit 1
        ;;
esac
