ifneq (,$(wildcard .env))
    include .env
    export
endif

.PHONY: fmt compile test gas deploy-smart-account deploy-smart-account-factory deploy-all deploy-localhost deploy-base-sepolia deploy-base

DEPLOY_PARAMS :=
ifeq ($(LOCAL_DEPLOY),1)
  DEPLOY_PARAMS := --force
else
  DEPLOY_PARAMS := --etherscan-api-key $(ETHERSCAN_API_KEY) --verify
endif

all:
	@echo "Available targets:"
	@echo "  fmt                          - Format code"
	@echo "  compile                      - Compile contracts"
	@echo "  test                         - Run tests"
	@echo "  gas                          - Generate gas report"
	@echo "  deploy-localhost             - Deploy all contracts to localhost"
	@echo "  deploy-base-sepolia          - Deploy all contracts to base sepolia"
	@echo "  deploy-base                  - Deploy all contracts to base"

fmt:
	@forge fmt

compile:
	@forge compile --sizes

test:
	@forge test -vvv --fail-fast

gas:
	@forge snapshot --gas-report

deploy-localhost: cleanup-localhost
	@echo "Deploying to localhost network"
	@make deploy-all RPC_URL=http://127.0.0.1:8545 LOCAL_DEPLOY=1

deploy-base-sepolia:
	@echo "Deploying to base sepolia network"
	@make deploy-all RPC_URL=https://base-sepolia.g.alchemy.com/v2/$(ALCHEMY_API_KEY)

deploy-base:
	@echo "Deploying to base network"
	@make deploy-all RPC_URL=https://base.g.alchemy.com/v2/$(ALCHEMY_API_KEY)

deploy-smart-account:
	@forge script script/SmartAccount.s.sol:SmartAccountScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		$(DEPLOY_PARAMS)

deploy-smart-account-factory:
	@forge script script/SmartAccountFactory.s.sol:SmartAccountFactoryScript \
		--rpc-url $(RPC_URL) \
		--broadcast \
		$(DEPLOY_PARAMS)

deploy-all: deploy-smart-account deploy-smart-account-factory

cleanup-localhost:
	@echo "Cleaning up localhost"
	@forge clean
	@rm -rf broadcast/*/31337
