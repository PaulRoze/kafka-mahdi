#!/bin/bash

SCRIPT_VERSION="v1.0.0"

# Function to check for script updates
check_for_update() {
    echo "Checking for updates..."
    curl --connect-timeout 10 -s https://raw.githubusercontent.com/PaulRoze/kafka-mahdi/main/kafka-mahdi.sh -o /tmp/latest_kafka_mahdi.sh
    if [ $? -ne 0 ]; then
        read -r -p "Error: Failed to check for updates due to no internet connection. Do you want to proceed? [y/N] " yn
        echo # add a newline for clean output
        case $yn in
            [Yy]* ) return 1;; # Skip update process
            * ) exit 1;;
        esac
    fi
    local latest_version=$(grep '^SCRIPT_VERSION=' /tmp/latest_kafka_mahdi.sh | cut -d '"' -f 2)

    if [[ "$latest_version" > "$SCRIPT_VERSION" ]]; then
        echo "Current script version: $SCRIPT_VERSION"
        echo "New version available: $latest_version"
        read -r -p "Would you like to update to the latest version? [y/N] " yn
        case $yn in
            [Yy]* ) update_script; return 0;;
            * ) return 1;;
        esac
    else
        echo "You are using the latest version of the script [$SCRIPT_VERSION]."
        return 1
    fi
}

# Function to update the script
update_script() {
    local script_name=$(basename "$0")
    local temp_script="/tmp/$script_name"

    echo "Downloading the latest version..."
    curl --connect-timeout 10 -s https://raw.githubusercontent.com/PaulRoze/kafka-mahdi/main/kafka-mahdi.sh -o "$temp_script"
    if [ $? -ne 0 ]; then
        read -r -p "Error: Unable to connect to the internet. Do you want to proceed without updating? [y/N] " yn
        echo # add a newline for clean output
        case $yn in
            [Yy]* ) return 1;; # Skip update process
            * ) exit 1;;
        esac
    fi

    if [ ! -s "$temp_script" ]; then
        read -r -p "Failed to download the update. Proceed without updating? [y/N] " yn
        echo # add a newline for clean output
        case $yn in
            [Yy]* ) return 1;; # Skip update process
            * ) exit 1;;
        esac
    fi

    chmod +x "$temp_script"
    mv "$temp_script" "$0"
    echo "Update completed. Please rerun the script."
    exit 0
}

# Check for updates at the beginning of the script
check_for_update

# Define Kafka brokers and consumer group configuration
SOURCE_BROKERS="source-broker1:9092,source-broker2:9092"
DESTINATION_BROKERS="destination-broker1:9092,destination-broker2:9092"
CONSUMER_GROUPS=("consumer-group-1" "consumer-group-2" "consumer-group-3")
LOG_FILE="kafka-mahdi.log"
CONSUMER_GROUPS_FILE="source_consumer_groups.txt"
TMP_DIR="/tmp/kafka-mahdi"
CONSUMER_GROUPS_PATH="$TMP_DIR/$CONSUMER_GROUPS_FILE"

# Ensure the TMP_DIR exists and adjust permissions appropriately
mkdir -p "$TMP_DIR"
chmod 777 "$TMP_DIR"

# Function to display help message
show_help() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  -h, --help                        Display this help message and exit."
    echo "  -cg, -getConsumerGroup            Extract and list all consumer groups from the specified source brokers,"
    echo "                                    saving the details to a file for reference and further actions."
    echo "  -cgo, -applyConsumerGroupOffset   Synchronize consumer group offsets across clusters, applying"
    echo "                                    predefined offsets to ensure consistency and data integrity"
    echo "                                    across your Kafka ecosystem."
    echo "  -t, -getTopics                    Retrieve and list all topics available within the source Kafka cluster,"
    echo "                                    providing a comprehensive overview of the data landscape."
    echo ""
    echo "Description:"
    echo "  'kafka-mahdi' is a tool designed to navigate the shifting dunes of Kafka clusters, ensuring"
    echo "  that consumer group offsets are synchronized across different realms. This script aids in"
    echo "  maintaining harmony and consistency in message consumption, essential for reliable data"
    echo "  processing and analysis in distributed systems."
    echo ""
    echo "  By wielding the powers of 'kafka-mahdi', administrators and developers can confidently manage"
    echo "  their Kafka ecosystem, ensuring that messages are consumed correctly and data flows"
    echo "  unimpeded across the sands of their digital infrastructure."
    echo ""
    echo "  The script requires access to source and destination Kafka broker addresses and utilizes"
    echo "  Docker to execute Kafka commands, encapsulating complex operations into simple, intuitive commands."
    echo ""
    echo "  Embark on your journey with 'kafka-mahdi' to master the art of Kafka offset synchronization"
    echo "  and unlock the secrets of efficient, consistent data streaming."
}

