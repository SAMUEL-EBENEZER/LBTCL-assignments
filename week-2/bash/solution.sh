#!/bin/bash

set -e

RPC_USER="alice"
RPC_PASSWORD="password"

CLI="bitcoin-cli -rpcuser=$RPC_USER -rpcpassword=$RPC_PASSWORD"

MINER_CLI="$CLI -rpcwallet=Miner"
TRADER_CLI="$CLI -rpcwallet=Trader"

echo "=== Week 2 Assignment ==="

# --------------------------------------------------
# 1. Make sure wallets are loaded
# --------------------------------------------------

if ! $CLI listwallets | jq -e '.[] | select(. == "Miner")' >/dev/null; then
    $CLI loadwallet Miner >/dev/null
fi

if ! $CLI listwallets | jq -e '.[] | select(. == "Trader")' >/dev/null; then
    $CLI loadwallet Trader >/dev/null
fi

echo "Wallets loaded."

# --------------------------------------------------
# 2. Make sure Miner has at least 150 BTC spendable
# --------------------------------------------------

BALANCE=$($MINER_CLI getbalance)

if (( $(echo "$BALANCE < 150" | bc -l) )); then
    MINER_ADDRESS=$($MINER_CLI getnewaddress)
    $CLI generatetoaddress 103 "$MINER_ADDRESS" >/dev/null
fi

echo "Miner balance: $($MINER_CLI getbalance) BTC"

# --------------------------------------------------
# 3. Generate Trader address
# --------------------------------------------------

TRADER_ADDRESS=$($TRADER_CLI getnewaddress)

echo "Trader address: $TRADER_ADDRESS"

# --------------------------------------------------
# 4. Find two mature 50 BTC coinbase UTXOs
# --------------------------------------------------

UTXOS=$($MINER_CLI listunspent 101 9999999)

INPUT1_TXID=$(echo "$UTXOS" | jq -r '[.[] | select(.amount == 50)][0].txid')

INPUT1_VOUT=$(echo "$UTXOS" | jq -r '[.[] | select(.amount == 50)][0].vout')

INPUT2_TXID=$(echo "$UTXOS" | jq -r '[.[] | select(.amount == 50)][1].txid')

INPUT2_VOUT=$(echo "$UTXOS" | jq -r '[.[] | select(.amount == 50)][1].vout')

if [ "$INPUT1_TXID" = "null" ] || [ "$INPUT2_TXID" = "null" ]; then
    echo "ERROR: Could not find two mature 50 BTC UTXOs."
    exit 1
fi

echo "Input 1: $INPUT1_TXID:$INPUT1_VOUT"
echo "Input 2: $INPUT2_TXID:$INPUT2_VOUT"

# --------------------------------------------------
# 5. Generate Miner change address
# --------------------------------------------------

MINER_CHANGE_ADDRESS=$($MINER_CLI getnewaddress)

# --------------------------------------------------
# 6. Create Parent transaction
#
# Inputs:
#   50 BTC
#   50 BTC
#
# Outputs:
#   70 BTC Trader
#   29.99999 BTC Miner
#
# Fee:
#   0.00001 BTC = 1,000 sats
#
# sequence 4294967293 signals RBF
# --------------------------------------------------

PARENT_RAW=$($MINER_CLI createrawtransaction \
"[
    {
        \"txid\":\"$INPUT1_TXID\",
        \"vout\":$INPUT1_VOUT,
        \"sequence\":4294967293
    },
    {
        \"txid\":\"$INPUT2_TXID\",
        \"vout\":$INPUT2_VOUT,
        \"sequence\":4294967293
    }
]" \
"{
    \"$TRADER_ADDRESS\":70,
    \"$MINER_CHANGE_ADDRESS\":29.99999
}")

echo "Parent transaction created."

# --------------------------------------------------
# 7. Sign Parent
# --------------------------------------------------

PARENT_SIGNED=$($MINER_CLI signrawtransactionwithwallet "$PARENT_RAW")

PARENT_HEX=$(echo "$PARENT_SIGNED" | jq -r '.hex')

# --------------------------------------------------
# 8. Broadcast Parent
# --------------------------------------------------

PARENT_TXID=$($MINER_CLI sendrawtransaction "$PARENT_HEX")

echo "Parent TXID: $PARENT_TXID"

# --------------------------------------------------
# 9. Create parent.json
# --------------------------------------------------

PARENT_DECODED=$($CLI decoderawtransaction "$PARENT_HEX")

PARENT_WEIGHT=$(echo "$PARENT_DECODED" | jq -r '.weight')

echo "$PARENT_DECODED" | jq \
    --arg txid "$PARENT_TXID" \
    --argjson weight "$PARENT_WEIGHT" \
'
{
    txid: $txid,

    input: [
        .vin[] |
        {
            txid: .txid,
            vout: .vout
        }
    ],

    output: [
        .vout[] |
        {
            scriptpubkey: .scriptPubKey.hex,
            amount: .value
        }
    ],

    fee: 0.00001,
    weight: $weight
}
' > parent.json

