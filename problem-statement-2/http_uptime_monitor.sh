#!/bin/bash

#########################################################################
# HTTP Application Uptime Monitor Script
# Author: DevOps Engineer  
# Description: Monitors application uptime via HTTP status codes
# Version: 1.0
# Date: $(date +%Y-%m-%d)
#########################################################################

# Script Configuration
SCRIPT_NAME="HTTP Application Uptime Monitor"
VERSION="1.0"
LOG_FILE="/var/log/app_uptime_monitor.log"
ALERT_LOG="/var/log/app_uptime_alerts.log"
CONFIG_FILE="/etc/app_uptime_monitor.conf"
HOSTNAME=$(hostname)

# Default Configuration (can be overridden by config file or command line)
ENABLE_EMAIL_ALERTS=0
NOTIFICATION_EMAIL="admin@example.com"
RETRY_COUNT=3
RETRY_DELAY=5
CONNECTION_TIMEOUT=10
MAX_REQUEST_TIME=30
CHECK_INTERVAL=300  # 5 minutes
ENABLE_SLACK_ALERTS=0
SLACK_WEBHOOK_URL=""
ENABLE_SMS_ALERTS=0
SMS_SERVICE="twilio"  # or "aws-sns"

# Applications to monitor (default list)
declare -A APPLICATIONS
APPLICATIONS=(
    ["WebApp"]="https://example.com,200,/"
    ["API"]="https://api.example.com/health,200,/health"
    ["Database"]="https://db.example.com:3306,,tcp"
)

# Status tracking
declare -A APP_STATUS
declare -A APP_LAST_DOWN
declare -A APP_DOWN_COUNT
declare -A APP_RESPONSE_TIMES

# Color codes for console output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Alert states
declare -A ALERT_STATES

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

    # Also log to console based on level
    case $level in
        "ERROR")
            print_color "$RED" "[$timestamp] [ERROR] $message"
            ;;
        "WARNING")
            print_color "$YELLOW" "[$timestamp] [WARNING] $message"
            ;;
        "SUCCESS")
            print_color "$GREEN" "[$timestamp] [SUCCESS] $message"
            ;;
        "INFO")
            print_color "$CYAN" "[$timestamp] [INFO] $message"
            ;;
        *)
            echo "[$timestamp] [$level] $message"
            ;;
    esac
}

# Function to load configuration file
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        log_message "INFO" "Loading configuration from $CONFIG_FILE"
        source "$CONFIG_FILE"
    else
        log_message "INFO" "No configuration file found at $CONFIG_FILE, using defaults"
    fi
}

# Function to send email alert
send_email_alert() {
    local subject=$1
    local message=$2
    local app_name=$3

    if [[ $ENABLE_EMAIL_ALERTS -eq 1 ]] && command -v mail &> /dev/null; then
        local full_subject="[$HOSTNAME] $subject - $app_name"
        echo -e "$message" | mail -s "$full_subject" "$NOTIFICATION_EMAIL"
        log_message "INFO" "Email alert sent to $NOTIFICATION_EMAIL for $app_name"
        return 0
    fi
    return 1
}

# Function to send Slack alert
send_slack_alert() {
    local message=$1
    local app_name=$2
    local status=$3

    if [[ $ENABLE_SLACK_ALERTS -eq 1 ]] && [[ -n "$SLACK_WEBHOOK_URL" ]] && command -v curl &> /dev/null; then
        local color="danger"
        [[ "$status" == "UP" ]] && color="good"
        [[ "$status" == "RECOVERED" ]] && color="good"

        local json_payload=$(cat <<EOF
{
    "attachments": [
        {
            "color": "$color",
            "title": "Application Status Alert",
            "fields": [
                {
                    "title": "Application",
                    "value": "$app_name",
                    "short": true
                },
                {
                    "title": "Status",
                    "value": "$status",
                    "short": true
                },
                {
                    "title": "Server",
                    "value": "$HOSTNAME",
                    "short": true
                },
                {
                    "title": "Time",
                    "value": "$(date '+%Y-%m-%d %H:%M:%S')",
                    "short": true
                }
            ],
            "text": "$message"
        }
    ]
}
EOF
        )

        curl -X POST -H 'Content-type: application/json' \
             --data "$json_payload" \
             --max-time 10 \
             "$SLACK_WEBHOOK_URL" &> /dev/null

        if [[ $? -eq 0 ]]; then
            log_message "INFO" "Slack alert sent for $app_name"
            return 0
        else
            log_message "ERROR" "Failed to send Slack alert for $app_name"
        fi
    fi
    return 1
}

