#!/bin/bash

set -eu
set -o pipefail # If anything in a pipeline fails, the pipe's exit status is a failure
#set -x # Print all commands for debugging

declare -a KEY=(a b c d)

declare -A FROM=(
    [a]='-y --from a'
    [b]='-y --from b'
    [c]='-y --from c'
    [d]='-y --from d'
)

# This means we don't need to configure the cli since it uses the preconfigured cli in the docker.
# We define this as a function rather than as an alias because it has more flexible expansion behavior.
# In particular, it's not possible to dynamically expand aliases, but `tx_of` dynamically executes whatever
# we specify in its arguments.
function secretcli() {
    docker exec secretdev /usr/bin/secretcli "$@"
}

# Just like `echo`, but prints to stderr
function log() {
    echo "$@" >&2
}

# suppress all output to stdout and stderr for the command described in the arguments
function silent() {
    "$@" >/dev/null 2>&1
}

# Pad the string in the first argument to 256 bytes, using spaces
function pad_space() {
    printf '%-256s' "$1"
}

function assert_eq() {
    local left="$1"
    local right="$2"
    local message

    if [[ "$left" != "$right" ]]; then
        if [ -z ${3+x} ]; then
            local lineno="${BASH_LINENO[0]}"
            message="assertion failed on line $lineno - both sides differ. left: ${left@Q}, right: ${right@Q}"
        else
            message="$3"
        fi
        log "$message"
        return 1
    fi

    return 0
}

function assert_ne() {
    local left="$1"
    local right="$2"
    local message

    if [[ "$left" == "$right" ]]; then
        if [ -z ${3+x} ]; then
            local lineno="${BASH_LINENO[0]}"
            message="assertion failed on line $lineno - both sides are equal. left: ${left@Q}, right: ${right@Q}"
        else
            message="$3"
        fi

        log "$message"
        return 1
    fi

    return 0
}

declare -A ADDRESS=(
    [a]="$(secretcli keys show --address a)"
    [b]="$(secretcli keys show --address b)"
    [c]="$(secretcli keys show --address c)"
    [d]="$(secretcli keys show --address d)"
)

declare -A VK=([a]='' [b]='' [c]='' [d]='')

# Generate a label for a contract with a given code id
# This just adds "contract_" before the code id.
function label_by_id() {
    local id="$1"
    echo "contract_$id"
}

# Keep polling the blockchain until the tx completes.
# The first argument is the tx hash.
# The second argument is a message that will be logged after every failed attempt.
# The tx information will be returned.
function wait_for_tx() {
    local tx_hash="$1"
    local message="$2"

    local result

    log "waiting on tx: $tx_hash"
    # secretcli will only print to stdout when it succeeds
    until result="$(secretcli query tx "$tx_hash" 2>/dev/null)"; do
        log "$message"
        sleep 1
    done

    # log out-of-gas events
    if jq -e '.raw_log | startswith("execute contract failed: Out of gas: ")' <<<"$result" >/dev/null; then
        log "$(jq -r '.raw_log' <<<"$result")"
    fi

    echo "$result"
}

# This is a wrapper around `wait_for_tx` that also decrypts the response,
# and returns a nonzero status code if the tx failed
function wait_for_compute_tx() {
    local tx_hash="$1"
    local message="$2"
    local return_value=0
    local result
    local decrypted

    result="$(wait_for_tx "$tx_hash" "$message")"
    # log "$result"
    if jq -e '.logs == null' <<<"$result" >/dev/null; then
        return_value=1
    fi
    decrypted="$(secretcli query compute tx "$tx_hash")"
    log "$decrypted"
    echo "$decrypted"

    return "$return_value"
}

# If the tx failed, return a nonzero status code.
# The decrypted error or message will be echoed
function check_tx() {
    local tx_hash="$1"
    local result
    local return_value=0

    result="$(secretcli query tx "$tx_hash")"
    if jq -e '.logs == null' <<<"$result" >/dev/null; then
        return_value=1
    fi
    decrypted="$(secretcli query compute tx "$tx_hash")"
    log "$decrypted"
    echo "$decrypted"

    return "$return_value"
}

# Extract the tx_hash from the output of the command
function tx_of() {
    "$@" | jq -r '.txhash'
}

# Extract the output_data_as_string from the output of the command
function data_of() {
    "$@" | jq -r '.output_data_as_string'
}

