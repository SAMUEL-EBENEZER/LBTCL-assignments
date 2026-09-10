# Get blockchain info using bitcoin-cli
blockchain_info=$(bitcoin-cli getblockchaininfo)

# Print the blockchain info
echo "$blockchain_info"

# Create/Load the wallets, named 'Miner', 'Employee', and 'Employer'. Have logic to optionally create/load them if they do not exist or not loaded already.

ensure_wallet() { 
    wallet="$1" 
    if bitcoin-cli listwallets | jq -e --arg w "$wallet" '. | index($w)' > /dev/null 2>&1; then 
        echo "$wallet wallet is already loaded." 
        return 
    fi  
    
    if bitcoin-cli listwalletdir | jq -e --arg w "$wallet" '.wallets[] | select(.name == $w)' > /dev/null 2>&1; then 
        bitcoin-cli loadwallet "$wallet" > /dev/null 
        echo "$wallet wallet loaded." 
    else 
        bitcoin-cli createwallet "$wallet" > /dev/null 
        echo "$wallet wallet created." 
    fi }

ensure_wallet "Miner"
ensure_wallet "Employee"
ensure_wallet "Employer"

MINER="bitcoin-cli -rpcwallet=Miner"
EMPLOYEE="bitcoin-cli -rpcwallet=Employee"
EMPLOYER="bitcoin-cli -rpcwallet=Employer"

MINER_ADDRESS=$($MINER getnewaddress)
EMPLOYER_ADDRESS=$($EMPLOYER getnewaddress)
EMPLOYEE_ADDRESS=$($EMPLOYEE getnewaddress)

# Generate spendable balances in the Miner wallet (≥ 150 BTC), then send some coins to Employer

MINER_BALANCE=$($MINER getbalance)

if awk "BEGIN {exit !($MINER_BALANCE < 150)}"; then
    $MINER generatetoaddress 103 "$MINER_ADDRESS" > /dev/null
fi

MINER_BALANCE=$($MINER getbalance)
echo "Miner balance: $MINER_BALANCE BTC"

EMPLOYER_BALANCE=$($EMPLOYER getbalance)

if awk "BEGIN {exit !($EMPLOYER_BALANCE < 40)}"; then
    $MINER sendtoaddress "$EMPLOYER_ADDRESS" 50 > /dev/null
    $MINER generatetoaddress 1 "$MINER_ADDRESS" > /dev/null
fi

echo "Employer balance: $($EMPLOYER getbalance) BTC"

# Create a salary transaction of 40 BTC, where the Employer pays the Employee
# Add an absolute timelock of 500 Blocks for the transaction

EMPLOYER_UTXO=$(
    $EMPLOYER listunspent 1 |
    jq -c 'map(select(.amount >= 40))[0]'
)

FUNDING_INPUT_TXID=$(echo "$EMPLOYER_UTXO" | jq -r '.txid')
FUNDING_INPUT_VOUT=$(echo "$EMPLOYER_UTXO" | jq -r '.vout')
FUNDING_INPUT_AMOUNT=$(echo "$EMPLOYER_UTXO" | jq -r '.amount')

CHANGE=$(awk -v amount="$FUNDING_INPUT_AMOUNT" \
    'BEGIN {printf "%.8f", amount - 40 - 0.001}')

FUNDING_RAW=$(
    $EMPLOYER createrawtransaction \
    "[{\"txid\":\"$FUNDING_INPUT_TXID\",\"vout\":$FUNDING_INPUT_VOUT,\"sequence\":4294967294}]" \
    "[{\"$EMPLOYEE_ADDRESS\":40},{\"$EMPLOYER_ADDRESS\":$CHANGE}]" \
    500 \
    false \
    2
)

FUNDING_SIGNED=$(
    $EMPLOYER signrawtransactionwithwallet "$FUNDING_RAW" |
    jq -r '.hex'
)

# Report in a comment what happens when you try to broadcast this transaction

# Before block 500, sendrawtransaction rejects this transaction because it is non-final due to its absolute timelock.

CURRENT_HEIGHT=$(bitcoin-cli getblockcount)

if [ "$CURRENT_HEIGHT" -lt 500 ]; then
    set +e
    PRE_BROADCAST=$($EMPLOYER sendrawtransaction "$FUNDING_SIGNED" 2>&1)
    set -e

    echo "Broadcast before block 500:"
    echo "$PRE_BROADCAST"
fi

# Mine up to 500th block and broadcast the transaction

CURRENT_HEIGHT=$(bitcoin-cli getblockcount)

if [ "$CURRENT_HEIGHT" -lt 500 ]; then
    BLOCKS_TO_MINE=$((500 - CURRENT_HEIGHT))
    $MINER generatetoaddress "$BLOCKS_TO_MINE" "$MINER_ADDRESS" > /dev/null
fi

FUNDING_TXID=$($EMPLOYER sendrawtransaction "$FUNDING_SIGNED")

echo "Timelocked funding transaction: $FUNDING_TXID"

$MINER generatetoaddress 1 "$MINER_ADDRESS" > /dev/null

# Print the final balances of Employee and Employer wallets

echo "Employee balance: $($EMPLOYEE getbalance) BTC"
echo "Employer balance: $($EMPLOYER getbalance) BTC"

# Create a spending transaction where the Employee spends the fund to a new Employee wallet address
# Add an OP_RETURN output in the spending transaction with the string data "I got my salary, I am rich".

SALARY_UTXO=$(
    $EMPLOYEE listunspent 1 |
    jq -c --arg txid "$FUNDING_TXID" \
    'map(select(.txid == $txid and .amount == 40))[0]'
)

SALARY_VOUT=$(echo "$SALARY_UTXO" | jq -r '.vout')

NEW_EMPLOYEE_ADDRESS=$($EMPLOYEE getnewaddress)

OP_RETURN_DATA="4920676f74206d792073616c6172792c204920616d2072696368"

SPENDING_RAW=$(
    $EMPLOYEE createrawtransaction \
    "[{\"txid\":\"$FUNDING_TXID\",\"vout\":$SALARY_VOUT}]" \
    "[{\"$NEW_EMPLOYEE_ADDRESS\":39.999},{\"data\":\"$OP_RETURN_DATA\"}]" \
    0 \
    false \
    2
)

# Sign and broadcast the transaction

SPENDING_SIGNED=$(
    $EMPLOYEE signrawtransactionwithwallet "$SPENDING_RAW" |
    jq -r '.hex'
)

SPENDING_TXID=$(
    $EMPLOYEE sendrawtransaction "$SPENDING_SIGNED"
)

echo "Spending transaction: $SPENDING_TXID"

$MINER generatetoaddress 1 "$MINER_ADDRESS" > /dev/null

# Print the final balances of the Employee and the Employer wallets

echo "Employee balance: $($EMPLOYEE getbalance) BTC"
echo "Employer balance: $($EMPLOYER getbalance) BTC"

# Output the txid of the timelocked funding transaction and the txid of the spending transaction to out.txt
# <txid_timelocked_funding>
# <txid_spending>

echo "$FUNDING_TXID" > out.txt
echo "$SPENDING_TXID" >> out.txt