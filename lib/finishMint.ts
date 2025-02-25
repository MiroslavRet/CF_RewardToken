import {
  Constr,
  Data,
  toUnit,
  mintingPolicyToId,
  UTxO,
  // etc...
} from "@lucid-evolution/lucid";

import { SUPPORT_TOKEN, REWARD_TOKEN } from "@/config/crowdfunding";
import {
  BackerDatum,
  CampaignDatum,
} from "@/types/crowdfunding";

/**
 * Finish a single backer's portion of the campaign by
 * burning their support token(s) and minting reward token(s).
 */
export async function finishCampaignForBacker(
  { lucid, wallet, address }: WalletConnection,
  campaign: CampaignUTxO,
  backerDatum: BackerDatum
): Promise<string> {
  if (!lucid) throw "Uninitialized Lucid";
  if (!wallet) throw "Disconnected Wallet";
  if (!address) throw "No connected wallet address";
  if (!campaign) throw "No campaign provided";

  // The campaign's validator also serves as the MintingPolicy.
  const { CampaignInfo } = campaign;
  const campaignPolicyId = mintingPolicyToId(CampaignInfo.validator);

  // Build the support token unit + reward token unit
  const supportTokenUnit = toUnit(campaignPolicyId, SUPPORT_TOKEN.hex);
  const rewardTokenUnit  = toUnit(campaignPolicyId, REWARD_TOKEN.hex);

  // We need to find the backer's "Support" UTxO in the script.
  //   - The script address is `CampaignInfo.address`.
  //   - The inline datum must match the `BackerDatum`.
  const backerDatumPlutus = Data.to(backerDatum, BackerDatum);
  const scriptUtxos = await lucid.utxosAt(CampaignInfo.address);
  
  // Find the user’s support UTxO (by matching the inline datum)
  const userSupportUtxo = scriptUtxos.find(utxo => {
    if (!utxo.datum) return false;
    try {
      return Data.equal(utxo.datum, backerDatumPlutus);
    } catch {
      return false;
    }
  });

  if (!userSupportUtxo) {
    throw "No script UTxO found with matching BackerDatum for this backer.";
  }

  // How many support tokens does it have? (Likely 1 if your logic is 1 token/UTxO.)
  // But it can be any quantity that was minted for this backer.
  const supportTokenQty = userSupportUtxo.assets[supportTokenUnit] ?? 0n;
  if (supportTokenQty <= 0n) {
    throw "No support tokens found in this backer’s UTxO";
  }

  // The "FinishCampaign(backer_datum)" redeemer = Constr(2, [backerDatum])
  const finishRedeemer = new Constr(2, [Data.to(backerDatum, BackerDatum)]);

  // We want to burn the same quantity of "support tokens" and
  // mint the same quantity of "reward tokens".
  // So the net minted assets are:
  //   { [rewardTokenUnit]: +supportTokenQty, [supportTokenUnit]: -supportTokenQty }
  const mintedAssets = {
    [rewardTokenUnit]: supportTokenQty,
    [supportTokenUnit]: -supportTokenQty,
  };

  // Build the transaction
  // 1) Collect the backer's UTxO from the script
  // 2) Mint & burn the tokens with "FinishCampaign" redeemer
  // 3) Attach the campaignValidator as MintingPolicy
  // 4) Send the newly minted reward tokens to backer’s address
  const tx = await lucid
    .newTx()
    .collectFrom([userSupportUtxo]) // gather the user's support UTxO
    .mintAssets(mintedAssets, finishRedeemer)
    .attach.MintingPolicy(CampaignInfo.validator)
    .payToAddress(address, {
      [rewardTokenUnit]: supportTokenQty,
    })
    .complete();

  // Sign & submit
  const signedTx = await tx.sign().complete();
  const txHash = await signedTx.submit();

  // Optionally show success message
  console.log(`FinishCampaign TxHash: ${txHash}`);

  return txHash;
}