function get_generic_err() {
    jq -r '.output_error.generic_err.msg' <<<"$1"
}

# Send a compute transaction and return the tx hash.
# All arguments to this function are passed directly to `secretcli tx compute execute`.
function compute_execute() {
    tx_of secretcli tx compute execute "$@"
}

# Send a query to the contract.
# All arguments to this function are passed directly to `secretcli query compute query`.
function compute_query() {
    secretcli query compute query "$@"
}

function upload_code() {
    local directory="$1"
    local tx_hash
    local code_id

    tx_hash="$(tx_of secretcli tx compute store "code/$directory/contract.wasm.gz" ${FROM[a]} --gas 10000000)"
    code_id="$(
        wait_for_tx "$tx_hash" 'waiting for contract upload' |
            jq -r '.logs[0].events[0].attributes[] | select(.key == "code_id") | .value'
    )"

    log "uploaded contract #$code_id"

    echo "$code_id"
}

function instantiate() {
    local code_id="$1"
    local init_msg="$2"

    log 'sending init message:'
    log "${init_msg@Q}"

    local tx_hash
    tx_hash="$(tx_of secretcli tx compute instantiate "$code_id" "$init_msg" --label "$(label_by_id "$code_id")" ${FROM[a]} --gas 10000000)"
    wait_for_tx "$tx_hash" 'waiting for init to complete'
}

# This function uploads and instantiates a contract, and returns the new contract's address
function create_contract() {
    local dir="$1"
    local init_msg="$2"

    local code_id
    code_id="$(upload_code "$dir")"

    local init_result
    init_result="$(instantiate "$code_id" "$init_msg")"

    if jq -e '.logs == null' <<<"$init_result" >/dev/null; then
        log "$(secretcli query compute tx "$(jq -r '.txhash' <<<"$init_result")")"
        return 1
    fi

    jq -r '.logs[0].events[0].attributes[] | select(.key == "contract_address") | .value' <<<"$init_result"
}

function deposit() {
    local contract_addr="$1"
    local key="$2"
    local amount="$3"

    local deposit_message='{"deposit":{"padding":":::::::::::::::::"}}'
    local tx_hash
    local deposit_response
    tx_hash="$(compute_execute "$contract_addr" "$deposit_message" --amount "${amount}uscrt" ${FROM[$key]} --gas 150000)"
    deposit_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for deposit to \"$key\" to process")"
    assert_eq "$deposit_response" "$(pad_space '{"deposit":{"status":"success"}}')"
    log "deposited ${amount}uscrt to \"$key\" successfully"
}

function get_balance() {
    local contract_addr="$1"
    local key="$2"

    log "querying balance for \"$key\""
    local balance_query='{"balance":{"address":"'"${ADDRESS[$key]}"'","key":"'"${VK[$key]}"'"}}'
    local balance_response
    balance_response="$(compute_query "$contract_addr" "$balance_query")"
    log "balance response was: $balance_response"
    jq -r '.balance.amount' <<<"$balance_response"
}

# Redeem some SCRT from an account
# As you can see, verifying this is happening correctly requires a lot of code
# so I separated it to its own function, because it's used several times.
function redeem() {
    local contract_addr="$1"
    local key="$2"
    local amount="$3"

    local redeem_message
    local tx_hash
    local redeem_tx
    local transfer_attributes
    local redeem_response

    log "redeeming \"$key\""
    redeem_message='{"redeem":{"amount":"'"$amount"'"}}'
    tx_hash="$(compute_execute "$contract_addr" "$redeem_message" ${FROM[$key]} --gas 150000)"
    redeem_tx="$(wait_for_tx "$tx_hash" "waiting for redeem from \"$key\" to process")"
    transfer_attributes="$(jq -r '.logs[0].events[] | select(.type == "transfer") | .attributes' <<<"$redeem_tx")"
    assert_eq "$(jq -r '.[] | select(.key == "recipient") | .value' <<<"$transfer_attributes")" "${ADDRESS[$key]}"
    assert_eq "$(jq -r '.[] | select(.key == "amount") | .value' <<<"$transfer_attributes")" "${amount}uscrt"
    log "redeem response for \"$key\" returned ${amount}uscrt"

    redeem_response="$(data_of check_tx "$tx_hash")"
    assert_eq "$redeem_response" "$(pad_space '{"redeem":{"status":"success"}}')"
    log "redeemed ${amount} from \"$key\" successfully"
}

