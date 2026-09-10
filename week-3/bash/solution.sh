# Get blockchain info using bitcoin-cli
blockchain_info=$(bitcoin-cli -rpcuser=alice -rpcpassword=password getblockchaininfo)

# Print the blockchain info
echo "$blockchain_info"

# Create/Load the wallets, named 'Miner', 'Alice' and 'Bob'. Have logic to optionally create/load them if they do not exist or not loaded already.
for wallet in Miner Alice Bob; do
    if bitcoin-cli -rpcuser=alice -rpcpassword=password listwallets | jq -e --arg w "$wallet" '.[] | select(. == $w)' >/dev/null; then
        echo "$wallet wallet already loaded"
    elif bitcoin-cli -rpcuser=alice -rpcpassword=password listwalletdir | jq -e --arg w "$wallet" '.wallets[] | select(.name == $w)' >/dev/null; then
        bitcoin-cli -rpcuser=alice -rpcpassword=password loadwallet "$wallet"
    else
        bitcoin-cli -rpcuser=alice -rpcpassword=password createwallet "$wallet"
    fi
done

# Generate spendable balances in the Miner wallet (≥ 150 BTC), then send 15 BTC each to Alice and Bob
MINER_CLI="bitcoin-cli -rpcuser=alice -rpcpassword=password -rpcwallet=Miner"
ALICE_CLI="bitcoin-cli -rpcuser=alice -rpcpassword=password -rpcwallet=Alice"
BOB_CLI="bitcoin-cli -rpcuser=alice -rpcpassword=password -rpcwallet=Bob"

MINER_ADDRESS=$($MINER_CLI getnewaddress)

# Generate enough blocks for spendable coinbase rewards.
$MINER_CLI generatetoaddress 103 "$MINER_ADDRESS"

ALICE_ADDRESS=$($ALICE_CLI getnewaddress)
BOB_ADDRESS=$($BOB_CLI getnewaddress)

$MINER_CLI sendtoaddress "$ALICE_ADDRESS" 15
$MINER_CLI sendtoaddress "$BOB_ADDRESS" 15

# Confirm the 15 BTC payments.
$MINER_CLI generatetoaddress 1 "$MINER_ADDRESS"

# Construct 2-of-2 multisig (Alice & Bob) and build funding PSBT to contribute 20 BTC total
ALICE_MS_ADDRESS=$($ALICE_CLI getnewaddress)
BOB_MS_ADDRESS=$($BOB_CLI getnewaddress)

ALICE_PUBKEY=$($ALICE_CLI getaddressinfo "$ALICE_MS_ADDRESS" | jq -r '.pubkey')
BOB_PUBKEY=$($BOB_CLI getaddressinfo "$BOB_MS_ADDRESS" | jq -r '.pubkey')

MULTISIG=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password createmultisig 2 \
    "[\"$ALICE_PUBKEY\",\"$BOB_PUBKEY\"]" bech32
)

MULTISIG_ADDRESS=$(echo "$MULTISIG" | jq -r '.address')
MULTISIG_WITNESS_SCRIPT=$(echo "$MULTISIG" | jq -r '.redeemScript')

echo "2-of-2 P2WSH address: $MULTISIG_ADDRESS"

# Find one confirmed 15 BTC UTXO belonging to Alice and Bob.
ALICE_UTXO=$(
    $ALICE_CLI listunspent 1 9999999 |
    jq -c '[.[] | select(.amount >= 14.999 and .amount <= 15.001)] | .[0]'
)

BOB_UTXO=$(
    $BOB_CLI listunspent 1 9999999 |
    jq -c '[.[] | select(.amount >= 14.999 and .amount <= 15.001)] | .[0]'
)

if [ "$ALICE_UTXO" = "null" ] || [ "$BOB_UTXO" = "null" ]; then
    echo "ERROR: Could not find the required 15 BTC UTXOs."
    exit 1
fi

ALICE_TXID=$(echo "$ALICE_UTXO" | jq -r '.txid')
ALICE_VOUT=$(echo "$ALICE_UTXO" | jq -r '.vout')

BOB_TXID=$(echo "$BOB_UTXO" | jq -r '.txid')
BOB_VOUT=$(echo "$BOB_UTXO" | jq -r '.vout')

