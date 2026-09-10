# Get blockchain info using bitcoin-cli
blockchain_info=$(bitcoin-cli getblockchaininfo)

# Print the blockchain info
echo "$blockchain_info"

# Create two wallets called Miner and Alice

ensure_wallet() {
    wallet="$1"

    if bitcoin-cli listwallets | jq -e --arg w "$wallet" '. | index($w)' > /dev/null 2>&1; then
        echo "$wallet wallet is already loaded."
    elif bitcoin-cli listwalletdir | jq -e --arg w "$wallet" '.wallets[] | select(.name == $w)' > /dev/null 2>&1; then
        bitcoin-cli loadwallet "$wallet" > /dev/null
        echo "$wallet wallet loaded."
    else
        bitcoin-cli createwallet "$wallet" > /dev/null
        echo "$wallet wallet created."
    fi
}

ensure_wallet "Miner"
ensure_wallet "Alice"

MINER="bitcoin-cli -rpcwallet=Miner"
ALICE="bitcoin-cli -rpcwallet=Alice"

MINER_ADDRESS=$($MINER getnewaddress)
ALICE_ADDRESS=$($ALICE getnewaddress)

# Fund the Miner wallet

MINER_BALANCE=$($MINER getbalance)

if awk "BEGIN {exit !($MINER_BALANCE < 50)}"; then
    # Mine enough blocks for at least one coinbase output to become spendable.
    $MINER generatetoaddress 101 "$MINER_ADDRESS" > /dev/null
fi

echo "Miner balance: $($MINER getbalance) BTC"

# Send some coins to Alice's wallet

ALICE_BALANCE=$($ALICE getbalance)

if awk "BEGIN {exit !($ALICE_BALANCE > 0)}"; then
    echo "Alice already has a balance."
else
    FUNDING_TXID=$($MINER sendtoaddress "$ALICE_ADDRESS" 20)

    echo "Funding transaction: $FUNDING_TXID"

    # Confirm Alice's funding transaction.
    $MINER generatetoaddress 1 "$MINER_ADDRESS" > /dev/null
fi

# Confirm that Alice has a positive balance.
ALICE_BALANCE=$($ALICE getbalance)

if awk "BEGIN {exit !($ALICE_BALANCE > 0)}"; then
    echo "Alice balance: $ALICE_BALANCE BTC"
else
    echo "Alice has no balance."
    exit 1
fi

# Create refund transaction where Alice pays 10 BTC to Miner
# Additionally, add a relative timelock of 10 blocks

REFUND_UTXO=$(
    $ALICE listunspent 1 |
    jq -c 'map(select(.amount >= 10))[0]'
)

REFUND_INPUT_TXID=$(echo "$REFUND_UTXO" | jq -r '.txid')
REFUND_INPUT_VOUT=$(echo "$REFUND_UTXO" | jq -r '.vout')
REFUND_INPUT_AMOUNT=$(echo "$REFUND_UTXO" | jq -r '.amount')

MINER_REFUND_ADDRESS=$($MINER getnewaddress)

# Leave 0.001 BTC as the transaction fee.
CHANGE=$(awk -v amount="$REFUND_INPUT_AMOUNT" \
    'BEGIN {printf "%.8f", amount - 10 - 0.001}')

# nSequence = 10 gives a relative block-based timelock of 10 blocks.
# Version 2 is required for BIP68 relative timelocks.
REFUND_RAW=$(
    $ALICE createrawtransaction \
    "[{\"txid\":\"$REFUND_INPUT_TXID\",\"vout\":$REFUND_INPUT_VOUT,\"sequence\":10}]" \
    "[{\"$MINER_REFUND_ADDRESS\":10},{\"$ALICE_ADDRESS\":$CHANGE}]" \
    0 \
    false \
    2
)

REFUND_SIGNED=$(
    $ALICE signrawtransactionwithwallet "$REFUND_RAW" |
    jq -r '.hex'
)

# Sign and broadcast the transaction. Is the broadcast successful?

set +e
EARLY_BROADCAST=$($ALICE sendrawtransaction "$REFUND_SIGNED" 2>&1)
EARLY_BROADCAST_STATUS=$?
set -e

echo "Attempting to broadcast refund transaction before 10 blocks:"
echo "$EARLY_BROADCAST"

# The transaction should not be accepted yet because its input has
# a relative timelock of 10 blocks.

# Generate 10 blocks

MINER_CURRENT_HEIGHT=$(bitcoin-cli getblockcount)

$MINER generatetoaddress 10 "$MINER_ADDRESS" > /dev/null

echo "Current block height: $(bitcoin-cli getblockcount)"

# Broadcast the transaction again. Is the broadcast successful now?

REFUND_TXID=$($ALICE sendrawtransaction "$REFUND_SIGNED")

echo "Refund transaction: $REFUND_TXID"

# Mine one additional block to confirm the refund transaction.
$MINER generatetoaddress 1 "$MINER_ADDRESS" > /dev/null

echo "Alice final balance: $($ALICE getbalance) BTC"

# Output the transaction ID to `out.txt`

echo "$REFUND_TXID" > out.txt