# Function to log alert
log_alert() {
    local app_name=$1
    local status=$2
    local details=$3
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local alert_message="ALERT: $app_name is $status - $details"
    echo "[$timestamp] $alert_message" >> "$ALERT_LOG"
    log_message "ERROR" "$alert_message"

    # Send notifications
    send_email_alert "Application $status" "$alert_message\nTime: $timestamp\nServer: $HOSTNAME" "$app_name"
    send_slack_alert "$alert_message" "$app_name" "$status"
}

# Function to log recovery
log_recovery() {
    local app_name=$1
    local downtime=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local recovery_message="RECOVERY: $app_name is UP again after $downtime seconds downtime"
    echo "[$timestamp] $recovery_message" >> "$ALERT_LOG"
    log_message "SUCCESS" "$recovery_message"

    # Send recovery notifications
    send_email_alert "Application RECOVERED" "$recovery_message\nTime: $timestamp\nServer: $HOSTNAME" "$app_name"
    send_slack_alert "$recovery_message" "$app_name" "RECOVERED"
}

#########################################################################
# HTTP Monitoring Functions
#########################################################################

# Function to check HTTP endpoint
check_http_endpoint() {
    local url=$1
    local expected_status=$2
    local app_name=$3
    local timeout=${4:-$MAX_REQUEST_TIME}

    log_message "INFO" "Checking HTTP endpoint: $url (expecting $expected_status)"

    local start_time=$(date +%s.%3N)
    local response=$(curl -s \
        --max-time "$timeout" \
        --connect-timeout "$CONNECTION_TIMEOUT" \
        --write-out "HTTPSTATUS:%{http_code};TIME:%{time_total};SIZE:%{size_download}" \
        --output /dev/null \
        --user-agent "UptimeMonitor/1.0" \
        --location \
        --insecure \
        "$url" 2>/dev/null)

    local curl_exit_code=$?
    local end_time=$(date +%s.%3N)
    local total_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")

    # Parse curl response
    local http_status=$(echo "$response" | grep -o "HTTPSTATUS:[0-9]*" | cut -d: -f2)
    local response_time=$(echo "$response" | grep -o "TIME:[0-9.]*" | cut -d: -f2)
    local response_size=$(echo "$response" | grep -o "SIZE:[0-9]*" | cut -d: -f2)

    # Store response time
    APP_RESPONSE_TIMES["$app_name"]=$response_time

    # Check if curl command succeeded
    if [[ $curl_exit_code -ne 0 ]]; then
        case $curl_exit_code in
            6) return 1 ;; # Could not resolve host
            7) return 2 ;; # Failed to connect
            28) return 3 ;; # Timeout
            *) return 4 ;; # Other error
        esac
    fi

    # Check if we got expected status code
    if [[ "$http_status" == "$expected_status" ]]; then
        log_message "SUCCESS" "$app_name: HTTP $http_status (${response_time}s, ${response_size:-0} bytes)"
        return 0
    else
        log_message "ERROR" "$app_name: HTTP $http_status (expected $expected_status)"
        return 5
    fi
}

# Function to check TCP port
check_tcp_port() {
    local host=$1
    local port=$2
    local app_name=$3
    local timeout=${4:-$CONNECTION_TIMEOUT}

    log_message "INFO" "Checking TCP port: $host:$port"

    local start_time=$(date +%s.%3N)
    timeout "$timeout" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null
    local result=$?
    local end_time=$(date +%s.%3N)
    local total_time=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")

    APP_RESPONSE_TIMES["$app_name"]=$total_time

    if [[ $result -eq 0 ]]; then
        log_message "SUCCESS" "$app_name: TCP $host:$port is open (${total_time}s)"
        return 0
    else
        log_message "ERROR" "$app_name: TCP $host:$port is not accessible"
        return 1
    fi
}