# Build funding transaction.
# 15 + 15 = 30 BTC inputs.
# 20 BTC multisig + 4.999 BTC Alice + 4.999 BTC Bob = 29.998 BTC.
# The remaining 0.002 BTC is the transaction fee.
FUNDING_PSBT=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password createpsbt \
    "[{\"txid\":\"$ALICE_TXID\",\"vout\":$ALICE_VOUT},{\"txid\":\"$BOB_TXID\",\"vout\":$BOB_VOUT}]" \
    "[{\"$MULTISIG_ADDRESS\":20},{\"$ALICE_ADDRESS\":4.999},{\"$BOB_ADDRESS\":4.999}]"
)

# Sign & broadcast the funding PSBT
FUNDING_PSBT_ALICE=$(
    $ALICE_CLI walletprocesspsbt "$FUNDING_PSBT" |
    jq -r '.psbt'
)

FUNDING_PSBT_BOB=$(
    $BOB_CLI walletprocesspsbt "$FUNDING_PSBT_ALICE" |
    jq -r '.psbt'
)

FUNDING_FINAL=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    finalizepsbt "$FUNDING_PSBT_BOB"
)

if [ "$(echo "$FUNDING_FINAL" | jq -r '.complete')" != "true" ]; then
    echo "ERROR: Funding transaction is not fully signed."
    echo "$FUNDING_FINAL"
    exit 1
fi

FUNDING_HEX=$(echo "$FUNDING_FINAL" | jq -r '.hex')

FUNDING_TXID=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    sendrawtransaction "$FUNDING_HEX"
)

echo "Funding TXID: $FUNDING_TXID"

# Mine 6 blocks to confirm
$MINER_CLI generatetoaddress 6 "$MINER_ADDRESS"

# Print balances for Alice and Bob
echo "Alice balance: $($ALICE_CLI getbalance)"
echo "Bob balance: $($BOB_CLI getbalance)"

# Build spending PSBT to spend the 20 BTC multisig output, ensuring 10 BTC is equally distributed back between Alice and Bob after accounting for fees
FUNDING_TX=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    getrawtransaction "$FUNDING_TXID" true
)

MULTISIG_VOUT=$(
    echo "$FUNDING_TX" |
    jq -r --arg address "$MULTISIG_ADDRESS" \
    '.vout[] | select(.scriptPubKey.address == $address) | .n'
)

# New addresses for the final 10 BTC distribution.
ALICE_FINAL_ADDRESS=$($ALICE_CLI getnewaddress)
BOB_FINAL_ADDRESS=$($BOB_CLI getnewaddress)

# 20 BTC input.
# 9.999 BTC to Alice + 9.999 BTC to Bob.
# 0.002 BTC fee.
SPENDING_RAW=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    createrawtransaction \
    "[{\"txid\":\"$FUNDING_TXID\",\"vout\":$MULTISIG_VOUT}]" \
    "[{\"$ALICE_FINAL_ADDRESS\":9.999},{\"$BOB_FINAL_ADDRESS\":9.999}]"
)

# Get the P2WSH scriptPubKey from the funding transaction.
MULTISIG_SCRIPTPUBKEY=$(
    echo "$FUNDING_TX" |
    jq -r --arg address "$MULTISIG_ADDRESS" \
    '.vout[] | select(.scriptPubKey.address == $address) | .scriptPubKey.hex'
)

# Get the HD derivation paths for the multisig keys.
ALICE_HD_PATH=$(
    $ALICE_CLI getaddressinfo "$ALICE_MS_ADDRESS" |
    jq -r '.hdkeypath'
)

BOB_HD_PATH=$(
    $BOB_CLI getaddressinfo "$BOB_MS_ADDRESS" |
    jq -r '.hdkeypath'
)

# Get Alice's master private key from her private descriptor.
ALICE_TPRV=$(
    $ALICE_CLI listdescriptors true |
    jq -r '.descriptors[]
        | select(.desc | startswith("wpkh(tprv"))
        | select(.desc | contains("/84h/1h/0h/0/*"))
        | .desc' |
    sed -E 's/^wpkh\((tprv[^\/]+).*/\1/'
)

# Get Bob's master private key from his private descriptor.
BOB_TPRV=$(
    $BOB_CLI listdescriptors true |
    jq -r '.descriptors[]
        | select(.desc | startswith("wpkh(tprv"))
        | select(.desc | contains("/84h/1h/0h/0/*"))
        | .desc' |
    sed -E 's/^wpkh\((tprv[^\/]+).*/\1/'
)

if [ -z "$ALICE_TPRV" ] || [ -z "$BOB_TPRV" ]; then
    echo "ERROR: Could not obtain Alice/Bob private extended keys."
    exit 1
fi