function log_test_header() {
    log " # Starting ${FUNCNAME[1]}"
}

function test_viewing_key() {
    local contract_addr="$1"

    log_test_header

    # common variables
    local result
    local tx_hash

    # query balance. Should fail.
    local wrong_key
    wrong_key="$(xxd -ps <<<'wrong-key')"
    local balance_query
    local expected_error='{"viewing_key_error":{"msg":"Wrong viewing key for this address or viewing key not set"}}'
    for key in "${KEY[@]}"; do
        log "querying balance for \"$key\" with wrong viewing key"
        balance_query='{"balance":{"address":"'"${ADDRESS[$key]}"'","key":"'"$wrong_key"'"}}'
        result="$(compute_query "$contract_addr" "$balance_query")"
        assert_eq "$result" "$expected_error"
    done

    # Create viewing keys
    local create_viewing_key_message='{"create_viewing_key":{"entropy":"MyPassword123"}}'
    local viewing_key_response
    for key in "${KEY[@]}"; do
        log "creating viewing key for \"$key\""
        tx_hash="$(compute_execute "$contract_addr" "$create_viewing_key_message" ${FROM[$key]} --gas 1400000)"
        viewing_key_response="$(data_of wait_for_compute_tx "$tx_hash" "waiting for viewing key for \"$key\" to be created")"
        VK[$key]="$(jq -er '.create_viewing_key.key' <<<"$viewing_key_response")"
        log "viewing key for \"$key\" set to ${VK[$key]}"
        if [[ "${VK[$key]}" =~ ^api_key_ ]]; then
            log "viewing key \"$key\" seems valid"
        else
            log 'viewing key is invalid'
            return 1
        fi
    done

    # Check that all viewing keys are different despite using the same entropy
    assert_ne "${VK[a]}" "${VK[b]}"
    assert_ne "${VK[b]}" "${VK[c]}"
    assert_ne "${VK[c]}" "${VK[d]}"

    # query balance. Should succeed.
    local balance_query
    for key in "${KEY[@]}"; do
        balance_query='{"balance":{"address":"'"${ADDRESS[$key]}"'","key":"'"${VK[$key]}"'"}}'
        log "querying balance for \"$key\" with correct viewing key"
        result="$(compute_query "$contract_addr" "$balance_query")"
        if ! silent jq -e '.balance.amount | tonumber' <<<"$result"; then
            log "Balance query returned unexpected response: ${result@Q}"
            return 1
        fi
    done

    # Change viewing keys
    local vk2_a

    log 'creating new viewing key for "a"'
    tx_hash="$(compute_execute "$contract_addr" "$create_viewing_key_message" ${FROM[a]} --gas 1400000)"
    viewing_key_response="$(data_of wait_for_compute_tx "$tx_hash" 'waiting for viewing key for "a" to be created')"
    vk2_a="$(jq -er '.create_viewing_key.key' <<<"$viewing_key_response")"
    log "viewing key for \"a\" set to $vk2_a"
    assert_ne "${VK[a]}" "$vk2_a"

    # query balance with old keys. Should fail.
    log 'querying balance for "a" with old viewing key'
    local balance_query_a='{"balance":{"address":"'"${ADDRESS[a]}"'","key":"'"${VK[a]}"'"}}'
    result="$(compute_query "$contract_addr" "$balance_query_a")"
    assert_eq "$result" "$expected_error"

    # query balance with new keys. Should succeed.
    log 'querying balance for "a" with new viewing key'
    balance_query_a='{"balance":{"address":"'"${ADDRESS[a]}"'","key":"'"$vk2_a"'"}}'
    result="$(compute_query "$contract_addr" "$balance_query_a")"
    if ! silent jq -e '.balance.amount | tonumber' <<<"$result"; then
        log "Balance query returned unexpected response: ${result@Q}"
        return 1
    fi

    # Set the vk for "a" to the original vk
    log 'setting the viewing key for "a" back to the first one'
    local set_viewing_key_message='{"set_viewing_key":{"key":"'"${VK[a]}"'"}}'
    tx_hash="$(compute_execute "$contract_addr" "$set_viewing_key_message" ${FROM[a]} --gas 1400000)"
    viewing_key_response="$(data_of wait_for_compute_tx "$tx_hash" 'waiting for viewing key for "a" to be set')"
    assert_eq "$viewing_key_response" "$(pad_space '{"set_viewing_key":{"status":"success"}}')"

    # try to use the new key - should fail
    log 'querying balance for "a" with new viewing key'
    balance_query_a='{"balance":{"address":"'"${ADDRESS[a]}"'","key":"'"$vk2_a"'"}}'
    result="$(compute_query "$contract_addr" "$balance_query_a")"
    assert_eq "$result" "$expected_error"

    # try to use the old key - should succeed
    log 'querying balance for "a" with old viewing key'
    balance_query_a='{"balance":{"address":"'"${ADDRESS[a]}"'","key":"'"${VK[a]}"'"}}'
    result="$(compute_query "$contract_addr" "$balance_query_a")"
    if ! silent jq -e '.balance.amount | tonumber' <<<"$result"; then
        log "Balance query returned unexpected response: ${result@Q}"
        return 1
    fi
}

