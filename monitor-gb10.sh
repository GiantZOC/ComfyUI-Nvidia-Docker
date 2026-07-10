#!/bin/bash
#
# GB10 (DGX Spark / Grace Blackwell) Resource Monitor
# Monitors GPU, memory, CPU, disk, and Docker containers
#

LOG_FILE="/tmp/gb10_monitor.log"
ALERT_LOG="/tmp/gb10_alerts.log"
INTERVAL=5  # seconds between checks

# Thresholds
GPU_TEMP_WARN=75
GPU_TEMP_CRIT=85
GPU_UTIL_WARN=95
POWER_WARN=60  # GB10 can draw ~85W under load, warn above 60W sustained
MEM_WARN_PCT=85
DISK_WARN_PCT=85

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Counters
check_count=0
peak_gpu_temp=0
peak_power=0
peak_gpu_util=0
peak_mem_used=0

print_header() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║         GB10 (Grace Blackwell) Resource Monitor                     ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

get_gpu_info() {
    nvidia-smi --query-gpu=temperature.gpu,utilization.gpu,utilization.memory,power.draw,power.limit,clocks.current.graphics,clocks.max.graphics,clocks.current.memory,clocks.max.memory,pstate --format=csv,noheader,nounits 2>/dev/null
}

get_gpu_processes() {
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null
}

get_container_stats() {
    docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null
}

check_alerts() {
    local temp=$1
    local power=$2
    local gpu_util=$3
    local mem_pct=$4
    local alerts=""

    if [ "$temp" -ge "$GPU_TEMP_CRIT" ]; then
        alerts="${alerts}  ${RED}[CRITICAL]${NC} GPU temperature: ${temp}°C (>${GPU_TEMP_CRIT}°C)\n"
    elif [ "$temp" -ge "$GPU_TEMP_WARN" ]; then
        alerts="${alerts}  ${YELLOW}[WARNING]${NC} GPU temperature: ${temp}°C (>${GPU_TEMP_WARN}°C)\n"
    fi

    if [ "$power" -ge "$POWER_WARN" ]; then
        alerts="${alerts}  ${YELLOW}[WARNING]${NC} Power draw: ${power}W (>${POWER_WARN}W)\n"
    fi

    if [ "$gpu_util" -ge "$GPU_UTIL_WARN" ]; then
        alerts="${alerts}  ${GREEN}[HIGH]${NC} GPU utilization: ${gpu_util}% (sustained high load)\n"
    fi

    if [ "$(echo "$mem_pct > $MEM_WARN_PCT" | bc -l 2>/dev/null || echo 0)" = "1" ]; then
        alerts="${alerts}  ${YELLOW}[WARNING]${NC} Memory usage: ${mem_pct}% (>${MEM_WARN_PCT}%)\n"
    fi

    if [ -n "$alerts" ]; then
        echo -e "$alerts" | tee -a "$ALERT_LOG"
    fi
}

