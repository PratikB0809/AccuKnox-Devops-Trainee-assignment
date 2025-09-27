#!/bin/bash

#########################################################################
# Linux System Health Monitor Script
# Author: DevOps Engineer
# Description: Monitors CPU, Memory, Disk space, and Running processes
# Version: 1.0
# Date: $(date +%Y-%m-%d)
#########################################################################

# Script Configuration
SCRIPT_NAME="System Health Monitor"
VERSION="1.0"
LOG_FILE="/var/log/system_health_monitor.log"
ALERT_LOG="/var/log/system_health_alerts.log"
ENABLE_EMAIL_ALERTS=0  # Set to 1 to enable email notifications
NOTIFICATION_EMAIL="admin@example.com"
HOSTNAME=$(hostname)

# Default Thresholds (can be overridden by command line arguments)
CPU_THRESHOLD=80
MEMORY_THRESHOLD=80
DISK_THRESHOLD=80
PROCESS_COUNT_THRESHOLD=200

# Color codes for console output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Initialize alert flags
CPU_ALERT=0
MEMORY_ALERT=0
DISK_ALERT=0
PROCESS_ALERT=0

#########################################################################
# Helper Functions
#########################################################################

# Function to print colored output
print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to log messages with timestamp
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"

    # Also log to console with color
    case $level in
        "ERROR")
            print_color "$RED" "[$timestamp] [ERROR] $message"
            ;;
        "WARNING")
            print_color "$YELLOW" "[$timestamp] [WARNING] $message"
            ;;
        "INFO")
            print_color "$GREEN" "[$timestamp] [INFO] $message"
            ;;
        *)
            echo "[$timestamp] [$level] $message"
            ;;
    esac
}

# Function to send email alert
send_email_alert() {
    local subject=$1
    local message=$2

    if [[ $ENABLE_EMAIL_ALERTS -eq 1 ]]; then
        echo "$message" | mail -s "$subject - $HOSTNAME" "$NOTIFICATION_EMAIL"
        log_message "INFO" "Email alert sent to $NOTIFICATION_EMAIL"
    fi
}

# Function to log alerts to separate alert file
log_alert() {
    local alert_type=$1
    local current_value=$2
    local threshold=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local alert_message="ALERT: $alert_type usage exceeded threshold! Current: $current_value%, Threshold: $threshold%"
    echo "[$timestamp] $alert_message" >> "$ALERT_LOG"
    log_message "ERROR" "$alert_message"

    # Send email if enabled
    send_email_alert "$alert_type ALERT" "$alert_message\nHostname: $HOSTNAME\nTime: $timestamp"
}

#########################################################################
# System Monitoring Functions
#########################################################################

# Function to check CPU usage
check_cpu_usage() {
    log_message "INFO" "Checking CPU usage..."

    # Get CPU usage using top command (1 minute average)
    local cpu_usage=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{printf "%.0f", 100 - $1}')

    # Alternative method using vmstat
    if [[ -z "$cpu_usage" ]]; then
        cpu_usage=$(vmstat 1 2 | tail -1 | awk '{printf "%.0f", 100-$15}')
    fi

    print_color "$BLUE" "=== CPU Usage Report ==="
    echo "Current CPU Usage: ${cpu_usage}%"
    echo "CPU Threshold: ${CPU_THRESHOLD}%"

    # Show top 5 CPU consuming processes
    echo "Top 5 CPU consuming processes:"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -6

    if [[ $cpu_usage -ge $CPU_THRESHOLD ]]; then
        CPU_ALERT=1
        log_alert "CPU" "$cpu_usage" "$CPU_THRESHOLD"
        return 1
    else
        log_message "INFO" "CPU usage is normal: ${cpu_usage}%"
        return 0
    fi
}

# Function to check memory usage
check_memory_usage() {
    log_message "INFO" "Checking memory usage..."

    # Get memory usage percentage
    local memory_info=$(free -m | awk 'NR==2{printf "%.0f %.0f %.0f %.0f", $3,$2,$4,($3/$2)*100}')
    read used_mem total_mem free_mem mem_usage_percent <<< "$memory_info"

    print_color "$BLUE" "=== Memory Usage Report ==="
    echo "Total Memory: ${total_mem}MB"
    echo "Used Memory: ${used_mem}MB"
    echo "Free Memory: ${free_mem}MB"
    echo "Memory Usage: ${mem_usage_percent}%"
    echo "Memory Threshold: ${MEMORY_THRESHOLD}%"

    # Show swap usage
    local swap_info=$(free -m | awk 'NR==3{printf "%.0f %.0f", $3,$2}')
    read swap_used swap_total <<< "$swap_info"
    if [[ $swap_total -gt 0 ]]; then
        local swap_usage=$((swap_used * 100 / swap_total))
        echo "Swap Usage: ${swap_used}MB / ${swap_total}MB (${swap_usage}%)"
    fi

    # Show top 5 memory consuming processes
    echo "Top 5 memory consuming processes:"
    ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%mem | head -6

    if [[ $mem_usage_percent -ge $MEMORY_THRESHOLD ]]; then
        MEMORY_ALERT=1
        log_alert "MEMORY" "$mem_usage_percent" "$MEMORY_THRESHOLD"
        return 1
    else
        log_message "INFO" "Memory usage is normal: ${mem_usage_percent}%"
        return 0
    fi
}