function test_deposit() {
    local contract_addr="$1"

    log_test_header

    local tx_hash

    local -A deposits=([a]=1000000 [b]=2000000 [c]=3000000 [d]=4000000)
    for key in "${KEY[@]}"; do
        deposit "$contract_addr" "$key" "${deposits[$key]}"
    done

    # Query the balances of the accounts and make sure they have the right balances.
    for key in "${KEY[@]}"; do
        assert_eq "$(get_balance "$contract_addr" "$key")" "${deposits[$key]}"
    done

    # Try to overdraft
    local redeem_message
    local overdraft
    local redeem_response
    for key in "${KEY[@]}"; do
        overdraft="$((deposits[$key] + 1))"
        redeem_message='{"redeem":{"amount":"'"$overdraft"'"}}'
        tx_hash="$(compute_execute "$contract_addr" "$redeem_message" ${FROM[$key]} --gas 150000)"
        # Notice the `!` before the command - it is EXPECTED to fail.
        ! redeem_response="$(wait_for_compute_tx "$tx_hash" "waiting for overdraft from \"$key\" to process")"
        log "trying to overdraft from \"$key\" was rejected"
        assert_eq \
            "$(get_generic_err "$redeem_response")" \
            "insufficient funds to redeem: balance=${deposits[$key]}, required=$overdraft"
    done

    # Withdraw Everything
    for key in "${KEY[@]}"; do
        redeem "$contract_addr" "$key" "${deposits[$key]}"
    done

    # Check the balances again. They should all be empty
    for key in "${KEY[@]}"; do
        assert_eq "$(get_balance "$contract_addr" "$key")" 0
    done
}

