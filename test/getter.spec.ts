import { expect } from "chai";
import { ethers, utils as ethersUtils } from "ethers";
import { ethers as hardhatEthers, network } from "hardhat";

import { randomHex } from "./utils/encoding";
import { seaportFixture } from "./utils/fixtures";
import { VERSION } from "./utils/helpers";
import { faucet } from "./utils/impersonate";

const { keccak256, toUtf8Bytes } = ethersUtils;

describe(`Getter tests (Seaport ${VERSION})`, function () {
  const { provider } = hardhatEthers;
  let marketplaceContract: ethers.Contract;
  let owner: ethers.Wallet;
  let conduitController: ethers.Contract;
  let directMarketplaceContract: ethers.Contract;

  after(async () => {
    await network.provider.request({
      method: "hardhat_reset",
    });
  });

  before(async () => {
    owner = new ethers.Wallet(randomHex(32), provider);

    await faucet(owner.address, provider);

    ({ conduitController, marketplaceContract, directMarketplaceContract } =
      await seaportFixture(owner));
  });

  it("gets correct name", async () => {
    const name = await marketplaceContract.name();
    expect(name).to.equal(process.env.REFERENCE ? "Consideration" : "Seaport");

    const directName = await directMarketplaceContract.name();
    expect(directName).to.equal("Consideration");
  });

  it("gets correct version, domain separator and conduit controller", async () => {
    const name = process.env.REFERENCE ? "Consideration" : "Seaport";
    const {
      version,
      domainSeparator,
      conduitController: controller,
    } = await marketplaceContract.information();

    const typehash = keccak256(
      toUtf8Bytes(
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
      )
    );
    const namehash = keccak256(toUtf8Bytes(name));
    const versionhash = keccak256(toUtf8Bytes(version));
    const { chainId } = await provider.getNetwork();
    const chainIdEncoded = chainId.toString(16).padStart(64, "0");
    const addressEncoded = marketplaceContract.address
      .slice(2)
      .padStart(64, "0");
    expect(domainSeparator).to.equal(
      keccak256(
        `0x${typehash.slice(2)}${namehash.slice(2)}${versionhash.slice(
          2
        )}${chainIdEncoded}${addressEncoded}`
      )
    );
    expect(controller).to.equal(conduitController.address);
  });
});
