#!/bin/bash
# =====================================================
# config.sh - Configuracion de VMs para manage.sh
# =====================================================
# Editar este archivo para cambiar IPs y credenciales.
# Los perfiles de componentes se ajustan automaticamente.
# =====================================================

# Credenciales SSH (mismas para todas las VMs)
SSH_USER="luichi"
SSH_PASS="password"

# GitHub Token (para clonar el repo del TP)
GITHUB_TOKEN=""

# IPs de las VMs (modificar segun tu setup)
VM1_IP="192.168.100.134"
VM2_IP="192.168.100.135"
VM3_IP="192.168.100.136"

# Repositorio del TP
REPO_NAME="tp-2026-1c-NexOs"

# =====================================================
# Perfiles de componentes por VM
# (NO editar a menos que cambies que corre en cada VM)
# =====================================================
# VM1: kernel_memory, io
# VM2: kernel_scheduler, memory_stick
# VM3: cpu, swap

# Config flags por VM (usan las IPs de arriba)
# VM1: necesita saber donde esta kernel_scheduler
VM1_CONFIGS="IP_KERNEL_SCHEDULER=${VM2_IP}"

# VM2: necesita saber donde esta kernel_memory
VM2_CONFIGS="IP_KERNEL_MEMORY=${VM1_IP}"

# VM3: necesita saber donde estan kernel_scheduler y kernel_memory
VM3_CONFIGS="IP_KERNEL_SCHEDULER=${VM2_IP} IP_KERNEL_MEMORY=${VM1_IP}"