# Convert paths such as m/84'/1'/0'/0/21 into descriptor paths.
ALICE_DESCRIPTOR_PATH=$(echo "$ALICE_HD_PATH" | sed "s#^m/##; s/'/h/g")
BOB_DESCRIPTOR_PATH=$(echo "$BOB_HD_PATH" | sed "s#^m/##; s/'/h/g")

# Build private 2-of-2 descriptors.
# Each wallet receives its own private key and the other wallet's public key.
ALICE_PRIVATE_MULTISIG_DESCRIPTOR="wsh(multi(2,$ALICE_TPRV/$ALICE_DESCRIPTOR_PATH,$BOB_PUBKEY))"
BOB_PRIVATE_MULTISIG_DESCRIPTOR="wsh(multi(2,$ALICE_PUBKEY,$BOB_TPRV/$BOB_DESCRIPTOR_PATH))"

# Add checksums to the descriptors.
ALICE_PRIVATE_MULTISIG_DESCRIPTOR_WITH_CHECKSUM=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    getdescriptorinfo "$ALICE_PRIVATE_MULTISIG_DESCRIPTOR" |
    jq -r --arg d "$ALICE_PRIVATE_MULTISIG_DESCRIPTOR" \
    '.checksum as $c | ($d + "#" + $c)'
)

BOB_PRIVATE_MULTISIG_DESCRIPTOR_WITH_CHECKSUM=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    getdescriptorinfo "$BOB_PRIVATE_MULTISIG_DESCRIPTOR" |
    jq -r --arg d "$BOB_PRIVATE_MULTISIG_DESCRIPTOR" \
    '.checksum as $c | ($d + "#" + $c)'
)

# Import the private multisig descriptor into Alice.
$ALICE_CLI importdescriptors \
    "[{\"desc\":\"$ALICE_PRIVATE_MULTISIG_DESCRIPTOR_WITH_CHECKSUM\",\"timestamp\":\"now\",\"active\":false}]"

# Import the private multisig descriptor into Bob.
$BOB_CLI importdescriptors \
    "[{\"desc\":\"$BOB_PRIVATE_MULTISIG_DESCRIPTOR_WITH_CHECKSUM\",\"timestamp\":\"now\",\"active\":false}]"

# Sign the spending transaction with Alice's wallet.
SPENDING_SIGNED_ALICE=$(
    $ALICE_CLI signrawtransactionwithwallet \
    "$SPENDING_RAW" \
    "[{\"txid\":\"$FUNDING_TXID\",\"vout\":$MULTISIG_VOUT,\"scriptPubKey\":\"$MULTISIG_SCRIPTPUBKEY\",\"witnessScript\":\"$MULTISIG_WITNESS_SCRIPT\",\"amount\":20}]"
)

if [ "$(echo "$SPENDING_SIGNED_ALICE" | jq -r '.complete')" = "true" ]; then
    SPENDING_SIGNED="$SPENDING_SIGNED_ALICE"
else
    # Bob adds his signature to Alice's partially signed transaction.
    SPENDING_SIGNED=$(
        $BOB_CLI signrawtransactionwithwallet \
        "$(echo "$SPENDING_SIGNED_ALICE" | jq -r '.hex')" \
        "[{\"txid\":\"$FUNDING_TXID\",\"vout\":$MULTISIG_VOUT,\"scriptPubKey\":\"$MULTISIG_SCRIPTPUBKEY\",\"witnessScript\":\"$MULTISIG_WITNESS_SCRIPT\",\"amount\":20}]"
    )
fi

if [ "$(echo "$SPENDING_SIGNED" | jq -r '.complete')" != "true" ]; then
    echo "ERROR: Spending transaction is not fully signed."
    echo "$SPENDING_SIGNED"
    exit 1
fi

SPENDING_HEX=$(echo "$SPENDING_SIGNED" | jq -r '.hex')

# Sign & broadcast the spending PSBT
SPENDING_TXID=$(
    bitcoin-cli -rpcuser=alice -rpcpassword=password \
    sendrawtransaction "$SPENDING_HEX"
)

echo "Spending TXID: $SPENDING_TXID"

# Mine 6 blocks to confirm the spending transaction
$MINER_CLI generatetoaddress 6 "$MINER_ADDRESS"

# Print final balances for Alice and Bob
echo "Final Alice balance: $($ALICE_CLI getbalance)"
echo "Final Bob balance: $($BOB_CLI getbalance)"

# Save transaction IDs for the assignment tests.
echo "$FUNDING_TXID" > out.txt
echo "$SPENDING_TXID" >> out.txt