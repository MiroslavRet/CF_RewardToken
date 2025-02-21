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
  import { STATE_TOKEN, SUPPORT_TOKEN, REWARD_TOKEN } from "@/config/crowdfunding";
  import {
    BackerDatum,
    CampaignActionRedeemer,
    CampaignDatum,
    CampaignState,
  } from "@/types/crowdfunding";
  import { Platform } from "@/types/platform";
  
  async function submitTx(tx: TxSignBuilder) {
    const txSigned = await tx.sign.withWallet().complete();
    const txHash = await txSigned.submit();
  
    return txHash;
  }
  
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
  
  export async function queryCampaign(
    { lucid, wallet }: WalletConnection,
    campaignPolicyId: PolicyId,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Uninitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
  
    //#region Campaign Info
    const campaign = await koios.getTokenMetadata(campaignPolicyId);
    const { platform, creator, hash, index } =
      campaign[campaignPolicyId].STATE_TOKEN;
    const StateTokenUnit = toUnit(campaignPolicyId, STATE_TOKEN.hex); // `${PolicyID}${AssetName}`
    const SupportTokenUnit = toUnit(campaignPolicyId, SUPPORT_TOKEN.hex); // `${PolicyID}${AssetName}`
    const RewardTokenUnit = toUnit(campaignPolicyId, REWARD_TOKEN.hex); // `${PolicyID}${AssetName}`
  
    const nonceTxHash = String(hash);
    const nonceTxIdx = BigInt(index);
    const nonceORef = new Constr(0, [nonceTxHash, nonceTxIdx]);
  
    const campaignValidator: Validator = {
      type: "PlutusV3",
      script: applyParamsToScript(script.Crowdfunding, [
        platform,
        creator,
        nonceORef,
      ]),
    };
    const campaignAddress = validatorToAddress(network, campaignValidator);
    //#endregion
  
    const [StateTokenUTxO] = await lucid.utxosAtWithUnit(
      campaignAddress,
      StateTokenUnit,
    );
  
    if (!StateTokenUTxO.datum) throw "No Datum";

    const [SupportTokenUTxO] = await lucid.utxosAtWithUnit(
        campaignAddress,
        SupportTokenUnit,
      );
    
      if (!StateTokenUTxO.datum) throw "No Datum";


      const [RewardTokenUTxO] = await lucid.utxosAtWithUnit(
        campaignAddress,
        RewardTokenUnit,
      );
    
      if (!StateTokenUTxO.datum) throw "No Datum";
  
    const campaignDatum = Data.from(StateTokenUTxO.datum, CampaignDatum);
  
    //#region Creator Info
    const [creatorPkh, creatorSkh] = campaignDatum.creator;
    const creatorPk = keyHashToCredential(creatorPkh);
    const creatorSk = keyHashToCredential(creatorSkh);
    const creatorAddress = credentialToAddress(network, creatorPk, creatorSk);
    //#endregion
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
  
      lucid.selectWallet.fromAPI(api);
    }
  
    //#region Backers Info
    const utxos = await lucid.utxosAt(campaignAddress);
    const backers: BackerUTxO[] = [];
    const noDatumUTXOs: UTxO[] = [];
  
    for (const utxo of utxos) {
      if (!utxo.datum) {
        noDatumUTXOs.push(utxo);
      } else {
        try {
          const [pkh, skh] = Data.from(utxo.datum, BackerDatum);
          const backerPk = keyHashToCredential(pkh);
          const backerSk = skh ? keyHashToCredential(skh) : undefined;
          const backerAddress = credentialToAddress(network, backerPk, backerSk);
  
          const supportLovelace = utxo.assets.lovelace;
          const supportToken = utxo.assets.lovelace;
          const supportADA = parseFloat(
            `${supportLovelace / 1_000000n}.${supportLovelace % 1_000000n}`,
          );
  
          backers.push({
            utxo,
            pkh,
            skh,
            pk: backerPk,
            sk: backerSk,
            address: backerAddress,
            support: { lovelace: supportLovelace, ada: supportADA },
          });
        } catch {
          continue;
        }
      }
    }
    //#endregion
  
    const supportLovelace = backers.reduce(
      (sum, { support }) => sum + support.lovelace,
      0n,
    );
    const supportADA = parseFloat(
      `${supportLovelace / 1_000000n}.${supportLovelace % 1_000000n}`,
    );
    
    return {
      CampaignInfo: {
        id: campaignPolicyId,
        platform: { pkh: platform },
        nonce: { txHash: hash, outputIndex: index },
        validator: campaignValidator,
        address: campaignAddress,
        datum: campaignDatum,
        data: {
          name: toText(campaignDatum.name),
          goal: parseFloat(
            `${campaignDatum.goal / 1_000000n}.${campaignDatum.goal % 1_000000n}`,
          ),
          deadline: new Date(parseInt(campaignDatum.deadline.toString())),
          creator: { pk: creatorPk, sk: creatorSk, address: creatorAddress },
          backers,
          noDatum: noDatumUTXOs,
          support: { lovelace: supportLovelace, ada: supportADA },
          state: campaignDatum.state,
        },
      },
      StateToken: {
        unit: StateTokenUnit,
        utxo: StateTokenUTxO,
      },
      SupportToken: {
        unit: SupportTokenUnit,
        utxo: SupportTokenUTxO,
      },
      RewardToken: {
        unit: RewardTokenUnit,
        utxo: RewardTokenUTxO,
      },
    };
  }
  
  export async function createCampaign(
    { lucid, wallet, address, pkh, stakeAddress, skh }: WalletConnection,
    campaign: { name: string; goal: Lovelace; deadline: bigint },
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
  
    const crowdfundingPlatform = localStorage.getItem("CrowdfundingPlatform");
  
    if (!crowdfundingPlatform)
      throw "Go to Admin page to set the Crowdfunding Platform Address first!";
  
    const platform = JSON.parse(crowdfundingPlatform); // Platform { address, pkh, stakeAddress, skh }
    const creator = { address, pkh, stakeAddress, skh };
  
    if (!creator.address && !creator.pkh && creator.stakeAddress && !creator.skh)
      throw "Unconnected Wallet";
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    const utxos = await lucid.wallet().getUtxos();
  
    if (!utxos || !utxos.length) throw "Empty Wallet";
  
    const nonceUTxO = getShortestUTxO(utxos);
    const nonceTxHash = String(nonceUTxO.txHash);
    const nonceTxIdx = BigInt(nonceUTxO.outputIndex);
    const nonceORef = new Constr(0, [nonceTxHash, nonceTxIdx]);
  
    const campaignValidator: Validator = {
      type: "PlutusV3",
      script: applyParamsToScript(script.Crowdfunding, [
        platform.pkh ?? "",
        creator.pkh ?? "",
        nonceORef,
      ]),
    };
    const campaignPolicy = mintingPolicyToId(campaignValidator);
    const campaignAddress = validatorToAddress(network, campaignValidator);
  
    const StateTokenUnit = toUnit(campaignPolicy, STATE_TOKEN.hex); // `${PolicyID}${AssetName}`
    const StateToken = { [StateTokenUnit]: 1n };
  
    const campaignDatum: CampaignDatum = {
      name: fromText(campaign.name),
      goal: campaign.goal,
      deadline: campaign.deadline,
      creator: [creator.pkh ?? "", creator.skh ?? ""],
      state: "Running",
    };
    const mintRedeemer = Data.to(campaignDatum, CampaignDatum);
    const initCampaign = new Constr(0, [campaignDatum]);
  
    const now = await koios.getBlockTimeMs();
  
    const tx = await lucid
      .newTx()
      .collectFrom([nonceUTxO])
      .mintAssets(StateToken, initCampaign)
      .attachMetadata(721, {
        [campaignPolicy]: {
          [STATE_TOKEN.assetName]: {
            platform: platform.pkh ?? "",
            creator: creator.pkh ?? "",
            hash: nonceUTxO.txHash,
            index: nonceUTxO.outputIndex,
          },
        },
      })
      .attach.MintingPolicy(campaignValidator)
      .pay.ToContract(
        campaignAddress,
        { kind: "inline", value: initCampaign },
        StateToken,
      )
      .validFrom(now)
      .complete({ localUPLCEval: false });
  
    const txHash = await submitTx(tx);
  
    handleSuccess(`Create Campaign TxHash: ${txHash}`);
  
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
            `${campaign.goal / 1_000000n}.${campaign.goal % 1_000000n}`,
          ),
          deadline: new Date(parseInt(campaign.deadline.toString())),
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
          outputIndex: 0,
          address: campaignAddress,
          assets: StateToken,
          datum: mintRedeemer,
        },
      },
    };
  }



  export async function finishMintBurn(
    { lucid, wallet, address }: WalletConnection,
    campaign?: CampaignUTxO,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Uninitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!address) throw "No Address";
    if (!campaign) throw "No Campaign";


  
    const { CampaignInfo } = campaign;
    
    const validator: Validator = CampaignInfo.validator;
    const campaignAddress = CampaignInfo.address;
    const campaignPolicy = mintingPolicyToId(validator);
    const backers = CampaignInfo.data.backers;

    const SupportTokenUnit = toUnit(campaignPolicy, SUPPORT_TOKEN.hex);

    const [SupportToken] = await lucid.utxosAtWithUnit(
        CampaignInfo.address,
        SupportTokenUnit,
      );


  
    const backersupportTokenUtxos = backers.map(({ utxo }) => {
      const amount = utxo.assets[SupportTokenUnit] ?? 0n;
      totalSupportTokensToBurn += amount;
      return utxo;
  })
  .filter(({ assets }) => assets[SupportTokenUnit] > 0n);

    let totalSupportTokensToBurn = 0n;
    
    const SupportTokenToBurn = { [SupportTokenUnit]: -totalSupportTokensToBurn };
  
    const finishMintBurnRedeemer = Data.to(new Constr(2, [/* e.g. [backerPk, backerSkh] or [] */]));
    
    
    const RewardTokenUnit = toUnit(campaignPolicy, REWARD_TOKEN.hex);
  
    const RewardToken = { [RewardTokenUnit]: BigInt(backers.length) }; 
    const backerUtxos = backers.map(({ utxo }) => utxo);
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    let newTx = lucid
      .newTx()
      .collectFrom(
              [CampaignInfo.data.backers.map(({ utxo }) => utxo)],
              finishMintBurnRedeemer,
            ) 
      .collectFrom(backersupportTokenUtxos, finishMintBurnRedeemer)
      .attachSpendingValidator(validator)
      .mintAssets(SupportTokenToBurn, finishMintBurnRedeemer)
      .mintAssets(RewardToken, finishMintBurnRedeemer)
      .attachMetadata(721, {
        [campaignPolicy]: {
          [REWARD_TOKEN.assetName]: {
            platform: CampaignInfo.platform?.pkh ?? "",
            creator: CampaignInfo.data.creator.pk ?? "",
            hash: CampaignInfo.nonce.txHash,
            index: Number(CampaignInfo.nonce.outputIndex),
          },
        },
      })
      .attachMintingPolicy(validator);
    for (const { address: backerAddress } of backers) {
      newTx = newTx.payToAddress(backerAddress, {
        [RewardTokenUnit]: 1n,
      });
    }
  
    const tx = await newTx.complete({ localUPLCEval: false });
    const txHash = await submitTx(tx);
  
    handleSuccess(`Finish & Mint Rewards TxHash: ${txHash}`);
  
    return {
      CampaignInfo: {
        ...CampaignInfo,
        datum: {
          ...CampaignInfo.datum,
        },
        data: {
          ...CampaignInfo.data,
        },
      },
      StateToken: campaign.StateToken,
  
      BurnedSupportToken: {
        unit: SupportTokenUnit,
        quantity: totalSupportTokensToBurn, // burned
      },
  
      RewardToken: {
        unit: RewardTokenUnit,
        quantity: BigInt(backers.length),
        distributedTo: backers.map(({ address: bAddr }) => bAddr),
      },
    };
  }


  
  export async function cancelCampaign(
    { lucid, wallet }: WalletConnection,
    campaign?: CampaignUTxO,
    platform?: Platform,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!campaign) throw "No Campaign";
  
    const { CampaignInfo, StateToken } = campaign;
  
    const [StateTokenUTxO] = await lucid.utxosAtWithUnit(
      CampaignInfo.address,
      StateToken.unit,
    );
  
    const newState: CampaignState = "Cancelled";
    const updatedDatum: CampaignDatum = {
      ...CampaignInfo.datum,
      state: newState,
    };
    const datum = Data.to(updatedDatum, CampaignDatum);
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    let newTx = lucid
      .newTx()
      .collectFrom([StateTokenUTxO], CampaignActionRedeemer.Cancel) // TxInput: StateToken UTxO
      .attach.SpendingValidator(CampaignInfo.validator)
      .pay.ToContract(
        CampaignInfo.address,
        { kind: "inline", value: datum },
        { [StateToken.unit]: 1n },
      ); // TxOutput: Resend StateToken
  
    //#region Either executed by the crowdfunding platform, or by the campaign creator
    if (platform) {
      // signed by the crowdfunding platform
      // must be after deadline
      const now = await koios.getBlockTimeMs();
  
      newTx = newTx.addSigner(platform.address).validFrom(now);
    } else {
      // signed by the campaign creator
      newTx = newTx.addSigner(CampaignInfo.data.creator.address);
    }
    //#endregion
  
    const tx = await newTx.complete({ localUPLCEval: false });
  
    const txHash = await submitTx(tx);
  
    handleSuccess(`Cancel Campaign TxHash: ${txHash}`);
  
    return {
      CampaignInfo: {
        ...CampaignInfo,
        datum: updatedDatum,
        data: { ...CampaignInfo.data, state: newState },
      },
      StateToken: {
        ...StateToken,
        utxo: { ...StateTokenUTxO, txHash, outputIndex: 0, datum },
      },
    };
  }
  
  export async function supportCampaign(
    { lucid, wallet, pkh, skh, address }: WalletConnection,
    campaign?: CampaignUTxO,
    supportADA?: string,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!address) throw "No Address";
    if (!campaign) throw "No Campaign";
  
    // -- Pull out the existing campaign info from the `campaign` object --
    const { CampaignInfo } = campaign;
  
    // -- Setup the backer datum --
    const backerPKH = pkh ?? "";
    const backerSKH = skh ?? "";
    const backer: BackerDatum = [backerPKH, backerSKH];
    const backerDatum = Data.to(backer, BackerDatum);
  
    // -- Convert input support into Lovelace --
    const support = supportADA ?? "0";
    const ada = parseFloat(support);
    const lovelace = adaToLovelace(support);
  
    // -- Retrieve the already-constructed campaign validator & address --
    const campaignValidator: Validator = CampaignInfo.validator;
    const campaignAddress = CampaignInfo.address;
  
    // -- Derive the policy ID from the existing validator --
    const campaignPolicy = mintingPolicyToId(campaignValidator);
  
    // -- Prepare the support token to be minted --
    const SupportTokenUnit = toUnit(campaignPolicy, SUPPORT_TOKEN.hex); // e.g. `${policyId}${assetName}`
    const SupportToken = { [SupportTokenUnit]: 1n };
  
    // -- Create the 'SupportCampaign' redeemer (constructor index = 1) --
    const supportRedeemer = Data.to(new Constr(1, [backer]));
  
    // -- Ensure we have an active wallet in Lucid --
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    // -- Build the transaction --
    const tx = await lucid
      .newTx()
      // 1. Pay ADA + BackerDatum to the existing campaign address
      .payToContract(
        campaignAddress,
        { kind: "inline", value: backerDatum },
        { lovelace }
      )
      // 2. Mint the support token (with the 'SupportCampaign' redeemer)
      .mintAssets(SupportToken, supportRedeemer)
      // 3. Attach optional NFT metadata
      .attachMetadata(721, {
        [campaignPolicy]: {
          [SUPPORT_TOKEN.assetName]: {
            platform: CampaignInfo.platform?.pkh ?? "",
            creator: CampaignInfo.data.creator.pk ?? "",
            hash: CampaignInfo.nonce.txHash,
            index: Number(CampaignInfo.nonce.outputIndex),
          },
        },
      })
      // 4. Attach the minting policy (so the script can validate the mint)
      .attachMintingPolicy(campaignValidator)
      // 5. Send the minted support token (plus backer datum) again to the campaign address
      .payToContract(
        campaignAddress,
        { kind: "inline", value: backerDatum },
        SupportToken
      )
      .complete({ localUPLCEval: false });
  
    // -- Submit the transaction --
    const txHash = await submitTx(tx);
    handleSuccess(`Support Campaign TxHash: ${txHash}`);
  
    // -- Update our `CampaignUTxO` model with the new backer data --
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
              skh: backerPKH,
              pk: keyHashToCredential(backerPKH),
              sk: keyHashToCredential(backerSKH),
              support: { ada, lovelace },
              utxo: {
                txHash,
                outputIndex: 0,
                address: CampaignInfo.address,
                assets: { lovelace },
                backerDatum,
              },
            },
          ],
          support: {
            ada: CampaignInfo.data.support.ada + ada,
            lovelace: CampaignInfo.data.support.lovelace + lovelace,
          },
        },
      },
      SupportToken: {
        unit: SupportTokenUnit,
        utxo: {
          txHash,
          outputIndex: 1,
          address: campaignAddress,
          assets: SupportToken,
          datum: supportRedeemer,
        },
      },
    };
  }
  
  export async function finishCampaign(
    { lucid, wallet }: WalletConnection,
    campaign?: CampaignUTxO,
    platform?: Platform,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!campaign) throw "No Campaign";
  
    const { CampaignInfo, StateToken } = campaign;
  
    const [StateTokenUTxO] = await lucid.utxosAtWithUnit(
      CampaignInfo.address,
      StateToken.unit,
    );
  
    const newState: CampaignState = "Finished";
    const updatedDatum: CampaignDatum = {
      ...CampaignInfo.datum,
      state: newState,
    };
    const datum = Data.to(updatedDatum, CampaignDatum);
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    let newTx = lucid
      .newTx()
      .readFrom([CampaignInfo.data.backers.map(({ utxo }) => utxo)])
      .collectFrom(
        [StateTokenUTxO],
        CampaignActionRedeemer.Finish,
      ) // TxInputs: StateToken UTxO & Support
      .attach.SpendingValidator(CampaignInfo.validator)
      .pay.ToContract(
        CampaignInfo.address,
        { kind: "inline", value: datum },
        { [StateToken.unit]: 1n },
      ) // TxOutput: Resend StateToken
  
    //#region Either executed by the crowdfunding platform, or by the campaign creator
    if (platform) {
      // signed by the crowdfunding platform
      // must be after deadline
      const now = await koios.getBlockTimeMs();
  
      newTx = newTx.addSigner(platform.address).validFrom(now);
    } else {
      // signed by the campaign creator
      newTx = newTx.addSigner(CampaignInfo.data.creator.address);
    }
    //#endregion
  
    const tx = await newTx.complete({ localUPLCEval: false });
  
    const txHash = await submitTx(tx);
  
    handleSuccess(`Finish Campaign TxHash: ${txHash}`);
  
    return {
      CampaignInfo: {
        ...CampaignInfo,
        datum: updatedDatum,
        data: {
          ...CampaignInfo.data,
          state: newState,
        },
      },
      StateToken: {
        ...StateToken,
        utxo: { ...StateTokenUTxO, txHash, outputIndex: 0, datum },
      },
    };
  }
  
  export async function refundCampaign(
    { lucid, wallet, address }: WalletConnection,
    campaign?: CampaignUTxO,
    platform?: Platform,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!address) throw "No Address";
    if (!campaign) throw "No Campaign";
  
    const { CampaignInfo, StateToken } = campaign;
  
    if (!CampaignInfo.data.support.ada) throw "Nothing to Refund";
  
    const currentBacker = platform
      ? CampaignInfo.data.backers
      : CampaignInfo.data.backers.filter((backer) => backer.address === address);
    const backerADA = platform
      ? CampaignInfo.data.support.ada
      : currentBacker.reduce((sum, { support }) => sum + support.ada, 0);
  
    if (!backerADA)
      throw "You did not support this campaign, or you're already refunded. Incorrect? Contact us!";
    const backerLovelace = platform
      ? CampaignInfo.data.support.lovelace
      : adaToLovelace(`${backerADA}`);
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    let newTx = lucid
      .newTx()
      .readFrom([StateToken.utxo]) // TxRefInput: StateToken UTxO
      .collectFrom(
        currentBacker.map(({ utxo }) => utxo),
        CampaignActionRedeemer.Refund,
      ) // TxInputs: Backer support UTxO(s)
      .attach.SpendingValidator(CampaignInfo.validator);
  
    for (const { address, support } of currentBacker) {
      newTx = newTx.pay.ToAddress(address, { lovelace: support.lovelace }); // TxOutput: Send support back
    }
  
    const tx = await newTx.complete({ localUPLCEval: false });
  
    const txHash = await submitTx(tx);
  
    handleSuccess(`Refund Campaign TxHash: ${txHash}`);
  
    return {
      ...campaign,
      CampaignInfo: {
        ...CampaignInfo,
        data: {
          ...CampaignInfo.data,
          backers: platform
            ? []
            : CampaignInfo.data.backers.filter(
                (backer) => backer.address !== address,
              ),
          support: {
            ada: platform ? 0 : CampaignInfo.data.support.ada - backerADA,
            lovelace: platform
              ? 0n
              : CampaignInfo.data.support.lovelace - backerLovelace,
          },
        },
      },
    };
  }

  export async function collectSupport(
    { lucid, wallet, address }: WalletConnection,
    campaign?: CampaignUTxO,
    platform?: Platform
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!address) throw "No Address";
    if (!campaign) throw "No Campaign";
  
    const { CampaignInfo, StateToken } = campaign;
  
    if (!CampaignInfo.data.support.ada) throw "Nothing to Collect";
  
    const currentBacker = platform
      ? CampaignInfo.data.backers
      : CampaignInfo.data.backers.filter((backer) => backer.address === address);
  
    const backerADA = platform
      ? CampaignInfo.data.support.ada
      : currentBacker.reduce((sum, { support }) => sum + support.ada, 0);
  
    if (!backerADA) {
      throw "You did not support this campaign or there's nothing to collect. Incorrect? Contact us!";
    }
  
    const backerLovelace = platform
      ? CampaignInfo.data.support.lovelace
      : adaToLovelace(`${backerADA}`);
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    let newTx = lucid
      .newTx()
      .readFrom([StateToken.utxo])
      .collectFrom(
        currentBacker.map(({ utxo }) => utxo),
        CampaignActionRedeemer.Collect // or rename in your on-chain logic
      )
      .attachSpendingValidator(CampaignInfo.validator);
  
    newTx = newTx.pay.ToAddress(CampaignInfo.data.creator.address, {
      lovelace: backerLovelace,
    });
  
    const tx = await newTx.complete({ localUPLCEval: false });
    const txHash = await submitTx(tx);
  
    handleSuccess(`Collect Support TxHash: ${txHash}`);
    return {
      ...campaign,
      CollectedSupport: {
        txHash,
        to: CampaignInfo.data.creator.address,
        ada: backerADA,
        lovelace: backerLovelace,
      },
      CampaignInfo: {
        ...CampaignInfo,
        data: {
          ...CampaignInfo.data,
          backers: platform
            ? []
            : CampaignInfo.data.backers.filter((b) => b.address !== address),
          support: {
            ada: platform
              ? 0
              : CampaignInfo.data.support.ada - backerADA,
            lovelace: platform
              ? 0n
              : CampaignInfo.data.support.lovelace - backerLovelace,
          },
        },
      },
    };
  }
  
  
  export async function claimNoDatumUTXOs(
    { lucid, wallet, address }: WalletConnection,
    campaign: CampaignUTxO,
    utxo?: UTxO,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!address) throw "No Address";
  
    const { CampaignInfo, StateToken } = campaign;
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    const tx = await lucid
      .newTx()
      .readFrom([StateToken.utxo])
      .collectFrom(utxo ? [utxo] : CampaignInfo.data.noDatum, Data.void())
      .attach.SpendingValidator(CampaignInfo.validator)
      .addSigner(address)
      .complete({ localUPLCEval: false });
  
    const txHash = await submitTx(tx);
  
    handleSuccess(`Refund Campaign TxHash: ${txHash}`);
  
    return {
      ...campaign,
      CampaignInfo: {
        ...CampaignInfo,
        data: {
          ...CampaignInfo.data,
          noDatum: utxo
            ? CampaignInfo.data.noDatum.filter(
                ({ txHash, outputIndex }) =>
                  txHash !== utxo.txHash || outputIndex != utxo.outputIndex,
              )
            : [],
        },
      },
    };
  }
  
  type HackAction = {
    action: "cancel" | "finish" | "refund" | "rerun" | "claimNoDatumUTXOs";
    params: Record<string, any>;
  };
  
  export async function hackCampaign(
    { lucid, wallet, address }: WalletConnection,
    { action, params }: HackAction,
    campaign: CampaignUTxO,
  ): Promise<CampaignUTxO> {
    if (!lucid) throw "Unitialized Lucid";
    if (!wallet) throw "Disconnected Wallet";
    if (!campaign) throw "No Campaign";
  
    const { CampaignInfo, StateToken } = campaign;
  
    const [StateTokenUTxO] = await lucid.utxosAtWithUnit(
      CampaignInfo.address,
      StateToken.unit,
    );
  
    if (!lucid.wallet()) {
      const api = await wallet.enable();
      lucid.selectWallet.fromAPI(api);
    }
  
    switch (action) {
      case "cancel": {
        const { validFrom, addSigner, payToContract } = params;
  
        const newState: CampaignState = "Cancelled";
        const updatedDatum: CampaignDatum = {
          ...CampaignInfo.datum,
          state: newState,
        };
        const datum = Data.to(updatedDatum, CampaignDatum);
  
        let newTx = lucid
          .newTx()
          .collectFrom([StateTokenUTxO], CampaignActionRedeemer.Cancel)
          .attach.SpendingValidator(CampaignInfo.validator);
  
        if (payToContract.yes) {
          newTx = newTx.pay.ToContract(
            payToContract.address || CampaignInfo.address,
            { kind: "inline", value: datum },
            { [StateToken.unit]: 1n },
          );
        }
  
        if (addSigner.yes) {
          newTx = newTx.addSigner(addSigner.address || address);
        }
  
        if (validFrom.yes) {
          newTx = newTx.validFrom(
            validFrom.unixTime || (await koios.getBlockTimeMs()),
          );
        }
  
        const tx = await newTx.complete({ localUPLCEval: false });
  
        const txHash = await submitTx(tx);
  
        handleSuccess(`Cancel Campaign TxHash: ${txHash}`);
  
        return {
          CampaignInfo: {
            ...CampaignInfo,
            datum: updatedDatum,
            data: { ...CampaignInfo.data, state: newState },
          },
          StateToken: {
            ...StateToken,
            utxo: { ...StateTokenUTxO, txHash, outputIndex: 0, datum },
          },
        };
      }
  
      case "finish": {
        const { addSigner, payToContract, payToAddress } = params;
  
        const newState: CampaignState = "Finished";
        const updatedDatum: CampaignDatum = {
          ...CampaignInfo.datum,
          state: newState,
        };
        const datum = Data.to(updatedDatum, CampaignDatum);
  
        let newTx = lucid
          .newTx()
          .collectFrom(
            [
              StateTokenUTxO,
              ...CampaignInfo.data.backers.map(({ utxo }) => utxo),
            ],
            CampaignActionRedeemer.Finish,
          )
          .attach.SpendingValidator(CampaignInfo.validator);
  
        if (payToAddress.yes) {
          newTx = newTx.pay.ToAddress(
            payToAddress.address || CampaignInfo.data.creator.address,
            {
              lovelace:
                payToAddress.lovelace && payToAddress.lovelace > 0n
                  ? payToAddress.lovelace
                  : CampaignInfo.data.support.lovelace,
            },
          );
        }
  
        if (payToContract.yes) {
          newTx = newTx.pay.ToContract(
            payToContract.address || CampaignInfo.address,
            { kind: "inline", value: datum },
            { [StateToken.unit]: 1n },
          );
        }
  
        if (addSigner.yes) {
          newTx = newTx.addSigner(addSigner.address || address);
        }
  
        const tx = await newTx.complete({ localUPLCEval: false });
  
        const txHash = await submitTx(tx);
  
        handleSuccess(`Finish Campaign TxHash: ${txHash}`);
  
        return {
          CampaignInfo: {
            ...CampaignInfo,
            datum: updatedDatum,
            data: {
              ...CampaignInfo.data,
              state: newState,
              backers: [],
              support: { ada: 0, lovelace: 0n },
            },
          },
          StateToken: {
            ...StateToken,
            utxo: { ...StateTokenUTxO, txHash, outputIndex: 0, datum },
          },
        };
      }
  
      case "refund": {
        const { payToAddress } = params;
  
        if (!CampaignInfo.data.support.ada) throw "Nothing to Refund";
  
        let newTx = lucid
          .newTx()
          .readFrom([StateToken.utxo])
          .collectFrom(
            CampaignInfo.data.backers.map(({ utxo }) => utxo),
            CampaignActionRedeemer.Refund,
          )
          .attach.SpendingValidator(CampaignInfo.validator);
  
        if (payToAddress.yes) {
          for (const { address, support } of CampaignInfo.data.backers) {
            newTx = newTx.pay.ToAddress(payToAddress.address || address, {
              lovelace: support.lovelace,
            });
          }
        }
  
        const tx = await newTx.complete({ localUPLCEval: false });
  
        const txHash = await submitTx(tx);
  
        handleSuccess(`Refund Campaign TxHash: ${txHash}`);
  
        return {
          ...campaign,
          CampaignInfo: {
            ...CampaignInfo,
            data: {
              ...CampaignInfo.data,
              backers: [],
              support: { ada: 0, lovelace: 0n },
            },
          },
        };
      }
  
      case "rerun": {
        const { constr, addSigner } = params;
  
        const newState: CampaignState = "Running";
        const updatedDatum: CampaignDatum = {
          ...CampaignInfo.datum,
          state: newState,
        };
        const datum = Data.to(updatedDatum, CampaignDatum);
  
        let newTx = lucid
          .newTx()
          .collectFrom(
            [StateTokenUTxO],
            constr.yes ? Data.to(new Constr(constr.index ?? 3, [])) : undefined,
          )
          .attach.SpendingValidator(CampaignInfo.validator)
          .pay.ToContract(
            CampaignInfo.address,
            { kind: "inline", value: datum },
            { [StateToken.unit]: 1n },
          );
  
        if (addSigner.yes) {
          newTx = newTx.addSigner(addSigner.address || address);
        }
  
        const tx = await newTx.complete({ localUPLCEval: false });
  
        const txHash = await submitTx(tx);
  
        handleSuccess(`Rerun Campaign TxHash: ${txHash}`);
  
        return {
          CampaignInfo: {
            ...CampaignInfo,
            datum: updatedDatum,
            data: { ...CampaignInfo.data, state: newState },
          },
          StateToken: {
            ...StateToken,
            utxo: { ...StateTokenUTxO, txHash, outputIndex: 0, datum },
          },
        };
      }
  
      case "claimNoDatumUTXOs": {
        const { outRef, addSigner } = params;
  
        let newTx = lucid
          .newTx()
          .readFrom([StateToken.utxo])
          .collectFrom(
            outRef.yes
              ? await lucid.utxosByOutRef([
                  { txHash: outRef.txHash, outputIndex: outRef.outputIndex },
                ])
              : CampaignInfo.data.noDatum,
            Data.void(),
          )
          .attach.SpendingValidator(CampaignInfo.validator);
  
        if (addSigner.yes) {
          newTx = newTx.addSigner(addSigner.address || address);
        }
  
        const tx = await newTx.complete({ localUPLCEval: false });
  
        const txHash = await submitTx(tx);
  
        handleSuccess(`Refund Campaign TxHash: ${txHash}`);
  
        return {
          ...campaign,
          CampaignInfo: {
            ...CampaignInfo,
            data: {
              ...CampaignInfo.data,
              noDatum: outRef.yes
                ? CampaignInfo.data.noDatum.filter(
                    ({ txHash, outputIndex }) =>
                      txHash !== outRef.txHash ||
                      outputIndex != outRef.outputIndex,
                  )
                : [],
            },
          },
        };
      }
  
      default:
        throw "Invalid Action";
    }
  }