echo "parent.json created."

# --------------------------------------------------
# 10. Find Parent's Miner output
# --------------------------------------------------

PARENT_MINER_VOUT=$(echo "$PARENT_DECODED" | jq -r \
    --arg address "$MINER_CHANGE_ADDRESS" \
    '
    .vout[]
    | select(.scriptPubKey.address == $address)
    | .n
    '
)

echo "Parent Miner output: $PARENT_MINER_VOUT"

# --------------------------------------------------
# 11. Create Child
#
# Parent Miner output:
#   29.99999 BTC
#
# Child:
#   29.99998 BTC -> Miner
#
# Fee:
#   0.00001 BTC
# --------------------------------------------------

CHILD_MINER_ADDRESS=$($MINER_CLI getnewaddress)

CHILD_RAW=$($MINER_CLI createrawtransaction \
"[
    {
        \"txid\":\"$PARENT_TXID\",
        \"vout\":$PARENT_MINER_VOUT
    }
]" \
"{
    \"$CHILD_MINER_ADDRESS\":29.99998
}")

# --------------------------------------------------
# 12. Sign Child
# --------------------------------------------------

CHILD_SIGNED=$($MINER_CLI signrawtransactionwithwallet "$CHILD_RAW")

CHILD_HEX=$(echo "$CHILD_SIGNED" | jq -r '.hex')

# --------------------------------------------------
# 13. Broadcast Child
# --------------------------------------------------

CHILD_TXID=$($MINER_CLI sendrawtransaction "$CHILD_HEX")

echo "Child TXID: $CHILD_TXID"

# --------------------------------------------------
# 14. Create child.json
# --------------------------------------------------

CHILD_DECODED=$($CLI decoderawtransaction "$CHILD_HEX")

CHILD_WEIGHT=$(echo "$CHILD_DECODED" | jq -r '.weight')

echo "$CHILD_DECODED" | jq \
    --arg txid "$CHILD_TXID" \
    --argjson weight "$CHILD_WEIGHT" \
'
{
    txid: $txid,

    input: [
        .vin[] |
        {
            txid: .txid,
            vout: .vout
        }
    ],

    output: [
        .vout[] |
        {
            scriptpubkey: .scriptPubKey.hex,
            amount: .value
        }
    ],

    fee: 0.00001,
    weight: $weight
}
' > child.json

echo "child.json created."

# --------------------------------------------------
# 15. Create RBF replacement
#
# Same inputs as Parent.
#
# Outputs:
#   70 BTC Trader
#   29.99989 BTC Miner
#
# Total:
#   99.99989 BTC
#
# Fee:
#   0.00011 BTC = 11,000 sats
# --------------------------------------------------

RBF_MINER_ADDRESS=$($MINER_CLI getnewaddress)

RBF_RAW=$($MINER_CLI createrawtransaction \
"[
    {
        \"txid\":\"$INPUT1_TXID\",
        \"vout\":$INPUT1_VOUT,
        \"sequence\":4294967293
    },
    {
        \"txid\":\"$INPUT2_TXID\",
        \"vout\":$INPUT2_VOUT,
        \"sequence\":4294967293
    }
]" \
"{
    \"$TRADER_ADDRESS\":70,
    \"$RBF_MINER_ADDRESS\":29.99989
}")

echo "RBF replacement created."

# --------------------------------------------------
# 16. Sign RBF replacement
# --------------------------------------------------

RBF_SIGNED=$($MINER_CLI signrawtransactionwithwallet "$RBF_RAW")

RBF_HEX=$(echo "$RBF_SIGNED" | jq -r '.hex')

# --------------------------------------------------
# 17. Broadcast RBF replacement
# --------------------------------------------------

RBF_TXID=$($MINER_CLI sendrawtransaction "$RBF_HEX")

echo "RBF TXID: $RBF_TXID"

# --------------------------------------------------
# 18. Create parent-rbf.json
# --------------------------------------------------

RBF_DECODED=$($CLI decoderawtransaction "$RBF_HEX")

RBF_WEIGHT=$(echo "$RBF_DECODED" | jq -r '.weight')

echo "$RBF_DECODED" | jq \
    --arg txid "$RBF_TXID" \
    --argjson weight "$RBF_WEIGHT" \
'
{
    txid: $txid,

    input: [
        .vin[] |
        {
            txid: .txid,
            vout: .vout
        }
    ],

    output: [
        .vout[] |
        {
            scriptpubkey: .scriptPubKey.hex,
            amount: .value
        }
    ],

    fee: 0.00011,
    weight: $weight
}
' > parent-rbf.json

echo "parent-rbf.json created."

echo ""
echo "======================================"
echo "WEEK 2 COMPLETED"
echo "======================================"
echo "Parent:   $PARENT_TXID"
echo "Child:    $CHILD_TXID"
echo "RBF:      $RBF_TXID"
echo ""
echo "Files created:"
echo "  parent.json"
echo "  child.json"
echo "  parent-rbf.json"