print_status() {
    check_count=$((check_count + 1))
    
    # Get GPU info
    local gpu_line
    gpu_line=$(get_gpu_info)
    
    if [ -z "$gpu_line" ]; then
        echo -e "${RED}ERROR: Unable to query GPU info. Is nvidia-smi working?${NC}"
        return 1
    fi

    IFS=',' read -r gpu_temp gpu_util gpu_mem_util power_draw power_limit clock_gr clock_max_gr clock_mem clock_max_mem pstate <<< "$gpu_line"
    
    # Clean up values (remove whitespace)
    gpu_temp=$(echo "$gpu_temp" | tr -d ' ')
    gpu_util=$(echo "$gpu_util" | tr -d ' ')
    gpu_mem_util=$(echo "$gpu_mem_util" | tr -d ' ')
    power_draw=$(echo "$power_draw" | tr -d ' ')
    power_limit=$(echo "$power_limit" | tr -d ' ')
    clock_gr=$(echo "$clock_gr" | tr -d ' ')
    clock_max_gr=$(echo "$clock_max_gr" | tr -d ' ')
    clock_mem=$(echo "$clock_mem" | tr -d ' ')
    clock_max_mem=$(echo "$clock_max_mem" | tr -d ' ')
    pstate=$(echo "$pstate" | tr -d ' ')

    # Get memory info
    local mem_total mem_used mem_free mem_available mem_pct
    mem_total=$(free -g | grep Mem | tr -s ' ' | cut -d' ' -f2)
    mem_used=$(free -g | grep Mem | tr -s ' ' | cut -d' ' -f4)
    mem_free=$(free -g | grep Mem | tr -s ' ' | cut -d' ' -f3)
    mem_available=$(free -g | grep Mem | tr -s ' ' | cut -d' ' -f7)
    
    if [ "$mem_total" -gt 0 ]; then
        mem_pct=$(echo "scale=1; $mem_used * 100 / $mem_total" | bc)
    else
        mem_pct="0"
    fi

    # Get CPU info
    local cpu_load
    cpu_load=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
    local cpu_count
    cpu_count=$(nproc)

    # Get disk info
    local disk_pct
    disk_pct=$(df / | tail -1 | tr -s ' ' | cut -d' ' -f5 | tr -d '%')

    # Track peaks
    if [ "$gpu_temp" -gt "$peak_gpu_temp" ]; then peak_gpu_temp=$gpu_temp; fi
    if [ "${power_draw%.*}" -gt "$peak_power" ]; then peak_power=${power_draw%.*}; fi
    if [ "$gpu_util" -gt "$peak_gpu_util" ]; then peak_gpu_util=$gpu_util; fi
    if [ "$mem_used" -gt "$peak_mem_used" ]; then peak_mem_used=$mem_used; fi

    # Check alerts
    check_alerts "$gpu_temp" "${power_draw%.*}" "$gpu_util" "$mem_pct"

    # Print header every 20 checks
    if [ $((check_count % 20)) -eq 1 ]; then
        print_header
    fi

    # Timestamp
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # GPU Section
    local temp_color="$GREEN"
    if [ "$gpu_temp" -ge "$GPU_TEMP_CRIT" ]; then temp_color="$RED"
    elif [ "$gpu_temp" -ge "$GPU_TEMP_WARN" ]; then temp_color="$YELLOW"; fi

    local power_color="$GREEN"
    if [ "${power_draw%.*}" -ge "$POWER_WARN" ]; then power_color="$YELLOW"; fi

    echo -e "${BOLD}[$timestamp]${NC} Check #$check_count"
    echo -e "  ${BOLD}GPU (GB10):${NC}"
    echo -e "    Temperature:  ${temp_color}${gpu_temp}°C${NC}  (Peak: ${peak_gpu_temp}°C)"
    echo -e "    Utilization:  ${gpu_util}%  (GPU) / ${gpu_mem_util}% (Memory)  (Peak: ${peak_gpu_util}%)"
    echo -e "    Power Draw:   ${power_color}${power_draw}W${NC} / ${power_limit}W  (Peak: ${peak_power}W)"
    echo -e "    Clocks:       ${clock_gr} / ${clock_max_gr} MHz (GR) | ${clock_mem} / ${clock_max_mem} MHz (MEM)"
    echo -e "    Power State:  P${pstate}"
    echo ""
    
    # Unified Memory Section
    local mem_color="$GREEN"
    if [ "$(echo "$mem_pct > $MEM_WARN_PCT" | bc -l 2>/dev/null || echo 0)" = "1" ]; then mem_color="$YELLOW"; fi

    echo -e "  ${BOLD}Unified Memory (120GB):${NC}"
    echo -e "    Used:         ${mem_color}${mem_used}GB${NC} / ${mem_total}GB (${mem_pct}%)  (Peak: ${peak_mem_used}GB)"
    echo -e "    Free:         ${mem_free}GB"
    echo -e "    Available:    ${mem_available}GB"
    echo ""

    # CPU Section
    echo -e "  ${BOLD}CPU (20 cores):${NC}"
    echo -e "    Load Average: ${cpu_load}  (per ${cpu_count} cores)"
    echo ""

    # Disk Section
    local disk_color="$GREEN"
    if [ "$disk_pct" -ge "$DISK_WARN_PCT" ]; then disk_color="$YELLOW"; fi

    echo -e "  ${BOLD}Disk:${NC}"
    echo -e "    /            ${disk_color}${disk_pct}%${NC} used"
    echo ""

    # Container Stats
    echo -e "  ${BOLD}Docker Containers:${NC}"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    printf "  %-25s %8s  %15s  %8s\n" "CONTAINER" "CPU%" "MEM USAGE" "MEM%"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    
    docker stats --no-stream --format "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}" 2>/dev/null | while IFS=$'\t' read -r name cpu mem mem_pct; do
        if [ "$name" = "NAME" ]; then continue; fi
        printf "  %-25s %8s  %15s  %8s\n" "$name" "$cpu" "$mem" "$mem_pct"
    done
    
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    echo ""

    # GPU Processes (vLLM / ComfyUI)
    echo -e "  ${BOLD}GPU Processes:${NC}"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    printf "  %-10s %-30s %10s\n" "PID" "PROCESS" "GPU MEM"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader 2>/dev/null | while IFS=',' read -r pid name mem; do
        pid=$(echo "$pid" | tr -d ' ')
        name=$(echo "$name" | tr -d ' ')
        mem=$(echo "$mem" | tr -d ' ')
        printf "  %-10s %-30s %8s\n" "$pid" "$name" "$mem"
    done
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────${NC}"
    echo ""

    # System summary
    echo -e "  ${BOLD}System:${NC}"
    echo -e "    Kernel: $(uname -r)"
    echo -e "    Uptime: $(uptime -p 2>/dev/null || uptime)"
    echo -e "    Swap:   $(free -h | grep Swap | awk '{print $3, "/", $2}')"
    echo ""
    echo -e "  Press ${RED}Ctrl+C${NC} to stop monitoring"
    echo ""
}

# Main loop
echo -e "${BOLD}Starting GB10 Resource Monitor...${NC}"
echo -e "Log file: ${LOG_FILE}"
echo -e "Alert log:  ${ALERT_LOG}"
echo -e "Interval:   ${INTERVAL}s"
echo -e "Press Ctrl+C to stop\n"

# Log header
echo "" | tee -a "$LOG_FILE"
echo "=== GB10 Monitor Started: $(date) ===" | tee -a "$LOG_FILE"

while true; do
    print_status 2>&1 | tee -a "$LOG_FILE"
    sleep "$INTERVAL"
done