# Function to log messages to a file
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to apply offsets to consumer groups
apply_offsets() {
    local CONSUMER_GROUP=$1
    log "Processing $CONSUMER_GROUP..."

    # Define a temporary file to store offsets in TMP_DIR
    OFFSETS_FILE="$TMP_DIR/offsets_${CONSUMER_GROUP}.txt"

    # Backup existing offsets file before fetching new offsets
    if [ -f "$OFFSETS_FILE" ]; then
        TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
        BACKUP_FILE="${OFFSETS_FILE%.txt}-backup-pre-fetch-$TIMESTAMP.txt"
        log "Backing up existing offsets file before fetching new offsets to $BACKUP_FILE"
        mv "$OFFSETS_FILE" "$BACKUP_FILE"
    fi

    log "Fetching offsets for $CONSUMER_GROUP from source cluster..."

    # Fetch offsets using kafka-consumer-groups in a Docker container
    docker run --rm -v "$TMP_DIR:/scripts" confluentinc/cp-kafka \
    bash -c "kafka-consumer-groups --bootstrap-server $SOURCE_BROKERS --describe --group $CONSUMER_GROUP > /scripts/$(basename $OFFSETS_FILE)" 2>>"$LOG_FILE"

    if [ -f "$OFFSETS_FILE" ]; then
        while IFS= read -r line; do
            TOPIC=$(echo "$line" | awk '{print $1}')
            PARTITION=$(echo "$line" | awk '{print $2}')
            OFFSET=$(echo "$line" | awk '{print $3}')
            if [[ -n "$TOPIC" && -n "$PARTITION" && -n "$OFFSET" ]]; then
                log "Applying offset $OFFSET for $TOPIC partition $PARTITION to $CONSUMER_GROUP on destination cluster."
                docker run --rm -v "$TMP_DIR:/scripts" confluentinc/cp-kafka \
                bash -c "kafka-consumer-groups --bootstrap-server $DESTINATION_BROKERS --group $CONSUMER_GROUP --topic $TOPIC --reset-offsets --to-offset $OFFSET --execute --partitions $PARTITION" 2>>"$LOG_FILE"
            else
                log "Error processing line: $line"
            fi
        done < "$OFFSETS_FILE"
    else
        log "Failed to fetch offsets for $CONSUMER_GROUP."
    fi
}

get_consumer_groups() {
    log "Extracting consumer groups from source brokers..."

    # Check if the CONSUMER_GROUPS_PATH exists
    if [ -f "$CONSUMER_GROUPS_PATH" ]; then
        # Backup existing file
        TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
        BACKUP_FILE="$TMP_DIR/${CONSUMER_GROUPS_FILE%.txt}-backup-$TIMESTAMP.txt"
        log "Backing up existing file to $BACKUP_FILE"
        mv "$CONSUMER_GROUPS_PATH" "$BACKUP_FILE"
    fi

    log "Starting Docker container to run kafka-consumer-groups..."

    # Run kafka-consumer-groups in Docker, correctly referencing TMP_DIR
    docker run --rm -v "$TMP_DIR:/scripts" confluentinc/cp-kafka \
    bash -c "kafka-consumer-groups --bootstrap-server $SOURCE_BROKERS --list > /scripts/$(basename $CONSUMER_GROUPS_FILE)" 2>>"$LOG_FILE"

    if [ $? -eq 0 ]; then
        log "Consumer groups successfully written to $CONSUMER_GROUPS_PATH"

        # Display the content of the consumer groups file on the screen
        log "Consumer Groups:"
        cat "$CONSUMER_GROUPS_PATH" | while read -r line; do
            log "$line"
        done
    else
        log "Failed to extract consumer groups."
    fi
}

# Function to list all topics from the Kafka cluster
get_topics() {
    log "Listing all topics from the Kafka cluster..."

    # File where the topics list will be stored
    TOPICS_FILE="$TMP_DIR/topics_list.txt"

    # Check if the topics list file already exists and back it up if it does
    if [ -f "$TOPICS_FILE" ]; then
        TIMESTAMP=$(date +"%Y%m%d-%H%M%S")
        BACKUP_FILE="${TOPICS_FILE%.txt}-backup-$TIMESTAMP.txt"
        log "Backing up existing topics list to $BACKUP_FILE"
        mv "$TOPICS_FILE" "$BACKUP_FILE"
    fi

    # Use Docker to run kafka-topics command and list topics, outputting to the topics file
    docker run --rm -v "$TMP_DIR:/scripts" confluentinc/cp-kafka \
    bash -c "kafka-topics --bootstrap-server $SOURCE_BROKERS --list > /scripts/$(basename $TOPICS_FILE)"

    if [ $? -eq 0 ]; then
        log "Topics successfully listed and written to $TOPICS_FILE"

        # Display the content of the topics file on the screen
        log "Topics:"
        cat "$TOPICS_FILE" | while read -r line; do
            log "$line"
        done
    else
        log "Failed to list topics."
    fi
}

# Main script logic
case "$1" in
    -h|--help)
        show_help
        ;;
    -cg|-getConsumerGroup)
        get_consumer_groups
        ;;
    -cgo|-applyConsumerGroupOffset)
        for CGO in "${CONSUMER_GROUPS[@]}"; do
            apply_offsets "$CGO"
        done
        ;;
    -t|-getTopics)
        get_topics
        ;;
    *)
        echo "Unknown option: $1"
        show_help
        ;;
esac