# Function to monitor single application
monitor_application() {
    local app_name=$1
    local config=$2

    # Parse configuration: URL,expected_status,path,type
    IFS=',' read -ra CONFIG_PARTS <<< "$config"
    local url="${CONFIG_PARTS[0]}"
    local expected_status="${CONFIG_PARTS[1]:-200}"
    local path="${CONFIG_PARTS[2]:-/}"
    local check_type="${CONFIG_PARTS[3]:-http}"

    log_message "INFO" "Monitoring $app_name: $url (type: $check_type)"

    local check_result=1
    local retry_attempts=0
    local error_details=""

    # Perform checks with retries
    while [[ $retry_attempts -lt $RETRY_COUNT ]]; do
        if [[ "$check_type" == "tcp" ]]; then
            # Extract host and port from URL
            local host=$(echo "$url" | sed 's|.*://||' | cut -d: -f1)
            local port=$(echo "$url" | sed 's|.*://||' | cut -d: -f2 | cut -d/ -f1)
            check_tcp_port "$host" "$port" "$app_name"
            check_result=$?
        else
            # HTTP check
            check_http_endpoint "$url" "$expected_status" "$app_name"
            check_result=$?
        fi

        if [[ $check_result -eq 0 ]]; then
            break
        fi

        retry_attempts=$((retry_attempts + 1))
        if [[ $retry_attempts -lt $RETRY_COUNT ]]; then
            log_message "WARNING" "$app_name: Check failed (attempt $retry_attempts/$RETRY_COUNT), retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
    done

    # Determine error details based on result code
    case $check_result in
        0) error_details="OK" ;;
        1) error_details="Connection failed or host unreachable" ;;
        2) error_details="Failed to connect to host" ;;
        3) error_details="Request timeout" ;;
        4) error_details="Curl error" ;;
        5) error_details="Unexpected HTTP status code" ;;
        *) error_details="Unknown error" ;;
    esac

    # Update application status
    local current_time=$(date +%s)
    local previous_status="${APP_STATUS[$app_name]:-UNKNOWN}"

    if [[ $check_result -eq 0 ]]; then
        # Application is UP
        if [[ "$previous_status" == "DOWN" ]]; then
            # Recovery detected
            local down_time=${APP_LAST_DOWN[$app_name]:-$current_time}
            local downtime=$((current_time - down_time))
            log_recovery "$app_name" "$downtime"
            APP_DOWN_COUNT["$app_name"]=0
        fi
        APP_STATUS["$app_name"]="UP"
        ALERT_STATES["$app_name"]=0
    else
        # Application is DOWN
        if [[ "$previous_status" != "DOWN" ]]; then
            # New failure detected
            APP_LAST_DOWN["$app_name"]=$current_time
            APP_DOWN_COUNT["$app_name"]=1
            log_alert "$app_name" "DOWN" "$error_details"
        else
            # Still down, increment counter
            APP_DOWN_COUNT["$app_name"]=$((${APP_DOWN_COUNT[$app_name]} + 1))
        fi
        APP_STATUS["$app_name"]="DOWN"
        ALERT_STATES["$app_name"]=1
    fi

    return $check_result
}

#########################################################################
# Reporting Functions
#########################################################################