//////////////////////////////////////////////////////////// collect Support And Reward  ////////////////////////////////////////////////////////////

export async function collectSupportAndReward(
  { lucid, wallet, address }: WalletConnection,
  campaign?: CampaignUTxO,
  platform?: Platform
): Promise<CampaignUTxO> {
  if (!lucid) throw new Error("Uninitialized Lucid");
  if (!wallet) throw new Error("Disconnected Wallet");
  if (!address) throw new Error("No Address");
  if (!campaign) throw new Error("No Campaign");

  const { CampaignInfo, StateToken } = campaign;
  const validator: Validator = CampaignInfo.validator;
  const campaignAddress = CampaignInfo.address;
  const campaignPolicy = mintingPolicyToId(validator);
  const backers = CampaignInfo.data.backers;

  if (!CampaignInfo.data.support.ada) throw new Error("Nothing to Collect");

  // Determine backers and ADA to collect
  const currentBackers = platform
    ? CampaignInfo.data.backers
    : CampaignInfo.data.backers.filter((backer) => backer.address === address);
  
  const backerADA = platform
    ? CampaignInfo.data.support.ada
    : currentBackers.reduce((sum, { support }) => sum + support.ada, 0);

  if (!backerADA) {
    throw new Error("You did not support this campaign or there's nothing to collect. Incorrect? Contact us!");
  }

  const backerLovelace = platform
    ? CampaignInfo.data.support.lovelace
    : adaToLovelace(`${backerADA}`);

  // Fetch and calculate support tokens to burn
  const supportTokenUnit = toUnit(campaignPolicy, SUPPORT_TOKEN.hex);
  let totalSupportTokensToBurn = 0n;
  const backerSupportTokenUtxos = backers
    .map(({ utxo }) => {
      const amount = utxo.assets[supportTokenUnit] ?? 0n;
      totalSupportTokensToBurn += amount;
      return utxo;
    })
    .filter(({ assets }) => assets[supportTokenUnit] > 0n);

  // Prepare assets for minting/burning
  const supportTokenToBurn = { [supportTokenUnit]: -totalSupportTokensToBurn };
  const rewardTokenUnit = toUnit(campaignPolicy, REWARD_TOKEN.hex);
  const rewardTokenToMint = { [rewardTokenUnit]: BigInt(backers.length) };

  // Redeemers
  const collectRedeemer = CampaignActionRedeemer.Collect; // For collecting support
  const finishMintBurnRedeemer = Data.to(new Constr(2, [])); // For minting/burning, adjust index as needed

  // Ensure wallet is selected
  if (!lucid.wallet()) {
    const api = await wallet.enable();
    lucid.selectWallet.fromAPI(api);
  }

  // Build the transaction
  let newTx = lucid
    .newTx()
    .readFrom([StateToken.utxo]) // Reference state token UTxO
    .collectFrom(currentBackers.map(({ utxo }) => utxo), collectRedeemer) // Collect backer support UTxOs
    .collectFrom(backerSupportTokenUtxos, finishMintBurnRedeemer) // Collect support token UTxOs for burning
    .attachSpendingValidator(validator)
    .payToAddress(CampaignInfo.data.creator.address, { lovelace: backerLovelace }) // Send collected ADA to creator
    .mintAssets(supportTokenToBurn, finishMintBurnRedeemer) // Burn support tokens
    .mintAssets(rewardTokenToMint, finishMintBurnRedeemer) // Mint reward tokens
    .attachMintingPolicy(validator)
    .attachMetadata(721, {
      [campaignPolicy]: {
        [REWARD_TOKEN.assetName]: {
          platform: CampaignInfo.platform?.pkh ?? "",
          creator: CampaignInfo.data.creator.pk ?? "",
          hash: CampaignInfo.nonce.txHash,
          index: Number(CampaignInfo.nonce.outputIndex),
        },
      },
    });

  // Distribute reward tokens to backers
  for (const { address: backerAddress } of backers) {
    newTx = newTx.payToAddress(backerAddress, { [rewardTokenUnit]: 1n });
  }

  // Complete and submit transaction
  const tx = await newTx.complete({ localUPLCEval: false });
  const txHash = await submitTx(tx);

  handleSuccess(`Collect Support & Mint Rewards TxHash: ${txHash}`);

  // Return updated campaign state
  return {
    CampaignInfo: {
      ...CampaignInfo,
      data: {
        ...CampaignInfo.data,
        backers: platform ? [] : CampaignInfo.data.backers.filter((b) => b.address !== address),
        support: {
          ada: platform ? 0 : CampaignInfo.data.support.ada - backerADA,
          lovelace: platform ? 0n : CampaignInfo.data.support.lovelace - backerLovelace,
        },
      },
    },
    StateToken,
    CollectedSupport: {
      txHash,
      to: CampaignInfo.data.creator.address,
      ada: backerADA,
      lovelace: backerLovelace,
    },
    BurnedSupportToken: {
      unit: supportTokenUnit,
      quantity: totalSupportTokensToBurn,
    },
    RewardToken: {
      unit: rewardTokenUnit,
      quantity: BigInt(backers.length),
      distributedTo: backers.map(({ address: bAddr }) => bAddr),
    },
  };
}