function test_transfer() {
    local contract_addr="$1"

    log_test_header

    local tx_hash

    # Check "a" and "b" don't have any funds
    assert_eq "$(get_balance "$contract_addr" 'a')" 0
    assert_eq "$(get_balance "$contract_addr" 'b')" 0

    # Deposit to "a"
    deposit "$contract_addr" 'a' 1000000

    # Try to transfer more than "a" has
    log 'transferring funds from "a" to "b", but more than "a" has'
    local transfer_message='{"transfer":{"recipient":"'"${ADDRESS[b]}"'","amount":"1000001"}}'
    local transfer_response
    tx_hash="$(compute_execute "$contract_addr" "$transfer_message" ${FROM[a]} --gas 150000)"
    # Notice the `!` before the command - it is EXPECTED to fail.
    ! transfer_response="$(wait_for_compute_tx "$tx_hash" 'waiting for transfer from "a" to "b" to process')"
    log "trying to overdraft from \"a\" to transfer to \"b\" was rejected"
    assert_eq "$(get_generic_err "$transfer_response")" "insufficient funds: balance=1000000, required=1000001"

    # Check both a and b, that their last transaction is not for 1000001 uscrt
    local transfer_history_query
    local transfer_history_response
    local txs
    for key in a b; do
        log "querying the transfer history of \"$key\""
        transfer_history_query='{"transfer_history":{"address":"'"${ADDRESS[$key]}"'","key":"'"${VK[$key]}"'","page_size":1}}'
        transfer_history_response="$(compute_query "$contract_addr" "$transfer_history_query")"
        txs="$(jq -r '.transfer_history.txs' <<<"$transfer_history_response")"
        silent jq -e 'length <= 1' <<<"$txs" # just make sure we're not getting a weird response
        if silent jq -e 'length == 1' <<<"$txs"; then
            assert_ne "$(jq -r '.[0].coins.amount' <<<"$txs")" 1000001
        fi
    done

    # Transfer from "a" to "b"
    log 'transferring funds from "a" to "b"'
    local transfer_message='{"transfer":{"recipient":"'"${ADDRESS[b]}"'","amount":"400000"}}'
    local transfer_response
    tx_hash="$(compute_execute "$contract_addr" "$transfer_message" ${FROM[a]} --gas 160000)"
    transfer_response="$(data_of wait_for_compute_tx "$tx_hash" 'waiting for transfer from "a" to "b" to process')"
    assert_eq "$transfer_response" "$(pad_space '{"transfer":{"status":"success"}}')"

    # Check for both "a" and "b" that they recorded the transfer
    local tx
    local -A tx_ids
    for key in a b; do
        log "querying the transfer history of \"$key\""
        transfer_history_query='{"transfer_history":{"address":"'"${ADDRESS[$key]}"'","key":"'"${VK[$key]}"'","page_size":1}}'
        transfer_history_response="$(compute_query "$contract_addr" "$transfer_history_query")"
        txs="$(jq -r '.transfer_history.txs' <<<"$transfer_history_response")"
        silent jq -e 'length == 1' <<<"$txs" # just make sure we're not getting a weird response
        tx="$(jq -r '.[0]' <<<"$txs")"
        assert_eq "$(jq -r '.from' <<<"$tx")" "${ADDRESS[a]}"
        assert_eq "$(jq -r '.sender' <<<"$tx")" "${ADDRESS[a]}"
        assert_eq "$(jq -r '.receiver' <<<"$tx")" "${ADDRESS[b]}"
        assert_eq "$(jq -r '.coins.amount' <<<"$tx")" 400000
        assert_eq "$(jq -r '.coins.denom' <<<"$tx")" 'SSCRT'
        tx_ids[$key]="$(jq -r '.id' <<<"$tx")"
    done

    assert_eq "${tx_ids[a]}" "${tx_ids[b]}"
    log 'The transfer was recorded correctly in the transaction history'

    # Check that "a" has fewer funds
    assert_eq "$(get_balance "$contract_addr" 'a')" 600000

    # Check that "b" has the funds that "a" deposited
    assert_eq "$(get_balance "$contract_addr" 'b')" 400000

    # Redeem both accounts
    redeem "$contract_addr" a 600000
    redeem "$contract_addr" b 400000
    # Send the funds back
    secretcli tx send b "${ADDRESS[a]}" 400000uscrt -y -b block >/dev/null
}

function create_receiver_contract() {
    local init_msg
    local contract_addr

    init_msg='{"count":0}'
    contract_addr="$(create_contract 'tests/example-receiver' "$init_msg")"

    log "uploaded receiver contract to $contract_addr"
    echo "$contract_addr"
}

# This function exists so that we can reset the state as much as possible between different tests
function redeem_receiver() {
    local receiver_addr="$1"
    local snip20_addr="$2"
    local to_addr="$3"
    local amount="$4"

    local tx_hash
    local redeem_tx
    local transfer_attributes

    log 'fetching snip20 hash'
    local snip20_hash
    snip20_hash="$(secretcli query compute contract-hash "$snip20_addr")"

    local redeem_message='{"redeem":{"addr":"'"$snip20_addr"'","hash":"'"${snip20_hash:2}"'","to":"'"$to_addr"'","amount":"'"$amount"'"}}'
    tx_hash="$(compute_execute "$receiver_addr" "$redeem_message" ${FROM[a]} --gas 300000)"
    redeem_tx="$(wait_for_tx "$tx_hash" "waiting for redeem from receiver at \"$receiver_addr\" to process")"
    # log "$redeem_tx"
    transfer_attributes="$(jq -r '.logs[0].events[] | select(.type == "transfer") | .attributes' <<<"$redeem_tx")"
    assert_eq "$(jq -r '.[] | select(.key == "recipient") | .value' <<<"$transfer_attributes")" "$receiver_addr"$'\n'"$to_addr"
    assert_eq "$(jq -r '.[] | select(.key == "amount") | .value' <<<"$transfer_attributes")" "${amount}uscrt"$'\n'"${amount}uscrt"
    log "redeem response for \"$receiver_addr\" returned ${amount}uscrt"
}