# Function to generate status report
generate_status_report() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    print_color "$BLUE" "=== Application Uptime Status Report ==="
    echo "Report generated: $timestamp"
    echo "Hostname: $HOSTNAME"
    echo ""

    printf "%-20s %-10s %-15s %-10s %-s\n" "Application" "Status" "Response Time" "Down Count" "Last Check"
    printf "%-20s %-10s %-15s %-10s %-s\n" "----------" "------" "-------------" "----------" "----------"

    local total_apps=0
    local up_apps=0
    local down_apps=0

    for app_name in "${!APPLICATIONS[@]}"; do
        local status="${APP_STATUS[$app_name]:-UNKNOWN}"
        local response_time="${APP_RESPONSE_TIMES[$app_name]:-N/A}"
        local down_count="${APP_DOWN_COUNT[$app_name]:-0}"

        # Format response time
        if [[ "$response_time" != "N/A" ]]; then
            response_time="${response_time}s"
        fi

        # Color code status
        local color="$NC"
        case $status in
            "UP") color="$GREEN"; up_apps=$((up_apps + 1)) ;;
            "DOWN") color="$RED"; down_apps=$((down_apps + 1)) ;;
            *) color="$YELLOW" ;;
        esac

        printf "%-20s " "$app_name"
        print_color "$color" "$(printf "%-10s" "$status")"
        printf "%-15s %-10s %-s\n" "$response_time" "$down_count" "$timestamp"

        total_apps=$((total_apps + 1))
    done

    echo ""
    print_color "$BLUE" "=== Summary ==="
    echo "Total Applications: $total_apps"
    print_color "$GREEN" "UP: $up_apps"
    print_color "$RED" "DOWN: $down_apps"

    # Calculate uptime percentage
    if [[ $total_apps -gt 0 ]]; then
        local uptime_percentage=$(echo "scale=2; $up_apps * 100 / $total_apps" | bc 2>/dev/null || echo "0")
        echo "Overall Uptime: ${uptime_percentage}%"
    fi

    echo ""
}

# Function to generate detailed report
generate_detailed_report() {
    generate_status_report

    print_color "$BLUE" "=== Application Details ==="
    for app_name in "${!APPLICATIONS[@]}"; do
        local config="${APPLICATIONS[$app_name]}"
        IFS=',' read -ra CONFIG_PARTS <<< "$config"
        local url="${CONFIG_PARTS[0]}"
        local expected_status="${CONFIG_PARTS[1]:-200}"
        local check_type="${CONFIG_PARTS[3]:-http}"

        echo ""
        print_color "$CYAN" "Application: $app_name"
        echo "  URL/Endpoint: $url"
        echo "  Expected Status: $expected_status"
        echo "  Check Type: $check_type"
        echo "  Current Status: ${APP_STATUS[$app_name]:-UNKNOWN}"
        echo "  Response Time: ${APP_RESPONSE_TIMES[$app_name]:-N/A}s"
        echo "  Failure Count: ${APP_DOWN_COUNT[$app_name]:-0}"

        if [[ "${APP_STATUS[$app_name]}" == "DOWN" && -n "${APP_LAST_DOWN[$app_name]}" ]]; then
            local down_time=${APP_LAST_DOWN[$app_name]}
            local current_time=$(date +%s)
            local downtime=$((current_time - down_time))
            echo "  Down Since: $(date -d @$down_time '+%Y-%m-%d %H:%M:%S')"
            echo "  Downtime: ${downtime}s"
        fi
    done
    echo ""
}

#########################################################################
# Configuration Management
#########################################################################

# Function to add application to monitor
add_application() {
    local app_name=$1
    local url=$2
    local expected_status=${3:-200}
    local check_type=${4:-http}

    APPLICATIONS["$app_name"]="$url,$expected_status,/,$check_type"
    log_message "INFO" "Added application $app_name for monitoring"
}

# Function to remove application from monitoring
remove_application() {
    local app_name=$1
    unset APPLICATIONS["$app_name"]
    unset APP_STATUS["$app_name"]
    unset APP_LAST_DOWN["$app_name"]
    unset APP_DOWN_COUNT["$app_name"]
    unset APP_RESPONSE_TIMES["$app_name"]
    log_message "INFO" "Removed application $app_name from monitoring"
}

# Function to load applications from file
load_applications_from_file() {
    local file_path=$1

    if [[ ! -f "$file_path" ]]; then
        log_message "ERROR" "Applications file not found: $file_path"
        return 1
    fi

    log_message "INFO" "Loading applications from $file_path"

    # Clear existing applications
    APPLICATIONS=()

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse line: name,url,expected_status,check_type
        IFS=',' read -ra APP_CONFIG <<< "$line"
        local app_name="${APP_CONFIG[0]}"
        local url="${APP_CONFIG[1]}"
        local expected_status="${APP_CONFIG[2]:-200}"
        local check_type="${APP_CONFIG[3]:-http}"

        if [[ -n "$app_name" && -n "$url" ]]; then
            APPLICATIONS["$app_name"]="$url,$expected_status,/,$check_type"
            log_message "INFO" "Loaded application: $app_name -> $url"
        fi
    done < "$file_path"
}