# Function to check disk usage
check_disk_usage() {
    log_message "INFO" "Checking disk usage..."

    print_color "$BLUE" "=== Disk Usage Report ==="
    echo "Disk Usage by Filesystem:"
    printf "%-20s %-10s %-10s %-10s %-6s %-s\n" "Filesystem" "Size" "Used" "Avail" "Use%" "Mounted on"

    local alert_triggered=0

    # Check all mounted filesystems
    while IFS= read -r line; do
        # Skip header line and special filesystems
        if [[ $line =~ ^/dev/ ]] || [[ $line =~ ^/ ]]; then
            local fs_info=($line)
            local filesystem=${fs_info[0]}
            local size=${fs_info[1]}
            local used=${fs_info[2]}
            local available=${fs_info[3]}
            local usage_percent=${fs_info[4]%\%}
            local mount_point=${fs_info[5]}

            printf "%-20s %-10s %-10s %-10s %-6s %-s\n" "$filesystem" "$size" "$used" "$available" "${usage_percent}%" "$mount_point"

            # Check if usage exceeds threshold
            if [[ $usage_percent -ge $DISK_THRESHOLD ]]; then
                DISK_ALERT=1
                alert_triggered=1
                log_alert "DISK ($mount_point)" "$usage_percent" "$DISK_THRESHOLD"
            fi
        fi
    done < <(df -h | tail -n +2)

    echo "Disk Threshold: ${DISK_THRESHOLD}%"

    if [[ $alert_triggered -eq 0 ]]; then
        log_message "INFO" "Disk usage is normal on all filesystems"
        return 0
    else
        return 1
    fi
}

# Function to check running processes
check_processes() {
    log_message "INFO" "Checking running processes..."

    local process_count=$(ps aux --no-heading | wc -l)
    local zombie_count=$(ps aux | awk '{print $8}' | grep -c '^Z')

    print_color "$BLUE" "=== Process Report ==="
    echo "Total running processes: $process_count"
    echo "Process threshold: $PROCESS_COUNT_THRESHOLD"
    echo "Zombie processes: $zombie_count"

    # Show system load averages
    echo "System Load Averages:"
    uptime

    # Show top processes by CPU and Memory
    echo "Top 5 processes by CPU usage:"
    ps aux --sort=-%cpu | head -6

    if [[ $process_count -ge $PROCESS_COUNT_THRESHOLD ]]; then
        PROCESS_ALERT=1
        log_alert "PROCESS COUNT" "$process_count" "$PROCESS_COUNT_THRESHOLD"
        return 1
    else
        log_message "INFO" "Process count is normal: $process_count"
        return 0
    fi
}

# Function to display system information
show_system_info() {
    print_color "$BLUE" "=== System Information ==="
    echo "Hostname: $HOSTNAME"
    echo "Kernel Version: $(uname -r)"
    echo "OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d= -f2 | tr -d '"')"
    echo "Uptime: $(uptime -p)"
    echo "Current Date: $(date)"
    echo "System Load: $(uptime | awk -F'load average:' '{print $2}')"
    echo ""
}

# Function to generate summary report
generate_summary() {
    local total_alerts=$((CPU_ALERT + MEMORY_ALERT + DISK_ALERT + PROCESS_ALERT))

    print_color "$BLUE" "=== Health Check Summary ==="
    if [[ $total_alerts -eq 0 ]]; then
        print_color "$GREEN" "✓ System Health: GOOD - No alerts triggered"
        log_message "INFO" "System health check completed successfully - No issues found"
    else
        print_color "$RED" "✗ System Health: CRITICAL - $total_alerts alert(s) triggered"
        log_message "ERROR" "System health check completed with $total_alerts alert(s)"

        echo "Alert Summary:"
        [[ $CPU_ALERT -eq 1 ]] && echo "  - CPU usage exceeded threshold"
        [[ $MEMORY_ALERT -eq 1 ]] && echo "  - Memory usage exceeded threshold"
        [[ $DISK_ALERT -eq 1 ]] && echo "  - Disk usage exceeded threshold"
        [[ $PROCESS_ALERT -eq 1 ]] && echo "  - Process count exceeded threshold"
    fi

    echo "Detailed logs available at: $LOG_FILE"
    echo "Alert logs available at: $ALERT_LOG"
    echo ""
}

