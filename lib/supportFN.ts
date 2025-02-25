export async function supportCampaign(
  { lucid, wallet, pkh, skh, address }: WalletConnection,
  campaign?: CampaignUTxO,
  supportADA?: string
): Promise<CampaignUTxO> {
  if (!lucid) throw "Uninitialized Lucid";
  if (!wallet) throw "Disconnected Wallet";
  if (!address) throw "No Address";
  if (!campaign) throw "No Campaign";

  const { CampaignInfo } = campaign;

  // The "BackerDatum" for the inline datum
  const backerPKH = pkh ?? "";
  const backerSKH = skh ?? "";
  const backerDatum: BackerDatum = [backerPKH, backerSKH];

  // Convert the backer datum to Plutus data for the output inline datum
  const inlineDatum = Data.to(backerDatum, BackerDatum);

  // The user’s support as Lovelace
  const support = supportADA ?? "0";
  const ada = parseFloat(support);
  const lovelace = adaToLovelace(support);

  // Select the user’s wallet if not already
  if (!lucid.wallet()) {
    const api = await wallet.enable();
    lucid.selectWallet.fromAPI(api);
  }

  // Minting policy ID is the same as the campaign’s script hash
  const campaignPolicy = mintingPolicyToId(CampaignInfo.validator);

  // Build a “Support Token” unit, e.g. "PolicyId + SUPPORT_TOKEN.hex"
  const supportTokenUnit = toUnit(campaignPolicy, SUPPORT_TOKEN.hex);

  // Exactly 1 support token
  const mintSupportTokens = { [supportTokenUnit]: 1n };

  // The redeemer must be "SupportCampaign(backer_datum)" => Constr(1, [...])
  const supportRedeemer = new Constr(1, [Data.to(backerDatum, BackerDatum)]);

  // Build, sign and submit the Tx
  const tx = await lucid
    .newTx()
    // Mint the support token with your "SupportCampaign" redeemer
    .mintAssets(mintSupportTokens, supportRedeemer)
    // Attach the same script used for the campaign
    .attach.MintingPolicy(CampaignInfo.validator)

    // Send the user’s Lovelace to the campaign script with an inline BackerDatum
    .payToContract(CampaignInfo.address, { kind: "inline", value: inlineDatum }, { lovelace })

    // (Optional) If you want the user to receive the minted token in their wallet:
    .payToAddress(address, mintSupportTokens)

    // Complete
    .complete();

  const txHash = await (await tx.sign().complete()).submit();

  handleSuccess(`Support Campaign TxHash: ${txHash}`);

  // Finally, update your local in-memory “campaign” object with the new backer
  return {
    ...campaign,
    CampaignInfo: {
      ...CampaignInfo,
      data: {
        ...CampaignInfo.data,
        backers: [
          ...CampaignInfo.data.backers,
          {
            address,
            pkh: backerPKH,
            skh: backerSKH,
            pk: keyHashToCredential(backerPKH),
            sk: keyHashToCredential(backerSKH),
            support: { ada, lovelace },
            utxo: {
              txHash,
              outputIndex: 0,
              address: CampaignInfo.address,
              assets: { lovelace },
              datum: inlineDatum,
            },
          },
        ],
        support: {
          ada: CampaignInfo.data.support.ada + ada,
          lovelace: CampaignInfo.data.support.lovelace + lovelace,
        },
      },
    },
  };
}