#########################################################################
# Main Script Functions
#########################################################################

# Function to display usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

$SCRIPT_NAME v$VERSION
Monitors application uptime by checking HTTP status codes and TCP ports

OPTIONS:
    -a, --add-app NAME,URL,STATUS,TYPE    Add application to monitor
    -r, --remove-app NAME                 Remove application from monitoring  
    -f, --apps-file PATH                  Load applications from file
    -c, --config PATH                     Use custom configuration file
    -i, --interval SECONDS                Set check interval (default: $CHECK_INTERVAL)
    -t, --timeout SECONDS                 Set request timeout (default: $MAX_REQUEST_TIME)
    --retry-count NUMBER                  Set retry count (default: $RETRY_COUNT)
    --retry-delay SECONDS                 Set retry delay (default: $RETRY_DELAY)
    -e, --enable-email                    Enable email notifications
    --email ADDRESS                       Set notification email address
    --enable-slack                        Enable Slack notifications  
    --slack-webhook URL                   Set Slack webhook URL
    -o, --once                            Run once and exit (don't loop)
    -d, --detailed                        Show detailed report
    -q, --quiet                           Quiet mode (log only)
    -h, --help                            Show this help message
    -v, --version                         Show version information

EXAMPLES:
    $0                                    # Run with default settings
    $0 -a "WebApp,https://example.com,200,http"  # Add application
    $0 -f /etc/apps.txt                   # Load apps from file
    $0 -i 60 -t 15                        # Check every 60s, 15s timeout
    $0 -e --email admin@company.com       # Enable email alerts
    $0 -o -d                              # Run once with detailed output

CONFIGURATION FILE FORMAT:
    The applications file should contain one application per line:
    AppName,URL,ExpectedStatus,CheckType

    Examples:
    WebSite,https://example.com,200,http
    API,https://api.example.com/health,200,http
    Database,db.example.com:5432,200,tcp

EOF
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -a|--add-app)
                IFS=',' read -ra APP_PARTS <<< "$2"
                if [[ ${#APP_PARTS[@]} -ge 2 ]]; then
                    add_application "${APP_PARTS[0]}" "${APP_PARTS[1]}" "${APP_PARTS[2]}" "${APP_PARTS[3]}"
                else
                    echo "Error: Invalid application format. Use: NAME,URL,STATUS,TYPE"
                    exit 1
                fi
                shift 2
                ;;
            -r|--remove-app)
                remove_application "$2"
                shift 2
                ;;
            -f|--apps-file)
                load_applications_from_file "$2"
                shift 2
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
                ;;
            -i|--interval)
                CHECK_INTERVAL="$2"
                shift 2
                ;;
            -t|--timeout)
                MAX_REQUEST_TIME="$2"
                shift 2
                ;;
            --retry-count)
                RETRY_COUNT="$2"
                shift 2
                ;;
            --retry-delay)
                RETRY_DELAY="$2"
                shift 2
                ;;
            -e|--enable-email)
                ENABLE_EMAIL_ALERTS=1
                shift
                ;;
            --email)
                NOTIFICATION_EMAIL="$2"
                ENABLE_EMAIL_ALERTS=1
                shift 2
                ;;
            --enable-slack)
                ENABLE_SLACK_ALERTS=1
                shift
                ;;
            --slack-webhook)
                SLACK_WEBHOOK_URL="$2"
                ENABLE_SLACK_ALERTS=1
                shift 2
                ;;
            -o|--once)
                RUN_ONCE=1
                shift
                ;;
            -d|--detailed)
                DETAILED_REPORT=1
                shift
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

# Function to setup logging
setup_logging() {
    # Create log directory if it doesn't exist
    local log_dir=$(dirname "$LOG_FILE")
    if [[ ! -d "$log_dir" ]]; then
        sudo mkdir -p "$log_dir" 2>/dev/null || {
            LOG_FILE="./app_uptime_monitor.log"
            ALERT_LOG="./app_uptime_alerts.log"
            echo "Warning: Cannot create $log_dir, using current directory for logs"
        }
    fi

    # Test write permissions
    if ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="./app_uptime_monitor.log"
        ALERT_LOG="./app_uptime_alerts.log"
        echo "Warning: Cannot write to log file, using current directory"
    fi
}