function register_receiver() {
    local receiver_addr="$1"
    local snip20_addr="$2"

    local tx_hash

    log 'fetching snip20 hash'
    local snip20_hash
    snip20_hash="$(secretcli query compute contract-hash "$snip20_addr")"

    log 'registering with snip20'
    local register_message='{"register":{"reg_addr":"'"$snip20_addr"'","reg_hash":"'"${snip20_hash:2}"'"}}'
    tx_hash="$(compute_execute "$receiver_addr" "$register_message" ${FROM[a]} --gas 200000)"
    # we throw away the output since we know it's empty
    local register_tx
    register_tx="$(wait_for_compute_tx "$tx_hash" 'Waiting for receiver registration')"
    assert_eq \
        "$(jq -r '.output_log[] | select(.type == "wasm") | .attributes[] | select(.key == "register_status") | .value' <<<"$register_tx")" \
        'success'
    log 'receiver registered successfully'
}

function test_send() {
    local contract_addr="$1"

    log_test_header

    local receiver_addr
    receiver_addr="$(create_receiver_contract)"
#    receiver_addr='secret17k8qt6aqd7eee3fawmtvy4vu6teqx8d7mdm49x'
    register_receiver "$receiver_addr" "$contract_addr"

    local tx_hash

    # Check "a" and "b" don't have any funds
    assert_eq "$(get_balance "$contract_addr" 'a')" 0
    assert_eq "$(get_balance "$contract_addr" 'b')" 0

    # Deposit to "a"
    deposit "$contract_addr" 'a' 1000000

    # Try to send more than "a" has
    log 'sending funds from "a" to "b", but more than "a" has'
    local send_message='{"send":{"recipient":"'"${ADDRESS[b]}"'","amount":"1000001"}}'
    local send_response
    tx_hash="$(compute_execute "$contract_addr" "$send_message" ${FROM[a]} --gas 150000)"
    # Notice the `!` before the command - it is EXPECTED to fail.
    ! send_response="$(wait_for_compute_tx "$tx_hash" 'waiting for send from "a" to "b" to process')"
    log "trying to overdraft from \"a\" to send to \"b\" was rejected"
    assert_eq "$(get_generic_err "$send_response")" "insufficient funds: balance=1000000, required=1000001"

    # Check both a and b, that their last transaction is not for 1000001 uscrt
    local transfer_history_query
    local transfer_history_response
    local txs
    for key in a b; do
        log "querying the transfer history of \"$key\""
        transfer_history_query='{"transfer_history":{"address":"'"${ADDRESS[$key]}"'","key":"'"${VK[$key]}"'","page_size":1}}'
        transfer_history_response="$(compute_query "$contract_addr" "$transfer_history_query")"
        txs="$(jq -r '.transfer_history.txs' <<<"$transfer_history_response")"
        silent jq -e 'length <= 1' <<<"$txs" # just make sure we're not getting a weird response
        if silent jq -e 'length == 1' <<<"$txs"; then
            assert_ne "$(jq -r '.[0].coins.amount' <<<"$txs")" 1000001
        fi
    done

    # Query receiver state before Send
    local receiver_state
    local receiver_state_query='{"get_count":{}}'
    receiver_state="$(compute_query "$receiver_addr" "$receiver_state_query")"
    local original_count
    original_count="$(jq -r '.count' <<<"$receiver_state")"

    # Send from "a" to the receiver with message to the Receiver
    log 'sending funds from "a" to "b", with message to the Receiver'
    local receiver_msg='{"increment":{}}'
    receiver_msg="$(base64 <<<"$receiver_msg")"
    local send_message='{"send":{"recipient":"'"$receiver_addr"'","amount":"400000","msg":"'$receiver_msg'"}}'
    local send_response
    tx_hash="$(compute_execute "$contract_addr" "$send_message" ${FROM[a]} --gas 300000)"
    send_response="$(wait_for_compute_tx "$tx_hash" 'waiting for send from "a" to "b" to process')"
    assert_eq \
        "$(jq -r '.output_log[0].attributes[] | select(.key == "count") | .value' <<<"$send_response")" \
        "$((original_count + 1))"
    log 'received send response'

    # Check that the receiver got the message
    log 'checking whether state was updated in the receiver'
    receiver_state_query='{"get_count":{}}'
    receiver_state="$(compute_query "$receiver_addr" "$receiver_state_query")"
    local new_count
    new_count="$(jq -r '.count' <<<"$receiver_state")"
    assert_eq "$((original_count + 1))" "$new_count"
    log 'receiver contract received the message'

    # Check that "a" recorded the transfer
    local tx
    log 'querying the transfer history of "a"'
    transfer_history_query='{"transfer_history":{"address":"'"${ADDRESS[a]}"'","key":"'"${VK[a]}"'","page_size":1}}'
    transfer_history_response="$(compute_query "$contract_addr" "$transfer_history_query")"
    txs="$(jq -r '.transfer_history.txs' <<<"$transfer_history_response")"
    silent jq -e 'length == 1' <<<"$txs" # just make sure we're not getting a weird response
    tx="$(jq -r '.[0]' <<<"$txs")"
    assert_eq "$(jq -r '.from' <<<"$tx")" "${ADDRESS[a]}"
    assert_eq "$(jq -r '.sender' <<<"$tx")" "${ADDRESS[a]}"
    assert_eq "$(jq -r '.receiver' <<<"$tx")" "$receiver_addr"
    assert_eq "$(jq -r '.coins.amount' <<<"$tx")" 400000
    assert_eq "$(jq -r '.coins.denom' <<<"$tx")" 'SSCRT'

    # Check that "a" has fewer funds
    assert_eq "$(get_balance "$contract_addr" 'a')" 600000

    # Test that send callback failure also denies the transfer
    log 'sending funds from "a" to "b", with a "Fail" message to the Receiver'
    receiver_msg='{"fail":{}}'
    receiver_msg="$(base64 <<<"$receiver_msg")"
    send_message='{"send":{"recipient":"'"$receiver_addr"'","amount":"400000","msg":"'$receiver_msg'"}}'
    tx_hash="$(compute_execute "$contract_addr" "$send_message" ${FROM[a]} --gas 300000)"
    # Notice the `!` before the command - it is EXPECTED to fail.
    ! send_response="$(wait_for_compute_tx "$tx_hash" 'waiting for send from "a" to "b" to process')"
    assert_eq "$(get_generic_err "$send_response")" 'intentional failure' # This comes from the receiver contract

    # Check that "a" does not have fewer funds
    assert_eq "$(get_balance "$contract_addr" 'a')" 600000 # This is the same balance as before

    log 'a failure in the callback caused the transfer to roll back, as expected'

    # redeem both accounts
    redeem "$contract_addr" 'a' 600000
    redeem_receiver "$receiver_addr" "$contract_addr" "${ADDRESS[a]}" 400000
}

