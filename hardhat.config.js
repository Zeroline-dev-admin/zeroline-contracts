require("@nomicfoundation/hardhat-toolbox");

// Compile only. No private keys are stored in this repository.
module.exports = {
  solidity: {
    version: "0.8.24",
    settings: { optimizer: { enabled: true, runs: 1 }, evmVersion: "cancun" },
  },
  networks: {
    bsc: { url: "https://bsc-dataseed.bnbchain.org", chainId: 56 },
    bscTestnet: { url: "https://data-seed-prebsc-1-s1.bnbchain.org:8545", chainId: 97 },
  },
};
