import {
  applyParamsToScript,
  Constr,
  credentialToAddress,
  Data,
  fromText,
  keyHashToCredential,
  Lovelace,
  mintingPolicyToId,
  PolicyId,
  toText,
  toUnit,
  TxSignBuilder,
  UTxO,
  Validator,
  validatorToAddress,
} from "@lucid-evolution/lucid";

import { koios } from "./providers/koios";
import { adaToLovelace, handleSuccess } from "./utils";
import { WalletConnection } from "./contexts/wallet/WalletContext";
import { BackerUTxO, CampaignUTxO } from "./contexts/campaign/CampaignContext";

import { network } from "@/config/lucid";
import { script } from "@/config/script";
import { STATE_TOKEN } from "@/config/crowdfunding";
import {
  BackerDatum,
  CampaignActionRedeemer,
  CampaignDatum,
  CampaignState,
} from "@/types/crowdfunding";
import { Platform } from "@/types/platform";

/**
 * Submit Tx helper
 */
async function submitTx(tx: TxSignBuilder) {
  const txSigned = await tx.sign.withWallet().complete();
  const txHash = await txSigned.submit();
  return txHash;
}

/**
 * Grab the smallest UTxO in JSON length (useful as a "nonce" UTxO)
 */
function getShortestUTxO(utxos: UTxO[]) {
  const bigint2str = (_: any, val: { toString: () => any }) =>
    typeof val === "bigint" ? val.toString() : val;

  let shortestUTxO = JSON.stringify(utxos[0], bigint2str).length;
  let utxo = utxos[0];

  for (let u = 1; u < utxos.length; u++) {
    const currLen = JSON.stringify(utxos[u], bigint2str).length;
    if (currLen < shortestUTxO) {
      shortestUTxO = currLen;
      utxo = utxos[u];
    }
  }

  return utxo;
}

/**
 * Create a campaign by minting the "state token" with the `InitCampaign(CampaignDatum)` redeemer
 */
export async function createCampaign(
  { lucid, wallet, address, pkh, stakeAddress, skh }: WalletConnection,
  campaign: { name: string; goal: Lovelace; deadline: bigint }
): Promise<CampaignUTxO> {
  if (!lucid) throw "Uninitialized Lucid";
  if (!wallet) throw "Disconnected Wallet";

  // Check that you have a stored crowdfundingPlatform object
  const crowdfundingPlatform = localStorage.getItem("CrowdfundingPlatform");
  if (!crowdfundingPlatform) {
    throw "Go to Admin page to set the Crowdfunding Platform Address first!";
  }

  const platform = JSON.parse(crowdfundingPlatform) as Platform;
  const creator = { address, pkh, stakeAddress, skh };

  if (!creator.address && !creator.pkh && creator.stakeAddress && !creator.skh) {
    throw "Unconnected Wallet";
  }

  // Select the wallet in Lucid
  if (!lucid.wallet()) {
    const api = await wallet.enable();
    lucid.selectWallet.fromAPI(api);
  }

  // We need some UTxO to serve as the "nonce" reference
  const utxos = await lucid.wallet().getUtxos();
  if (!utxos || !utxos.length) throw "Empty Wallet";

  // Pick the smallest UTxO
  const nonceUTxO = getShortestUTxO(utxos);
  const nonceTxHash = String(nonceUTxO.txHash);
  const nonceTxIdx = BigInt(nonceUTxO.outputIndex);

  // The on-chain script is parameterized by (platform.pkh, creator.pkh, nonceORef)
  const nonceORef = new Constr(0, [nonceTxHash, nonceTxIdx]);
  const campaignValidator: Validator = {
    type: "PlutusV3",
    script: applyParamsToScript(script.Crowdfunding, [
      platform.pkh ?? "",
      creator.pkh ?? "",
      nonceORef,
    ]),
  };

  // This policyId is effectively the same script hash as the campaignValidator
  const campaignPolicy = mintingPolicyToId(campaignValidator);
  const campaignAddress = validatorToAddress(network, campaignValidator);

  // The AssetName (hex) for your campaign state token
  const StateTokenUnit = toUnit(campaignPolicy, STATE_TOKEN.hex);
  const StateToken = { [StateTokenUnit]: 1n };

  // Our campaign data (inlined on the UTxO that holds the state token)
  const campaignDatum: CampaignDatum = {
    name: fromText(campaign.name),
    goal: campaign.goal,
    deadline: campaign.deadline,
    creator: [creator.pkh ?? "", creator.skh ?? ""],
    state: "Running",
  };

  /**
   * Per your Aiken code:
   * 
   *   type MintRedeemer {
   *       InitCampaign(CampaignDatum) = Constr(0, [CampaignDatum])
   *       SupportCampaign(BackerDatum) = Constr(1, [BackerDatum])
   *       FinishCampaign(BackerDatum)  = Constr(2, [BackerDatum])
   *   }
   *
   * So for creating a campaign, we do `InitCampaign(...) = Constr(0, [...])`.
   */
  const initCampaignRedeemer = new Constr(0, [Data.to(campaignDatum, CampaignDatum)]);

  // For the CIP-721 metadata if you choose to store it
  const CIP721metadata = {
    [campaignPolicy]: {
      [STATE_TOKEN.assetName]: {
        platform: platform.pkh ?? "",
        creator: creator.pkh ?? "",
        hash: nonceUTxO.txHash,
        index: nonceUTxO.outputIndex,
      },
    },
  };

  // Build and sign the transaction
  const now = await koios.getBlockTimeMs(); // your provider's "now" in ms
  const tx = await lucid
    .newTx()
    // We must consume the "nonce" from the campaign creator's address
    .collectFrom([nonceUTxO])
    // We mint exactly 1 state token with the "InitCampaign" redeemer
    .mintAssets(StateToken, initCampaignRedeemer)
    // Optionally attach CIP-721 metadata
    .attachMetadata(721, CIP721metadata)
    // The policy to attach is the same script
    .attach.MintingPolicy(campaignValidator)
    // We send that minted state token to our script address,
    // with the "CampaignDatum" as an inline datum (not the same as the minting redeemer).
    .payToContract(
      campaignAddress,
      {
        kind: "inline",
        value: Data.to(campaignDatum, CampaignDatum),
      },
      StateToken
    )
    // We ensure that the creation is valid from "now"
    .validFrom(now)
    .complete();

  const txHash = await submitTx(tx);

  handleSuccess(`Create Campaign TxHash: ${txHash}`);

  // Return your newly minted campaign object
  return {
    CampaignInfo: {
      id: campaignPolicy,
      platform: { pkh: platform.pkh },
      nonce: { txHash: nonceUTxO.txHash, outputIndex: nonceUTxO.outputIndex },
      validator: campaignValidator,
      address: campaignAddress,
      datum: campaignDatum,
      data: {
        name: campaign.name,
        goal: parseFloat(
          `${campaign.goal / 1_000000n}.${campaign.goal % 1_000000n}`
        ),
        deadline: new Date(parseInt(campaign.deadline.toString(), 10)),
        creator: {
          pk: keyHashToCredential(creator.pkh ?? ""),
          sk: keyHashToCredential(creator.skh ?? ""),
          address: creator.address ?? "",
        },
        backers: [],
        noDatum: [],
        support: { lovelace: 0n, ada: 0 },
        state: "Running",
      },
    },
    StateToken: {
      unit: StateTokenUnit,
      utxo: {
        txHash,
        outputIndex: 0, // The newly minted UTxO index
        address: campaignAddress,
        assets: StateToken,
        // This inline datum is the campaignDatum
        datum: Data.to(campaignDatum, CampaignDatum),
      },
    },
  };
}