#########################################################################
# Main Script Functions
#########################################################################

# Function to display usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

$SCRIPT_NAME v$VERSION
Monitors Linux system health including CPU, Memory, Disk, and Processes

OPTIONS:
    -c, --cpu-threshold NUM        Set CPU threshold percentage (default: $CPU_THRESHOLD)
    -m, --memory-threshold NUM     Set memory threshold percentage (default: $MEMORY_THRESHOLD)
    -d, --disk-threshold NUM       Set disk threshold percentage (default: $DISK_THRESHOLD)
    -p, --process-threshold NUM    Set process count threshold (default: $PROCESS_COUNT_THRESHOLD)
    -e, --enable-email             Enable email notifications
    -l, --log-file PATH            Set log file path (default: $LOG_FILE)
    -q, --quiet                    Quiet mode (log only, no console output)
    -h, --help                     Show this help message
    -v, --version                  Show version information

EXAMPLES:
    $0                             # Run with default settings
    $0 -c 90 -m 85 -d 75          # Set custom thresholds
    $0 -e                          # Enable email notifications
    $0 -q -l /tmp/health.log       # Quiet mode with custom log file

THRESHOLDS:
    CPU: Alert when CPU usage > threshold%
    Memory: Alert when memory usage > threshold%
    Disk: Alert when any filesystem usage > threshold%
    Processes: Alert when process count > threshold

EOF
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--cpu-threshold)
                CPU_THRESHOLD="$2"
                shift 2
                ;;
            -m|--memory-threshold)
                MEMORY_THRESHOLD="$2"
                shift 2
                ;;
            -d|--disk-threshold)
                DISK_THRESHOLD="$2"
                shift 2
                ;;
            -p|--process-threshold)
                PROCESS_COUNT_THRESHOLD="$2"
                shift 2
                ;;
            -e|--enable-email)
                ENABLE_EMAIL_ALERTS=1
                shift
                ;;
            -l|--log-file)
                LOG_FILE="$2"
                ALERT_LOG="${LOG_FILE%.log}_alerts.log"
                shift 2
                ;;
            -q|--quiet)
                exec > /dev/null 2>&1
                shift
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--version)
                echo "$SCRIPT_NAME v$VERSION"
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
}

# Function to create log files if they don't exist
setup_logging() {
    # Create log directory if it doesn't exist
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        sudo mkdir -p "$log_dir" 2>/dev/null || {
            LOG_FILE="./system_health_monitor.log"
            ALERT_LOG="./system_health_alerts.log"
            echo "Warning: Cannot create $log_dir, using current directory for logs"
        }
    fi

    # Test write permissions
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="./system_health_monitor.log"
        ALERT_LOG="./system_health_alerts.log"
        echo "Warning: Cannot write to log file, using current directory"
    fi
}

# Main function
main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Setup logging
    setup_logging

    # Script start
    print_color "$GREEN" "Starting $SCRIPT_NAME v$VERSION"
    log_message "INFO" "=== $SCRIPT_NAME v$VERSION Started ==="
    log_message "INFO" "Thresholds - CPU: $CPU_THRESHOLD%, Memory: $MEMORY_THRESHOLD%, Disk: $DISK_THRESHOLD%, Processes: $PROCESS_COUNT_THRESHOLD"

    # Display system information
    show_system_info

    # Run health checks
    echo "Performing system health checks..."
    echo "================================="

    check_cpu_usage
    echo ""

    check_memory_usage
    echo ""

    check_disk_usage
    echo ""

    check_processes
    echo ""

    # Generate summary
    generate_summary

    # Script end
    log_message "INFO" "=== $SCRIPT_NAME v$VERSION Completed ==="

    # Exit with appropriate code
    local total_alerts=$((CPU_ALERT + MEMORY_ALERT + DISK_ALERT + PROCESS_ALERT))
    exit $total_alerts
}

#########################################################################
# Script Execution
#########################################################################

# Trap signals for cleanup
trap 'log_message "INFO" "Script interrupted by user"; exit 130' INT TERM

# Check if running as root for certain operations
if [[ $EUID -ne 0 ]]; then
    echo "Note: Running as non-root user. Some features may have limited functionality."
fi

# Run main function with all arguments
main "$@"
