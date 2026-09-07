#!/usr/bin/env bash

# Get blockchain info using bitcoin-cli
blockchain_info=$(bitcoin-cli getblockchaininfo)

# Print the blockchain info
echo "$blockchain_info"

# Create/Load the wallets, named 'Miner' and 'Trader'. Have logic to optionally create/load them if they do not exist or not loaded already.

create_or_load_wallet() {
    wallet_name="$1"

    if bitcoin-cli listwallets | grep -q "\"$wallet_name\""; then
        echo "$wallet_name wallet is already loaded."
    elif bitcoin-cli loadwallet "$wallet_name" >/dev/null 2>&1; then
        echo "$wallet_name wallet loaded."
    else
        bitcoin-cli createwallet "$wallet_name"
    fi
}

create_or_load_wallet "Miner"
create_or_load_wallet "Trader"

# Generate spendable balances in the Miner wallet. How many blocks needs to be mined?

miner_address=$(bitcoin-cli -rpcwallet=Miner getnewaddress "Mining Reward")

blocks_mined=0

while true; do
    bitcoin-cli -rpcwallet=Miner generatetoaddress 1 "$miner_address" >/dev/null

    blocks_mined=$((blocks_mined + 1))

    miner_balance=$(bitcoin-cli -rpcwallet=Miner getbalance)

    if (( $(echo "$miner_balance > 0" | bc -l) )); then
        break
    fi
done

echo "Blocks mined: $blocks_mined"
echo "Miner balance: $miner_balance BTC"

# Load Trader wallet and generate a new address

trader_address=$(bitcoin-cli -rpcwallet=Trader getnewaddress "Received")
echo "Trader address: $trader_address"

# Send 20 BTC from Miner to Trader

txid=$(bitcoin-cli -rpcwallet=Miner sendtoaddress "$trader_address" 20)
echo "Transaction ID: $txid"

# Check transaction in mempool

mempool_entry=$(bitcoin-cli getmempoolentry "$txid")
echo "$mempool_entry"

# Mine 1 block to confirm the transaction

miner_address=$(bitcoin-cli -rpcwallet=Miner getnewaddress)
bitcoin-cli -rpcwallet=Miner generatetoaddress 1 "$miner_address"

# Extract all required transaction details

tx_info=$(bitcoin-cli getrawtransaction "$txid" true)

# Get the previous transaction that provided our input
input_txid=$(echo "$tx_info" | jq -r '.vin[0].txid')
input_vout=$(echo "$tx_info" | jq -r '.vin[0].vout')
input_tx_info=$(bitcoin-cli getrawtransaction "$input_txid" true)

# Extract Miner's input address and amount
miner_input_address=$(echo "$input_tx_info" | jq -r ".vout[$input_vout].scriptPubKey.address")
miner_input_amount=$(echo "$input_tx_info" | jq -r ".vout[$input_vout].value")

# Extract Trader's output address and amount
trader_output_address=$(echo "$tx_info" | jq -r '.vout[] | select(.value == 20) | .scriptPubKey.address')
trader_output_amount=$(echo "$tx_info" | jq -r '.vout[] | select(.value == 20) | .value')

# Extract Miner's change address and amount
miner_change_address=$(echo "$tx_info" | jq -r '.vout[] | select(.value != 20) | .scriptPubKey.address')
miner_change_amount=$(echo "$tx_info" | jq -r '.vout[] | select(.value != 20) | .value')

# Calculate the transaction fee
miner_fee=$(echo "$miner_input_amount - ($trader_output_amount + $miner_change_amount)" | bc -l)

# Get confirmation block information
block_hash=$(echo "$tx_info" | jq -r '.blockhash')
block_height=$(bitcoin-cli getblock "$block_hash" | jq -r '.height')

# Write the data to ../out.txt in the specified format given in readme.md
cat > out.txt <<EOF
$txid
$miner_input_address
$miner_input_amount
$trader_output_address
$trader_output_amount
$miner_change_address
$miner_change_amount
$miner_fee
$block_height
$block_hash
EOF