ifneq (,$(wildcard .env))
    include .env
    export
endif

.PHONY: fmt compile test test-unit test-integration test-fuzz test-invariant gas coverage deploy-genlayer deploy-all deploy-localhost deploy-base-sepolia deploy-base

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
	@echo "  test                         - Run all tests"
	@echo "  test-unit                    - Run unit tests only"
	@echo "  test-integration             - Run integration tests only"
	@echo "  test-fuzz                    - Run fuzz tests only"
	@echo "  test-invariant               - Run invariant tests only"
	@echo "  gas                          - Generate gas report"
	@echo "  coverage                     - Run test coverage with summary report"
	@echo "  deploy-localhost             - Deploy GenLayer contracts to localhost"
	@echo "  deploy-base-sepolia          - Deploy GenLayer contracts to base sepolia"
	@echo "  deploy-base                  - Deploy GenLayer contracts to base"

fmt:
	@forge fmt

compile:
	@forge compile --sizes

test:
	@forge test -vvv --fail-fast

test-unit:
	@forge test --match-path "test/unit/*" -vvv --fail-fast

test-integration:
	@forge test --match-path "test/integration/*" -vvv --fail-fast

test-fuzz:
	@forge test --match-path "test/fuzz/*" -vvv --fail-fast

test-invariant:
	@forge test --match-path "test/invariant/*" -vvv --fail-fast

gas:
	@forge test --gas-report

coverage:
	@echo "Running test coverage with summary report for core contracts..."
	@FOUNDRY_PROFILE=coverage forge coverage --ir-minimum --report summary \
		--no-match-coverage "(GLTToken|MockLLMOracle|script|test)"

deploy-localhost: cleanup-localhost
	@echo "Deploying to localhost network"
	@make deploy-genlayer RPC_URL=http://127.0.0.1:8545 LOCAL_DEPLOY=1

deploy-base-sepolia:
	@echo "Deploying to base sepolia network"
	@make deploy-genlayer RPC_URL=https://base-sepolia.g.alchemy.com/v2/$(ALCHEMY_API_KEY)

deploy-base:
	@echo "Deploying to base network"
	@make deploy-genlayer RPC_URL=https://base.g.alchemy.com/v2/$(ALCHEMY_API_KEY)

deploy-genlayer:
	@forge script script/Deploy.s.sol:Deploy \
		--rpc-url $(RPC_URL) \
		--broadcast \
		$(DEPLOY_PARAMS)

cleanup-localhost:
	@echo "Cleaning up localhost"
	@forge clean
	@rm -rf broadcast/*/31337
