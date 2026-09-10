from bitcoinrpc.authproxy import AuthServiceProxy, JSONRPCException

def main():

    try:
        # Connect to Bitcoin Core RPC with basic credentials
        rpc_user = "alice"
        rpc_password = "password"
        rpc_host = "127.0.0.1"
        rpc_port = 18443
        base_rpc_url = f"http://{rpc_user}:{rpc_password}@{rpc_host}:{rpc_port}"

        # General client for non-wallet-specific commands
        client = AuthServiceProxy(base_rpc_url)

        # Get blockchain info
        blockchain_info = client.getblockchaininfo()
        print("Blockchain Info:", blockchain_info)

        # Create/Load the wallets, named 'Miner' and 'Trader'. Have logic to optionally create/load them if they do not exist or not loaded already.

        # Generate spendable balances in the Miner wallet. How many blocks needs to be mined?

        # Load Trader wallet and generate a new address

        # Create parent transaction in the Miner wallet, sending 70 BTC to the Trader wallet address
        # Remember to signal for RBF

        # Sign and broadcast the transaction

        # Output the parent transaction in the specified format to parent.json

        # Create and child transaction that spends the parent transaction output

        # Output the child transaction in the specified format to child.json

        # Fee bump the Parent transaction using RBF. Do not use bitcoin-cli bumpfee

        # Sign and broadcast the fee-bumped transaction

        # Output the fee-bumped parent transaction in the specified format to parent-rbf.json

if __name__ == "__main__":
    main()