# Function to validate dependencies
check_dependencies() {
    local missing_deps=()

    # Check for required commands
    command -v curl >/dev/null 2>&1 || missing_deps+=("curl")
    command -v bc >/dev/null 2>&1 || missing_deps+=("bc")

    # Check for optional commands
    if [[ $ENABLE_EMAIL_ALERTS -eq 1 ]]; then
        command -v mail >/dev/null 2>&1 || {
            log_message "WARNING" "mail command not found - email alerts will not work"
        }
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_message "ERROR" "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install missing dependencies:"
        echo "  Ubuntu/Debian: sudo apt-get install ${missing_deps[*]}"
        echo "  RHEL/CentOS: sudo yum install ${missing_deps[*]}"
        exit 1
    fi
}

# Main monitoring loop
monitor_loop() {
    local loop_count=0

    while true; do
        loop_count=$((loop_count + 1))
        log_message "INFO" "Starting monitoring cycle #$loop_count"

        # Check if we have any applications to monitor
        if [[ ${#APPLICATIONS[@]} -eq 0 ]]; then
            log_message "WARNING" "No applications configured for monitoring"
            sleep "$CHECK_INTERVAL"
            continue
        fi

        # Monitor each application
        for app_name in "${!APPLICATIONS[@]}"; do
            monitor_application "$app_name" "${APPLICATIONS[$app_name]}"
        done

        # Generate report
        if [[ ${DETAILED_REPORT:-0} -eq 1 ]]; then
            generate_detailed_report
        else
            generate_status_report
        fi

        # Exit if running once
        [[ ${RUN_ONCE:-0} -eq 1 ]] && break

        # Wait for next check
        log_message "INFO" "Sleeping for $CHECK_INTERVAL seconds..."
        sleep "$CHECK_INTERVAL"
    done
}

# Main function
main() {
    # Parse command line arguments
    parse_arguments "$@"

    # Load configuration
    load_config

    # Setup logging
    setup_logging

    # Check dependencies
    check_dependencies

    # Script start
    print_color "$GREEN" "Starting $SCRIPT_NAME v$VERSION"
    log_message "INFO" "=== $SCRIPT_NAME v$VERSION Started ==="
    log_message "INFO" "Configuration: Interval=${CHECK_INTERVAL}s, Timeout=${MAX_REQUEST_TIME}s, Retries=$RETRY_COUNT"

    # Show current configuration
    echo ""
    print_color "$BLUE" "=== Configuration ==="
    echo "Check Interval: ${CHECK_INTERVAL}s"
    echo "Request Timeout: ${MAX_REQUEST_TIME}s"
    echo "Connection Timeout: ${CONNECTION_TIMEOUT}s"
    echo "Retry Count: $RETRY_COUNT"
    echo "Retry Delay: ${RETRY_DELAY}s"
    echo "Email Alerts: $([ $ENABLE_EMAIL_ALERTS -eq 1 ] && echo 'Enabled' || echo 'Disabled')"
    echo "Slack Alerts: $([ $ENABLE_SLACK_ALERTS -eq 1 ] && echo 'Enabled' || echo 'Disabled')"
    echo "Applications to monitor: ${#APPLICATIONS[@]}"
    echo ""

    # Start monitoring
    monitor_loop

    # Script end
    log_message "INFO" "=== $SCRIPT_NAME v$VERSION Completed ==="

    # Return overall status
    local failed_apps=0
    for app_name in "${!APPLICATIONS[@]}"; do
        [[ "${APP_STATUS[$app_name]}" == "DOWN" ]] && failed_apps=$((failed_apps + 1))
    done

    exit $failed_apps
}

#########################################################################
# Script Execution
#########################################################################

# Trap signals for cleanup
trap 'log_message "INFO" "Script interrupted by user"; exit 130' INT TERM

# Check if running as root for certain operations
if [[ $EUID -eq 0 ]]; then
    log_message "INFO" "Running as root user"
else
    log_message "INFO" "Running as non-root user $(whoami)"
fi

# Run main function with all arguments
main "$@"
