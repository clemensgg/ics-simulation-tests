#!/bin/bash

# node logs piped to /var/log/icstest.log

set -e

PROVIDER_FLAGS="--chain-id provider-chain --gas 1000000 --gas-prices 0.25icsstake --keyring-backend test"

# Load environment variables from .env file
function loadEnv {
  if test -f .env ; then 
    ENV=$(realpath .env)
    export $(grep "^[^#;]" $ENV | xargs)
    echo "loaded configuration from ENV file: $ENV"
  else
    echo "ENV file not found at .env"
    exit 1
  fi
}

# Determine desktop environment
function get_terminal_command() {
  local desktop_env
  desktop_env="$(echo $XDG_CURRENT_DESKTOP | tr '[:upper:]' '[:lower:]')"

  case $desktop_env in
    *gnome*)
      echo "gnome-terminal --"
      ;;
    *)
      echo "xterm -e"
      ;;
  esac
}

# Start provider chain and wait for it to produce blocks
function startAndWaitForProviderChain() {
  echo "Starting vagrant VMs, waiting for PC to produce blocks..."
  vagrant up

  # Wait for the provider to finalize a block
  echo "Waiting for Provider Chain to finalize a block..."
  PROVIDER_LATEST_HEIGHT=""
  while [[ ! $PROVIDER_LATEST_HEIGHT =~ ^[0-9]+$ ]] || [[ $PROVIDER_LATEST_HEIGHT -lt 1 ]]; do
    PROVIDER_LATEST_HEIGHT=$(ssh "provider-chain-validator1" 'curl -s http://localhost:26657/status | jq -r ".result.sync_info.latest_block_height"')
    sleep 2
  done
  echo ">> PROVIDER CHAIN successfully launched. Latest block height: $PROVIDER_LATEST_HEIGHT"
}

# Propose consumer addition proposal from provider validator 1
function proposeConsumerAdditionProposal() {
  
  # Prepare proposal file
  echo "Preparing consumer addition proposal..."

  CONSUMER_BINARY_SHA256=$(ssh "consumer-chain-validator1" "sha256sum $(which $CONSUMER_APP)" | awk '{ print $1 }')
  CONSUMER_RAW_GENESIS_SHA256=$(ssh "consumer-chain-validator1" "sha256sum $DAEMON_HOME/genesis/raw_genesis.json" | awk '{ print $1 }')
  SPAWN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ" --date="@$(($(date +%s) + 120))")
  cat > prop.json <<EOT
{
  "title": "Create the Consumer chain",
  "description": "This is the proposal to create the consumer chain \"consumer-chain\".",
  "chain_id": "consumer-chain",
  "initial_height": {
      "revision_height": 1,
  },
  "genesis_hash": "$CONSUMER_BINARY_SHA256",
  "binary_hash": "$CONSUMER_RAW_GENESIS_SHA256",
  "spawn_time": "$SPAWN_TIME",
  "deposit": "1icsstake"
} 
EOT
  scp prop.json provider-chain-validator1:/home/root/prop.json

  # Create and submit the consumer addition proposal
  echo "Submitting consumer addition proposal from provider validator 1..."
  RES=$(ssh "provider-chain-validator1" "$PROVIDER_APP --home $PROVIDER_HOME tx gov submit-proposal consumer-addition /home/root/prop.json --from provider-chain-validator1 $PROVIDER_FLAGS")
  if [ -z "$RES" ]; then
    echo "Error submitting consumer addition proposal"
    exit 1
  fi
  echo "Consumer addition proposal submitted successfully"
}

# Vote yes on the consumer addition proposal from all provider validators
function voteConsumerAdditionProposal() {
  echo "Voting on consumer addition proposal..."

  for i in {1..3} ; do 
    echo "Voting 'yes' from provider-chain-validator${i}..."
    RES=$(ssh "provider-chain-validator${i}" "$PROVIDER_APP --home $PROVIDER_HOME tx gov vote 1 yes --from provider-chain-validator${i} $PROVIDER_FLAGS")
    if [ -z "$RES" ]; then
      echo "Error voting on consumer addition proposal"
      exit 1
    fi
    echo "Voted 'yes' from provider-chain-validator${i} successfully"
  done
}

# Prepare consumer chain: copy private validator keys and finalizing genesis
function prepareConsumerChain() {
  echo "Preparing consumer chain..."

  for i in {1..3} ; do 
    echo "Copying private validator keys from provider-chain-validator${i} to consumer-chain-validator${i}..."
    scp "provider-chain-validator${i}:$PROVIDER_HOME/config/priv_validator_key.json" "priv_validator_key${i}.json"
    scp "priv_validator_key${i}.json" "consumer-chain-validator${i}:$CONSUMER_HOME/config/priv_validator_key.json" 
    rm "priv_validator_key${i}.json" 
  done

  echo "Waiting for consumer addition proposal to pass on provider-chain..."
  PROPOSAL_STATUS=""
  while [[ $PROPOSAL_STATUS != "PROPOSAL_STATUS_PASSED" ]]; do
    PROPOSAL_STATUS=$(ssh "provider-chain-validator1" "$PROVIDER_APP --home $PROVIDER_HOME q gov proposal 1 -o json | jq -r '.status'")
    sleep 2
  done
  echo "Consumer addition proposal passed"

  echo "Querying CCV consumer state and finalizing consumer chain genesis on each consumer validator..."
  CONSUMER_CCV_STATE=$(ssh "provider-chain-validator1" "$PROVIDER_APP query provider consumer-genesis consumer-chain -o json")
  echo "$CONSUMER_CCV_STATE" | jq . > "ccv.json"
  for i in {1..3} ; do 
    scp "ccv.json" "consumer-chain-validator${i}:/home/root/ccv.json"
    ssh "consumer-chain-validator${i}" "jq -s '.[0].app_state.ccvconsumer = .[1] | .[0]' $CONSUMER_HOME/config/raw_genesis.json /home/root/ccv.json > $CONSUMER_HOME/config/genesis.json"
  done
  rm "ccv.json"
}

function startConsumerChain() {
  if [ "$CHAIN_ID" == "consumer-chain" ]; then
    $(get_terminal_command) "ssh \"${CHAIN_ID}-validator${NODE_INDEX}\" \"tail -f /var/log/icstest.log\"" &
$DAEMON_NAME --home $DAEMON_HOME start &> /var/log/icstest.log &
  fi
}

function assignKeyPreLaunch() {
  echo "Assigning keys pre-launch..."
  
  # TODO
}

function assignKeyPostLaunch() {
  echo "Assigning keys post-launch..."
  
  # TODO
}

function main() {
  loadEnv
  startAndWaitForProviderChain
  proposeConsumerAdditionProposal
  voteConsumerAdditionProposal
  prepareConsumerChain
  startConsumerChain
  # assignKeyPreLaunch
  # assignKeyPostLaunch
}

main
echo "All tests passed!"