function main() {
    log '              <####> Starting integration tests <####>'
    log "secretcli version in the docker image is: $(secretcli version)"

    local prng_seed
    prng_seed="$(base64 <<<'enigma-rocks')"
    local init_msg
    init_msg='{"name":"secret-secret","admin":"'"${ADDRESS[a]}"'","symbol":"SSCRT","decimals":6,"initial_balances":[],"prng_seed":"'"$prng_seed"'","config":{}}'
    contract_addr="$(create_contract '.' "$init_msg")"

    # To make testing faster, check the logs and try to reuse the deployed contract and VKs from previous runs.
    # Remember to comment out the contract deployment and `test_viewing_key` if you do.
#    local contract_addr='secret1rgsafmz6jmq9ezq04v9gagu9sm08f4ht66lyfy'
#    VK[a]='api_key_UsLPYFXMml9Q9K01xdUY/zN7qLypLy96bWOQxe3dQp0='
#    VK[b]='api_key_w1D2hV0A3T9TssjQGWBCVh0+N/RgaBHsBx6fJxNIjss='
#    VK[c]='api_key_EzJg6mK6gXDXRlx6hsbUgfzhJytbaLvklvKKgw4GZ48='
#    VK[d]='api_key_IFGz4nFMTKc203uKaVaYrumPQEAtF2VdqC9lJllRDac='

    log "contract address: $contract_addr"

    # This first test also sets the `VK[*]` global variables that are used in the other tests
    test_viewing_key "$contract_addr"
    test_deposit "$contract_addr"
    test_transfer "$contract_addr"
    test_send "$contract_addr"

    log 'Tests completed successfully'

    # If everything else worked, return successful status
    return 0
}

main "$@"